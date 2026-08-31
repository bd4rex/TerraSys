param(
  [string]$Url = "https://download.kiwix.org/zim/wikivoyage/wikivoyage_zh_all_maxi_2026-06.zim",
  [string]$ExpectedSha256 = "e4349864cdde61756dda54e062db46a478d8d0892d266f5d8389d328f38501e4"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root "products\encyclopedia"
$fileName = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
$target = Join-Path $directory $fileName
$staged = "$target.part"
$manifestPath = Join-Path $directory "travel-guide.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Set-ContainerReadableFile {
  param([Parameter(Mandatory = $true)][string[]]$Paths)

  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return }
  if (-not (Get-Command chmod -ErrorAction SilentlyContinue)) { throw "The Linux 'chmod' command was not found." }
  foreach ($path in $Paths) {
    & chmod 0644 -- $path
    if ($LASTEXITCODE -ne 0) { throw "Could not make the travel-guide asset container-readable: $path" }
  }
}

New-Item -ItemType Directory -Force -Path $directory | Out-Null
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  curl.exe --fail --location --retry 8 --retry-delay 5 --continue-at - --output $staged $Url
  if ($LASTEXITCODE -ne 0) { throw "Downloading the Wikivoyage archive failed." }
  Move-Item -LiteralPath $staged -Destination $target -Force
}
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) { throw "Wikivoyage SHA256 verification failed." }
$manifest = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  sourceUrl = $Url
  file = "products/encyclopedia/$fileName"
  bytes = (Get-Item -LiteralPath $target).Length
  sha256 = $actualHash
  content = "Chinese Wikivoyage all-maxi"
  snapshot = "2026-06"
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)
Set-ContainerReadableFile @($target, $manifestPath)
Get-Item -LiteralPath $target | Select-Object FullName, Length, LastWriteTime
