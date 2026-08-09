param(
  [string]$DailyAt = "03:00",
  [string]$MirrorRoot = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $PSScriptRoot "backup-terrasys.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
if ($MirrorRoot) { $arguments += " -MirrorRoot `"$MirrorRoot`"" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "TerraSys Daily Personal Backup" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Daily checksum-verified TerraSys personal-data backup" -Force | Out-Null
$policyPath = Join-Path $root "data\maintenance\backup-policy.json"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $policyPath) | Out-Null
[IO.File]::WriteAllText($policyPath, ([ordered]@{
  taskName = "TerraSys Daily Personal Backup"
  dailyAt = $DailyAt
  installedAt = [DateTimeOffset]::Now.ToString("o")
  mirrorConfigured = [bool]$MirrorRoot
  mirrorRoot = if ($MirrorRoot) { [IO.Path]::GetFullPath($MirrorRoot) } else { $null }
} | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Write-Host "Installed TerraSys scheduled task (compatibility name: TerraSys Daily Personal Backup) at $DailyAt"
