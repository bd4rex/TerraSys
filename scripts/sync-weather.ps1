$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$directory = Join-Path $root "products\weather"
$locationCache = Join-Path $directory "location-cache"
$runtime = Join-Path $root "runtime\weather-locations"
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$image = "terrasys-osmium:1"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

$disabledPackIds = @()
if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  $packState = Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
  $disabledPackIds = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
$imageReady = [bool](docker image ls -q $image)
if ($imageReady) {
  docker run --rm --entrypoint jq $image --version *> $null
  $imageReady = $LASTEXITCODE -eq 0
}
if (-not $imageReady) {
  docker build -t $image (Join-Path $root "services\tools\osmium") | Out-Host
  Assert-NativeSuccess "Building the Osmium/JQ helper image"
}
New-Item -ItemType Directory -Force -Path $directory, $locationCache, $runtime | Out-Null
$jqProgram = Join-Path $runtime "weather-locations.lf.jq"
$jqSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "weather-locations.jq")
$jqSource = $jqSource.Replace("`r`n", "`n").Replace("`r", "`n")
[IO.File]::WriteAllText($jqProgram, $jqSource, $utf8NoBom)

$installedInputs = @()
$locations = New-Object System.Collections.Generic.List[object]
foreach ($dataset in @($catalog.datasets)) {
  $id = [string]$dataset.id
  if ($disabledPackIds -contains $id) { continue }
  $product = Join-Path $root "products\tiles\pmtiles\$id.pmtiles"
  $manifestPath = Join-Path $root "products\tiles\pmtiles\$id.manifest.json"
  if (-not (Test-Path -LiteralPath $product -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $sourceRelative = ([string]$manifest.source.file).Replace('/', '\')
  $source = Join-Path $root $sourceRelative
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Weather source is missing for ${id}: $source" }
  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
  if ($sourceHash -ne ([string]$manifest.source.sha256).ToLowerInvariant()) { throw "Weather source hash does not match $id manifest." }
  $installedInputs += [pscustomobject][ordered]@{
    id = $id
    sha256 = $sourceHash
    bytes = (Get-Item -LiteralPath $source).Length
    sourceUpdatedAt = [string]$manifest.source.updatedAt
  }

  $cacheName = "$id.$($sourceHash.Substring(0, 12)).json"
  $cachePath = Join-Path $locationCache $cacheName
  if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    $filtered = Join-Path $runtime "$id.osm.pbf"
    $sequence = Join-Path $runtime "$id.geojsonseq"
    $relativeSource = $source.Substring($root.Length + 1).Replace('\', '/')
    try {
      docker run --rm -v "${root}:/data" $image tags-filter "/data/$relativeSource" n/place=city `
        -o "/data/runtime/weather-locations/$id.osm.pbf" --overwrite
      Assert-NativeSuccess "Extracting weather cities from $id"
      docker run --rm -v "${root}:/data" $image export "/data/runtime/weather-locations/$id.osm.pbf" `
        -f geojsonseq -o "/data/runtime/weather-locations/$id.geojsonseq" --overwrite
      Assert-NativeSuccess "Exporting weather cities from $id"
      $jsonLines = & docker run --rm --entrypoint jq -v "${root}:/data" $image --seq -s `
        --arg regionId $id --arg regionName ([string]$dataset.shortName) `
        --from-file /data/runtime/weather-locations/weather-locations.lf.jq "/data/runtime/weather-locations/$id.geojsonseq"
      Assert-NativeSuccess "Selecting representative weather cities for $id"
      $json = (($jsonLines -join "`n") -replace '^[\x00-\x1f]+', '').Trim()
      if (-not $json) { throw "No representative weather cities were produced for $id." }
      [IO.File]::WriteAllText($cachePath, $json, $utf8NoBom)
    }
    finally {
      Remove-Item -LiteralPath $filtered, $sequence -Force -ErrorAction SilentlyContinue
    }
  }
  $regionalLocations = [object[]](Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json)
  if ($regionalLocations.Count -lt 1) {
    $bounds = @($dataset.bounds | ForEach-Object { [double]$_ })
    $regionalLocations = @([pscustomobject]@{
      regionId = $id
      province = [string]$dataset.shortName
      name = [string]$dataset.shortName
      latitude = ($bounds[1] + $bounds[3]) / 2
      longitude = ($bounds[0] + $bounds[2]) / 2
      population = 0
    })
  }
  foreach ($location in $regionalLocations) { [void]$locations.Add($location) }
}
if ($installedInputs.Count -lt 1 -or $locations.Count -lt 1) { throw "No enabled installed map regions are available for weather." }

Write-Host "Refreshing weather snapshots for $($locations.Count) cities in $($installedInputs.Count) enabled regions..."
$responses = New-Object System.Collections.Generic.List[object]
$sourceUrls = New-Object System.Collections.Generic.List[string]
for ($offset = 0; $offset -lt $locations.Count; $offset += 10) {
  $end = [math]::Min($locations.Count - 1, $offset + 9)
  $batch = @($locations[$offset..$end])
  $latitudes = (($batch | ForEach-Object { ([double]$_.latitude).ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ',')
  $longitudes = (($batch | ForEach-Object { ([double]$_.longitude).ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ',')
  $url = "https://api.open-meteo.com/v1/forecast?latitude=$latitudes&longitude=$longitudes&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,precipitation,wind_speed_10m,wind_direction_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max&timezone=Asia%2FShanghai&forecast_days=7"
  [void]$sourceUrls.Add($url)
  $rawResponse = Invoke-RestMethod -Uri $url -TimeoutSec 60
  foreach ($response in @($rawResponse)) { [void]$responses.Add($response) }
}
if ($responses.Count -ne $locations.Count) { throw "Open-Meteo returned $($responses.Count) locations; expected $($locations.Count)." }

$features = for ($index = 0; $index -lt $locations.Count; $index++) {
  $location = $locations[$index]
  $weather = $responses[$index]
  $forecast = for ($day = 0; $day -lt @($weather.daily.time).Count; $day++) {
    [ordered]@{
      date = $weather.daily.time[$day]
      weatherCode = $weather.daily.weather_code[$day]
      temperatureMax = $weather.daily.temperature_2m_max[$day]
      temperatureMin = $weather.daily.temperature_2m_min[$day]
      precipitation = $weather.daily.precipitation_sum[$day]
      windSpeedMax = $weather.daily.wind_speed_10m_max[$day]
    }
  }
  [ordered]@{
    type = "Feature"
    id = "$($location.regionId)-$($location.name)"
    properties = [ordered]@{
      regionId = $location.regionId
      province = $location.province
      name = $location.name
      observedAt = $weather.current.time
      temperature = $weather.current.temperature_2m
      apparentTemperature = $weather.current.apparent_temperature
      humidity = $weather.current.relative_humidity_2m
      weatherCode = $weather.current.weather_code
      precipitation = $weather.current.precipitation
      windSpeed = $weather.current.wind_speed_10m
      windDirection = $weather.current.wind_direction_10m
      forecast = @($forecast)
    }
    geometry = [ordered]@{ type = "Point"; coordinates = @([double]$location.longitude, [double]$location.latitude) }
  }
}
$payload = [ordered]@{
  type = "FeatureCollection"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  source = "Open-Meteo"
  attribution = "Weather data by Open-Meteo.com (CC BY 4.0)"
  features = @($features)
}
$target = Join-Path $directory "latest.geojson"
[IO.File]::WriteAllText($target, ($payload | ConvertTo-Json -Depth 10), $utf8NoBom)
$manifest = [ordered]@{
  schemaVersion = 2
  generatedAt = $payload.generatedAt
  inputs = $installedInputs
  sourceUrls = @($sourceUrls)
  locations = $locations.Count
  bytes = (Get-Item -LiteralPath $target).Length
  sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
  license = "CC BY 4.0"
}
[IO.File]::WriteAllText((Join-Path $directory "weather.manifest.json"), ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)

$activeCacheNames = @($installedInputs | ForEach-Object { "$($_.id).$($_.sha256.Substring(0, 12)).json" })
Get-ChildItem -LiteralPath $locationCache -File -Filter '*.json' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notin $activeCacheNames } |
  Remove-Item -Force
Get-Item -LiteralPath $target, (Join-Path $directory "weather.manifest.json") | Select-Object FullName, Length, LastWriteTime
