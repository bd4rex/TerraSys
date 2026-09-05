param(
  [ValidateRange(1, 30)]
  [int]$PollSeconds = 2
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "map-version-utils.ps1")
$maintenanceRoot = Join-Path $root "data\maintenance"
$jobsRoot = Join-Path $maintenanceRoot "jobs"
$logsRoot = Join-Path $maintenanceRoot "logs"
$workerPath = Join-Path $maintenanceRoot "worker.json"
$settingsPath = Join-Path $maintenanceRoot "settings.json"
$schedulerPath = Join-Path $maintenanceRoot "scheduler.json"
$inventoryCachePath = Join-Path $maintenanceRoot "resource-inventory-cache.json"
$inventoryRevisionPath = Join-Path $maintenanceRoot "resource-inventory-revision.json"
$mapPackStatePath = Join-Path $maintenanceRoot "map-pack-state.json"
$stopPath = Join-Path $maintenanceRoot "stop.request"
$utf8 = New-Object Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $jobsRoot, $logsRoot | Out-Null

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
  catch { return $null }
}

function Write-JsonFile {
  param([string]$Path, [object]$Value)
  $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), $utf8)
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Set-ObjectProperty {
  param([object]$Value, [string]$Name, [object]$PropertyValue)
  if ($Value.PSObject.Properties.Name -contains $Name) { $Value.$Name = $PropertyValue }
  else { $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $PropertyValue }
}

function Write-WorkerState {
  param([string]$Status = "running", [string]$CurrentJobId = "")
  Write-JsonFile -Path $workerPath -Value ([ordered]@{
    schemaVersion = 2
    status = $Status
    pid = $PID
    heartbeatAt = [DateTimeOffset]::Now.ToString("o")
    currentJobId = $CurrentJobId
  })
}

function Get-ActiveJob {
  param([string]$ResourceId)
  return @(Get-ActiveJobs -ResourceId $ResourceId | Select-Object -First 1)
}

function Get-ActiveJobs {
  param([string]$ResourceId)
  $jobs = @()
  foreach ($path in Get-ChildItem -LiteralPath $jobsRoot -Filter "*.json" -File -ErrorAction SilentlyContinue) {
    $job = Read-JsonFile -Path $path.FullName
    if ($job -and $job.resourceId -eq $ResourceId -and $job.status -in @("queued", "running")) { $jobs += $job }
  }
  return @($jobs)
}

function Restore-InterruptedJobs {
  foreach ($path in Get-ChildItem -LiteralPath $jobsRoot -Filter "*.json" -File -ErrorAction SilentlyContinue) {
    $job = Read-JsonFile -Path $path.FullName
    if (-not $job -or $job.status -ne "running") { continue }
    Stop-JobCandidates -JobId ([string]$job.id)
    if ($job.operation -eq "shared-capabilities") {
      Set-ObjectProperty -Value $job -Name "status" -PropertyValue "failed"
      Set-ObjectProperty -Value $job -Name "message" -PropertyValue "后台候选构建被系统中断；当前地图未切换，请检查后手动重试"
      Set-ObjectProperty -Value $job -Name "finishedAt" -PropertyValue ([DateTimeOffset]::Now.ToString("o"))
      Set-ObjectProperty -Value $job -Name "exitCode" -PropertyValue 1
    }
    else {
      Set-ObjectProperty -Value $job -Name "status" -PropertyValue "queued"
      Set-ObjectProperty -Value $job -Name "message" -PropertyValue "检测到维护服务中断，任务已恢复到队列"
      Set-ObjectProperty -Value $job -Name "startedAt" -PropertyValue $null
    }
    Write-JsonFile -Path $path.FullName -Value $job
  }
}

function Add-AutomaticJobs {
  $settings = Read-JsonFile -Path $settingsPath
  if (-not $settings -or -not $settings.enabled) { return }

  $schedule = @{}
  $storedSchedule = Read-JsonFile -Path $schedulerPath
  if ($storedSchedule -and $storedSchedule.resources) {
    foreach ($property in $storedSchedule.resources.PSObject.Properties) { $schedule[$property.Name] = $property.Value }
  }
  elseif ($storedSchedule -and $storedSchedule.lastScheduled) {
    foreach ($property in $storedSchedule.lastScheduled.PSObject.Properties) {
      $schedule[$property.Name] = [pscustomobject]@{ lastAttempted = [string]$property.Value; lastSucceeded = [string]$property.Value }
    }
  }
  $resources = @(
    [pscustomobject]@{ Id = "weather"; Label = "天气快照"; IntervalHours = 6 },
    [pscustomobject]@{ Id = "world-region-catalog"; Label = "全球区域目录"; IntervalHours = 168 },
    [pscustomobject]@{ Id = "overview-map"; Label = "全球概览地图"; IntervalHours = 720 }
  )
  $changed = $false
  foreach ($resource in $resources) {
    $resourceSetting = $settings.resources.PSObject.Properties[$resource.Id].Value
    if (-not $resourceSetting -or -not $resourceSetting.enabled) { continue }
    $intervalHours = if ($resourceSetting.intervalHours) { [double]$resourceSetting.intervalHours } else { [double]$resource.IntervalHours }
    $resourceSchedule = if ($schedule.ContainsKey($resource.Id)) { $schedule[$resource.Id] } else { $null }
    $lastSucceeded = if ($resourceSchedule -and $resourceSchedule.lastSucceeded) { [DateTimeOffset]::Parse([string]$resourceSchedule.lastSucceeded) } else { [DateTimeOffset]::MinValue }
    $lastAttempted = if ($resourceSchedule -and $resourceSchedule.lastAttempted) { [DateTimeOffset]::Parse([string]$resourceSchedule.lastAttempted) } else { [DateTimeOffset]::MinValue }
    if (([DateTimeOffset]::Now - $lastSucceeded).TotalHours -lt $intervalHours) { continue }
    if (([DateTimeOffset]::Now - $lastAttempted).TotalMinutes -lt 60) { continue }
    if (Get-ActiveJob -ResourceId $resource.Id) { continue }

    $jobId = [Guid]::NewGuid().ToString("N")
    $now = [DateTimeOffset]::Now.ToString("o")
    $job = [ordered]@{
      id = $jobId
      resourceId = $resource.Id
      action = "update"
      operation = $resource.Id
      label = $resource.Label
      heavy = $false
      priority = 50
      automatic = $true
      attempts = 0
      maxAttempts = 3
      nextAttemptAt = $now
      cancelRequested = $false
      status = "queued"
      message = "自动更新已加入队列"
      requestedAt = $now
      startedAt = $null
      finishedAt = $null
      exitCode = $null
      logFile = "logs/$jobId.log"
    }
    Write-JsonFile -Path (Join-Path $jobsRoot "$jobId.json") -Value $job
    $schedule[$resource.Id] = [ordered]@{ lastAttempted = $now; lastSucceeded = if ($resourceSchedule) { $resourceSchedule.lastSucceeded } else { $null } }
    $changed = $true
  }
  if ($changed) {
    Write-JsonFile -Path $schedulerPath -Value ([ordered]@{ resources = $schedule })
  }
}

function Set-ScheduleSuccess {
  param([string]$ResourceId)
  $stored = Read-JsonFile -Path $schedulerPath
  $resources = @{}
  if ($stored -and $stored.resources) {
    foreach ($property in $stored.resources.PSObject.Properties) { $resources[$property.Name] = $property.Value }
  }
  $now = [DateTimeOffset]::Now.ToString("o")
  $previous = if ($resources.ContainsKey($ResourceId)) { $resources[$ResourceId] } else { $null }
  $resources[$ResourceId] = [ordered]@{ lastAttempted = if ($previous -and $previous.lastAttempted) { $previous.lastAttempted } else { $now }; lastSucceeded = $now }
  Write-JsonFile -Path $schedulerPath -Value ([ordered]@{ resources = $resources })
}

function Stop-JobCandidates {
  param([string]$JobId)
  if (-not $JobId -or -not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
  try {
    $containers = @(docker ps -aq --filter "label=terrasys.maintenance-job=$JobId" 2>$null)
    if ($containers.Count) { docker rm -f @containers *> $null }
    $volumes = @(docker volume ls -q --filter "label=terrasys.maintenance-job=$JobId" 2>$null)
    $mountedVolumes = @()
    foreach ($container in @(docker ps -aq 2>$null)) {
      $mountedVolumes += @(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' $container 2>$null)
    }
    $safeVolumes = @($volumes | Where-Object { $_ -and $_ -notin $mountedVolumes })
    if ($safeVolumes.Count) { docker volume rm @safeVolumes *> $null }
  }
  catch {
    # Candidate cleanup is best-effort; the active map must never be stopped here.
  }
}

function Add-RegionFollowUpJobs {
  param([string]$PackId)
  $resources = @(
    [pscustomobject]@{ Id = "terrain"; Label = "全球地形与等高线"; Heavy = $true; Priority = 80; MaxAttempts = 3; Message = "正在补齐该区域离线高程与等高线" },
    [pscustomobject]@{ Id = "weather"; Label = "天气快照"; Heavy = $false; Priority = 60; MaxAttempts = 3; Message = "正在同步轻量派生资源" },
    [pscustomobject]@{ Id = "nautical"; Label = "航海参考"; Heavy = $false; Priority = 60; MaxAttempts = 3; Message = "正在同步轻量派生资源" },
    [pscustomobject]@{ Id = "osm-carto"; Label = "本地 OSM 原版渲染"; Heavy = $true; Priority = 120; MaxAttempts = 2; Message = "正在后台同步 OSM 原版；完成前新区域继续使用交互矢量" },
    [pscustomobject]@{ Id = "shared-capabilities"; Label = "搜索与路线共享索引"; Heavy = $true; Priority = 130; MaxAttempts = 2; Message = "正在后台扩展搜索与路线覆盖；当前地图及原覆盖范围继续可用" }
  )
  foreach ($resource in $resources) {
    $activeJobs = @(Get-ActiveJobs -ResourceId $resource.Id)
    # A queued job reads the complete installed set when it starts. If a job is
    # already running, retain one queued successor so a newly finished region
    # cannot be omitted from that in-flight snapshot.
    if (@($activeJobs | Where-Object { $_.status -eq "queued" }).Count) { continue }
    $jobId = [Guid]::NewGuid().ToString("N")
    $now = [DateTimeOffset]::Now.ToString("o")
    $job = [ordered]@{
      id = $jobId
      resourceId = $resource.Id
      action = "update"
      operation = $resource.Id
      label = $resource.Label
      heavy = [bool]$resource.Heavy
      priority = [int]$resource.Priority
      automatic = $true
      trigger = "region-pack:$PackId"
      attempts = 0
      maxAttempts = [int]$resource.MaxAttempts
      nextAttemptAt = $now
      cancelRequested = $false
      status = "queued"
      message = "启用区域范围已变化（$PackId），$($resource.Message)"
      requestedAt = $now
      startedAt = $null
      finishedAt = $null
      exitCode = $null
      logFile = "logs/$jobId.log"
    }
    Write-JsonFile -Path (Join-Path $jobsRoot "$jobId.json") -Value $job
  }
}

function Stop-ProcessTree {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return }
  $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
  try {
    if ($isWindowsHost) {
      & taskkill.exe /PID $ProcessId /T /F *> $null
      if ($LASTEXITCODE -ne 0) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
    }
    else {
      & pkill -TERM -P $ProcessId *> $null
      Start-Sleep -Milliseconds 500
      & pkill -KILL -P $ProcessId *> $null
      Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  catch { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
}

function Invalidate-ResourceInventory {
  Write-JsonFile -Path $inventoryRevisionPath -Value ([ordered]@{
    revision = [Guid]::NewGuid().ToString("N")
    changedAt = [DateTimeOffset]::Now.ToString("o")
  })
}

function Reset-PackPreference {
  param([string]$PackId)
  if (-not $PackId) { return }
  $preferences = Read-JsonFile -Path $mapPackStatePath
  if (-not $preferences) { return }
  $disabled = @($preferences.disabledPackIds | Where-Object { [string]$_ -ne $PackId })
  Set-ObjectProperty -Value $preferences -Name "disabledPackIds" -PropertyValue $disabled
  Set-ObjectProperty -Value $preferences -Name "updatedAt" -PropertyValue ([DateTimeOffset]::Now.ToString("o"))
  Write-JsonFile -Path $mapPackStatePath -Value $preferences
}

function Remove-RegionStaging {
  param([object]$Job)
  if ($Job.operation -ne "region-pack" -or $Job.action -notin @("build", "update", "rebuild")) { return }
  $stagedProduct = Join-Path $root "products\tiles\pmtiles\$($Job.resourceId).staged.pmtiles"
  Remove-Item -LiteralPath $stagedProduct -Force -ErrorAction SilentlyContinue
  foreach ($suffix in @('staged.manifest.json', 'details.staged.pmtiles')) {
    Remove-Item -LiteralPath (Join-Path $root "products\tiles\pmtiles\$($Job.resourceId).$suffix") -Force -ErrorAction SilentlyContinue
  }
}

function Get-JobCommand {
  param([object]$Job)
  switch ([string]$Job.operation) {
    "region-pack" {
      $action = switch ([string]$Job.action) {
        "build" { "Build" }
        "rebuild" { "Build" }
        "rollback" { "Rollback" }
        "verify" { "Verify" }
        "remove" { "Remove" }
        default { "Update" }
      }
      $parameters = [ordered]@{ Action = $action; PackId = [string]$Job.resourceId; MaintenanceJobId = [string]$Job.id }
      if ($action -eq "Remove") { $parameters.ConfirmRemove = $true }
      return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "region-pack.ps1"); Parameters = $parameters }
    }
    "shared-capabilities" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "rebuild-shared-indexes.ps1"); Parameters = [ordered]@{ ConfirmRebuild = $true; MaintenanceJobId = [string]$Job.id } } }
    "osm-carto" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "build-osm-carto.ps1"); Parameters = [ordered]@{ MaintenanceJobId = [string]$Job.id } } }
    "world-region-catalog" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "sync-world-catalog.ps1"); Parameters = [ordered]@{} } }
    "overview-map" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "sync-overview-resources.ps1"); Parameters = [ordered]@{} } }
    "terrain" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "sync-elevation.ps1"); Parameters = [ordered]@{} } }
    "weather" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "sync-weather.ps1"); Parameters = [ordered]@{} } }
    "nautical" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "build-nautical.ps1"); Parameters = [ordered]@{ MaintenanceJobId = [string]$Job.id } } }
    "encyclopedia" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "download-encyclopedia.ps1"); Parameters = [ordered]@{} } }
    "travel-guide" { return [pscustomobject]@{ Script = (Join-Path $PSScriptRoot "download-travel-guide.ps1"); Parameters = [ordered]@{} } }
    default { throw "Maintenance operation is not allowlisted: $($Job.operation)" }
  }
}

function Invoke-MaintenanceJob {
  param([IO.FileInfo]$JobFile, [object]$Job)
  $jobId = [string]$Job.id
  $logPath = Join-Path $logsRoot "$jobId.log"
  $errorPath = Join-Path $logsRoot "$jobId.error.log"
  $invocationPath = Join-Path $logsRoot "$jobId.invocation.json"
  $resultPath = Join-Path $logsRoot "$jobId.result.json"
  $attempts = [int]$Job.attempts + 1
  Set-ObjectProperty -Value $Job -Name "attempts" -PropertyValue $attempts
  Set-ObjectProperty -Value $Job -Name "status" -PropertyValue "running"
  Set-ObjectProperty -Value $Job -Name "startedAt" -PropertyValue ([DateTimeOffset]::Now.ToString("o"))
  Set-ObjectProperty -Value $Job -Name "message" -PropertyValue "本机维护服务正在执行"
  Write-JsonFile -Path $JobFile.FullName -Value $Job
  Write-WorkerState -CurrentJobId $jobId

  $cancelled = $false
  $process = $null
  try {
    $command = Get-JobCommand -Job $Job
    if (-not (Test-Path -LiteralPath $command.Script -PathType Leaf)) { throw "Maintenance script is missing: $($command.Script)" }
    Write-JsonFile -Path $invocationPath -Value ([ordered]@{
      script = $command.Script
      parameters = $command.Parameters
      resultFile = $resultPath
    })
    $wrapper = Join-Path $PSScriptRoot "invoke-maintenance-script.ps1"
    $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $powerShellExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
    $arguments = @("-NoLogo", "-NoProfile")
    if ($isWindowsHost) { $arguments += @("-ExecutionPolicy", "Bypass") }
    $arguments += @("-File", ('"' + $wrapper + '"'), "-InvocationFile", ('"' + $invocationPath + '"'))
    $processStart = @{
      FilePath = $powerShellExecutable
      ArgumentList = $arguments
      RedirectStandardOutput = $logPath
      RedirectStandardError = $errorPath
      PassThru = $true
    }
    if ($isWindowsHost) { $processStart.WindowStyle = "Hidden" }
    $process = Start-Process @processStart
    while (-not $process.HasExited) {
      $latestJob = Read-JsonFile -Path $JobFile.FullName
      if ($latestJob -and $latestJob.cancelRequested) {
        $cancelled = $true
        Stop-ProcessTree -ProcessId $process.Id
        Stop-JobCandidates -JobId $jobId
        throw "任务已由用户取消"
      }
      if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
        Stop-ProcessTree -ProcessId $process.Id
        Stop-JobCandidates -JobId $jobId
        throw "维护服务已停止，任务被中断"
      }
      Write-WorkerState -CurrentJobId $jobId
      Start-Sleep -Seconds $PollSeconds
      $process.Refresh()
    }
    $process.WaitForExit()
    $process.Refresh()
    $result = Read-JsonFile -Path $resultPath
    if (-not $result) { throw "维护包装器没有生成结果凭证，任务状态不可信。" }
    $exitCode = [int]$result.exitCode
    if ($exitCode -ne 0) {
      $errorMessage = if ($result.error) { [string]$result.error } elseif (Test-Path -LiteralPath $errorPath) { (Get-Content -LiteralPath $errorPath -Tail 3) -join " " } else { "脚本返回非零状态" }
      throw "退出码 ${exitCode}：$errorMessage"
    }
    Set-ObjectProperty -Value $Job -Name "status" -PropertyValue "succeeded"
    Set-ObjectProperty -Value $Job -Name "message" -PropertyValue "任务完成"
    Set-ObjectProperty -Value $Job -Name "exitCode" -PropertyValue 0
    Set-ObjectProperty -Value $Job -Name "nextAttemptAt" -PropertyValue $null
    if ($Job.operation -eq "region-pack" -and $Job.action -in @("build", "remove")) {
      Reset-PackPreference -PackId ([string]$Job.resourceId)
    }
    if ($Job.operation -eq "region-pack" -and $Job.action -in @("build", "update", "rebuild", "remove")) {
      Add-RegionFollowUpJobs -PackId ([string]$Job.resourceId)
    }
    # Keep the last complete inventory readable while the UI starts a fresh
    # background scan after observing this job transition.
    if ($Job.automatic) { Set-ScheduleSuccess -ResourceId ([string]$Job.resourceId) }
  }
  catch {
    $maxAttempts = if ($Job.maxAttempts) { [int]$Job.maxAttempts } else { 1 }
    if (-not $cancelled -and $attempts -lt $maxAttempts -and -not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
      $delayMinutes = [math]::Min(120, [math]::Pow(2, $attempts - 1) * 5)
      Set-ObjectProperty -Value $Job -Name "status" -PropertyValue "queued"
      Set-ObjectProperty -Value $Job -Name "message" -PropertyValue "执行失败，将在 $delayMinutes 分钟后重试：$($_.Exception.Message)"
      Set-ObjectProperty -Value $Job -Name "nextAttemptAt" -PropertyValue ([DateTimeOffset]::Now.AddMinutes($delayMinutes).ToString("o"))
      Set-ObjectProperty -Value $Job -Name "startedAt" -PropertyValue $null
      Set-ObjectProperty -Value $Job -Name "finishedAt" -PropertyValue $null
    }
    else {
      Set-ObjectProperty -Value $Job -Name "status" -PropertyValue $(if ($cancelled) { "cancelled" } else { "failed" })
      Set-ObjectProperty -Value $Job -Name "message" -PropertyValue $_.Exception.Message
      Set-ObjectProperty -Value $Job -Name "exitCode" -PropertyValue 1
    }
  }
  finally {
    if ($Job.operation -eq "region-pack") {
      try {
        if ($process -and -not $process.HasExited) { [void]$process.WaitForExit(5000) }
        Repair-TerraSysMapActivations -ProductRoot (Join-Path $root "products\tiles\pmtiles") -PackId ([string]$Job.resourceId)
      }
      catch {
        Set-ObjectProperty -Value $Job -Name "status" -PropertyValue "failed"
        Set-ObjectProperty -Value $Job -Name "message" -PropertyValue "地图版本恢复未完成，已保留恢复日志并暂停该版本使用：$($_.Exception.Message)"
        Set-ObjectProperty -Value $Job -Name "exitCode" -PropertyValue 1
      }
    }
    Remove-Item -LiteralPath $invocationPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    if ($Job.status -ne "queued") { Set-ObjectProperty -Value $Job -Name "finishedAt" -PropertyValue ([DateTimeOffset]::Now.ToString("o")) }
    Set-ObjectProperty -Value $Job -Name "cancelRequested" -PropertyValue $false
    if ($Job.status -in @("failed", "cancelled")) { Remove-RegionStaging -Job $Job }
    Write-JsonFile -Path $JobFile.FullName -Value $Job
    if ($Job.status -ne "queued") { Invalidate-ResourceInventory }
    Write-WorkerState
  }
}

function Remove-ExpiredHistory {
  $cutoff = [DateTimeOffset]::Now.AddDays(-30)
  $completed = Get-ChildItem -LiteralPath $jobsRoot -Filter "*.json" -File -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ File = $_; Job = (Read-JsonFile -Path $_.FullName) } } |
    Where-Object { $_.Job -and $_.Job.status -in @("succeeded", "failed", "cancelled") } |
    Sort-Object { [string]$_.Job.finishedAt } -Descending
  foreach ($entry in @($completed | Select-Object -Skip 200)) {
    Remove-Item -LiteralPath $entry.File.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $logsRoot "$($entry.Job.id).log"), (Join-Path $logsRoot "$($entry.Job.id).error.log") -Force -ErrorAction SilentlyContinue
  }
  foreach ($entry in @($completed | Select-Object -First 200)) {
    if (-not $entry.Job.finishedAt) { continue }
    if ([DateTimeOffset]::Parse([string]$entry.Job.finishedAt) -ge $cutoff) { continue }
    Remove-Item -LiteralPath $entry.File.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $logsRoot "$($entry.Job.id).log"), (Join-Path $logsRoot "$($entry.Job.id).error.log") -Force -ErrorAction SilentlyContinue
  }
}

$mutex = New-Object Threading.Mutex($false, "Local\TerraSys-MaintenanceWorker")
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
  Write-WorkerState
  Repair-TerraSysMapActivations -ProductRoot (Join-Path $root "products\tiles\pmtiles")
  Restore-InterruptedJobs
  Remove-ExpiredHistory
  $nextHistoryCleanup = [DateTimeOffset]::Now.AddHours(1)
  while (-not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
    Write-WorkerState
    Add-AutomaticJobs
    if ([DateTimeOffset]::Now -ge $nextHistoryCleanup) {
      Remove-ExpiredHistory
      $nextHistoryCleanup = [DateTimeOffset]::Now.AddHours(1)
    }
    $nextJob = Get-ChildItem -LiteralPath $jobsRoot -Filter "*.json" -File -ErrorAction SilentlyContinue |
      ForEach-Object { [pscustomobject]@{ File = $_; Job = (Read-JsonFile -Path $_.FullName) } } |
      Where-Object { $_.Job -and $_.Job.status -eq "queued" } |
      Where-Object { -not $_.Job.nextAttemptAt -or [DateTimeOffset]::Parse([string]$_.Job.nextAttemptAt) -le [DateTimeOffset]::Now } |
      Sort-Object @{ Expression = { if ($_.Job.priority) { [int]$_.Job.priority } else { 100 } } }, @{ Expression = { [string]$_.Job.requestedAt } } |
      Select-Object -First 1
    if ($nextJob) { Invoke-MaintenanceJob -JobFile $nextJob.File -Job $nextJob.Job }
    else { Start-Sleep -Seconds $PollSeconds }
  }
}
finally {
  Write-WorkerState -Status "stopped"
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
