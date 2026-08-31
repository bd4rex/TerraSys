param(
  [string]$Url = "https://download.kiwix.org/zim/wikipedia/wikipedia_zh_all_mini_2026-05.zim",
  [string]$ExpectedSha256 = "bde558d74cdfaab5d5fe43b4d400e94b33b146d256892b3f497c8f409d196da0"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root "products\encyclopedia"
$fileName = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
$target = Join-Path $directory $fileName
$staged = "$target.part"
$manifestPath = Join-Path $directory "encyclopedia.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Set-ContainerReadableFile {
  param([Parameter(Mandatory = $true)][string[]]$Paths)

  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return }
  if (-not (Get-Command chmod -ErrorAction SilentlyContinue)) { throw "The Linux 'chmod' command was not found." }
  foreach ($path in $Paths) {
    & chmod 0644 -- $path
    if ($LASTEXITCODE -ne 0) { throw "Could not make the encyclopedia asset container-readable: $path" }
  }
}

New-Item -ItemType Directory -Force -Path $directory | Out-Null
if (Test-Path -LiteralPath $target -PathType Leaf) {
  $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
  if ($currentHash -eq $ExpectedSha256.ToLowerInvariant()) {
    $readablePaths = @($target)
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $readablePaths += $manifestPath }
    Set-ContainerReadableFile $readablePaths
    Write-Host "Encyclopedia archive is already verified: $target"
    exit 0
  }
  throw "Existing encyclopedia archive has an unexpected SHA256: $target"
}

Write-Host "Downloading $fileName with resume support..."
curl.exe --fail --location --retry 8 --retry-delay 5 --continue-at - --output $staged $Url
if ($LASTEXITCODE -ne 0) { throw "Downloading the encyclopedia archive failed with exit code $LASTEXITCODE." }

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $staged).Hash.ToLowerInvariant()
if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
  throw "Encyclopedia SHA256 mismatch. Expected $ExpectedSha256, received $actualHash."
}
Move-Item -LiteralPath $staged -Destination $target -Force
$manifest = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  sourceUrl = $Url
  file = "products/encyclopedia/$fileName"
  bytes = (Get-Item -LiteralPath $target).Length
  sha256 = $actualHash
  content = "Chinese Wikipedia all-mini"
  snapshot = "2026-05"
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)
Set-ContainerReadableFile @($target, $manifestPath)
Get-Item -LiteralPath $target | Select-Object FullName, Length, LastWriteTime
