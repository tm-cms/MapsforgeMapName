$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($scriptDir)) {
    $scriptDir = Get-Location
}

$OsmosisDir = "$scriptDir\osmosis-0.49.2\bin"
$TagConfFile = "$OsmosisDir\tag-igpsport.xml"

$pbfFiles = Get-ChildItem -Path $scriptDir -Filter "*.pbf" | Select-Object -ExpandProperty FullName

if ($pbfFiles.Count -eq 0) {
    Write-Error "No .pbf files found in directory: $scriptDir"
    exit 1
}

Write-Host "Found .pbf files:"
foreach ($file in $pbfFiles) {
    Write-Host "  - $(Split-Path -Leaf $file)"
}
Write-Host ""

do {
    $CountryCode = Read-Host "Enter 2-character country code (e.g. PL, DE, FR)"
    $CountryCode = $CountryCode.ToUpper()
} while ($CountryCode.Length -ne 2)

Write-Host "Country code: $CountryCode"
Write-Host ""

if (-not (Test-Path $TagConfFile)) {
    Write-Error "Tag configuration file not found: $TagConfFile"
    exit 1
}

$MagicString = "mapsforge binary OSM"
$DefaultZoom = 13
$Zoom = 1 -shl $DefaultZoom
$Base36Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

function Read-BigEndianInt {
    param([System.IO.BinaryReader]$reader, [int]$length)
    $bytes = $reader.ReadBytes($length)
    [long]$result = 0
    foreach ($b in $bytes) {
        $result = ($result -shl 8) + $b
    }
    return $result
}

function Read-BigEndianLong {
    param([System.IO.BinaryReader]$reader)
    $bytes = $reader.ReadBytes(8)
    [long]$result = 0
    foreach ($b in $bytes) {
        $result = ($result -shl 8) + $b
    }
    return $result
}

function ConvertTo-Base36 {
    param([int]$value, [int]$length)
    if ($value -lt 0) { $value = 0 }
    $result = New-Object char[] $length
    for ($i = $length - 1; $i -ge 0; $i--) {
        $result[$i] = $Base36Chars[$value % 36]
        $value = [math]::Floor($value / 36)
    }
    return -join $result
}

function ConvertTo-TileX {
    param([double]$lon, [int]$tilesPerSide)
    $x = ($lon + 180.0) / 360.0 * $tilesPerSide
    return [math]::Floor($x)
}

function ConvertTo-TileY {
    param([double]$lat, [int]$tilesPerSide)
    $rad = $lat * [math]::PI / 180.0
    $y = (1.0 - [math]::Log([math]::Tan($rad) + 1.0 / [math]::Cos($rad)) / [math]::PI) / 2.0 * $tilesPerSide
    return [math]::Floor($y)
}

function Get-GeoName {
    param([double]$minLng, [double]$maxLng, [double]$minLat, [double]$maxLat)
    $xStart = ConvertTo-TileX -lon $minLng -tilesPerSide $Zoom
    $yStart = ConvertTo-TileY -lat $maxLat -tilesPerSide $Zoom
    $xEnd = ConvertTo-TileX -lon $maxLng -tilesPerSide $Zoom
    $yEnd = ConvertTo-TileY -lat $minLat -tilesPerSide $Zoom
    $xSpan = $xEnd - $xStart + 1
    $ySpan = $yEnd - $yStart + 1
    $name = (ConvertTo-Base36 -value $xStart -length 3) +
            (ConvertTo-Base36 -value $yStart -length 3) +
            (ConvertTo-Base36 -value ($xSpan - 1) -length 3) +
            (ConvertTo-Base36 -value ($ySpan - 1) -length 3)
    return $name
}

$fileIndex = 0
foreach ($InputFile in $pbfFiles) {
    $fileIndex++
    $fileName = Split-Path -Leaf $InputFile

    Write-Host "=========================================="
    Write-Host "Processing [$fileIndex/$($pbfFiles.Count)]: $fileName"
    Write-Host "=========================================="

    $OutputFile = "$scriptDir\out_$fileIndex.map"

    Write-Host "Running osmosis..."

    & cmd /c "$OsmosisDir\osmosis.bat" --rbf file="$InputFile" --tag-filter reject-ways amenity=* highway=* building=* natural=* landuse=* leisure=* shop=* waterway=* man_made=* railway=* tourism=* barrier=* boundary=* power=* historic=* emergency=* office=* craft=* healthcare=* aeroway=* route=* public_transport=* bridge=* tunnel=* addr:housenumber=* addr:street=* addr:city=* addr:postcode=* name=* ref=* surface=* access=* foot=* bicycle=* motor_vehicle=* oneway=* lit=* width=* maxspeed=* mountain_pass=* religion=* tracktype=* area=* sport=* piste=* admin_level=* aerialway=* lock=* roof=* military=* wood=* --tag-filter accept-relations natural=water place=islet --used-node --rbf file="$InputFile" --tag-filter accept-ways highway=* waterway=* landuse=* natural=* place=* --tag-filter accept-relations highway=* waterway=* landuse=* natural=* place=* --used-node --merge --mapfile-writer file="$OutputFile" type=hd zoom-interval-conf=13,13,13,14,14,14 threads=4 tag-conf-file="$TagConfFile"

    if (-not (Test-Path $OutputFile)) {
        Write-Warning "Osmosis did not generate file for: $fileName - skipping"
        continue
    }

    Write-Host "Osmosis completed. Generating name..."

    $fs = [System.IO.File]::OpenRead($OutputFile)
    $reader = New-Object System.IO.BinaryReader($fs)

    try {
        $magicBytes = $reader.ReadBytes($MagicString.Length)
        $magic = [System.Text.Encoding]::ASCII.GetString($magicBytes)

        if ($magic -ne $MagicString) {
            Write-Warning "Invalid .map file for: $fileName - skipping"
            continue
        }

        $null = $reader.ReadBytes(4 + 4 + 8)

        $dateTimestamp = Read-BigEndianLong -reader $reader
        $dateOfCreation = [DateTimeOffset]::FromUnixTimeMilliseconds($dateTimestamp).DateTime
        $dateString = $dateOfCreation.ToString("yyMMdd")

        $minLatMicro = Read-BigEndianInt -reader $reader -length 4
        $minLngMicro = Read-BigEndianInt -reader $reader -length 4
        $maxLatMicro = Read-BigEndianInt -reader $reader -length 4
        $maxLngMicro = Read-BigEndianInt -reader $reader -length 4

        $minLat = $minLatMicro / 1000000.0
        $minLng = $minLngMicro / 1000000.0
        $maxLat = $maxLatMicro / 1000000.0
        $maxLng = $maxLngMicro / 1000000.0

        $geoName = Get-GeoName -minLng $minLng -maxLng $maxLng -minLat $minLat -maxLat $maxLat

        Write-Host "Date: $dateString, Geoposition: $geoName"
    }
    finally {
        $reader.Close()
        $fs.Close()
    }

    $newName = "${CountryCode}0000${dateString}${geoName}"
    $newPath = "$scriptDir\$newName.map"

    Write-Host "New name: $newName.map"

    if (Test-Path $newPath) {
        Remove-Item $newPath -Force
    }

    Rename-Item -Path $OutputFile -NewName "$newName.map"
    Write-Host "OK: $fileName -> $newName.map"
    Write-Host ""
}

Write-Host "=========================================="
Write-Host "Done! Processed $($pbfFiles.Count) files."
Write-Host "=========================================="
