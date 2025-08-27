$PLEX_URL        = ($env:PLEX_URL        -replace '/+$','')
$PLEX_TOKEN        = $env:PLEX_TOKEN
$MAINTAINERR_URL = ($env:MAINTAINERR_URL -replace '/+$','')
$IMAGE_SAVE_PATH   = $env:IMAGE_SAVE_PATH
$ORIGINAL_IMAGE_PATH = $env:ORIGINAL_IMAGE_PATH
$TEMP_IMAGE_PATH   = $env:TEMP_IMAGE_PATH
$FONT_PATH         = $env:FONT_PATH
$FONT_COLOR        = $env:FONT_COLOR
$BACK_COLOR        = $env:BACK_COLOR

$FONT_SIZE         = $env:FONT_SIZE
$PADDING           = $env:PADDING
$BACK_RADIUS       = $env:BACK_RADIUS
$HORIZONTAL_OFFSET = $env:HORIZONTAL_OFFSET
$HORIZONTAL_ALIGN  = $env:HORIZONTAL_ALIGN
$VERTICAL_OFFSET   = $env:VERTICAL_OFFSET
$VERTICAL_ALIGN    = $env:VERTICAL_ALIGN

$OVERLAY_TEXT      = $env:OVERLAY_TEXT
$ENABLE_DAY_SUFFIX = [bool]($env:ENABLE_DAY_SUFFIX -eq "true")
$ENABLE_UPPERCASE  = [bool]($env:ENABLE_UPPERCASE -eq "true")
$LANGUAGE          = $env:LANGUAGE
$DATE_FORMAT       = $env:DATE_FORMAT
$PROCESS_COLLECTIONS = $env:PROCESS_COLLECTIONS
$REAPPLY_OVERLAY   = [bool]($env:REAPPLY_OVERLAY -eq "true")
$RESET_OVERLAY   = [bool]($env:RESET_OVERLAY -eq "true")


$ErrorActionPreference = 'Stop'
trap {
    $e = $_.Exception
    Log-Message -Type "ERR" -Message ("UNHANDLED: " + $e.GetType().FullName + " - " + $e.Message)
    if ($e.InnerException) {
        Log-Message -Type "ERR" -Message ("INNER: " + $e.InnerException.GetType().FullName + " - " + $e.InnerException.Message)
        Log-Message -Type "DBG" -Message ($e.InnerException.ToString())
    } else {
        Log-Message -Type "DBG" -Message ($e.ToString())
    }
    exit 1
}


# Set defaults if not provided
if (-not $DATE_FORMAT) {
    $DATE_FORMAT = "MMM d"
}
if (-not $LANGUAGE) {
    $LANGUAGE = "en-US"
}
if (-not $OVERLAY_TEXT) {
    $OVERLAY_TEXT = "Leaving"
}

if (-not $PROCESS_COLLECTIONS) {
    # Default: include all (by setting to empty array, or ["*"])
    $collectionsToReorder = @("*")
} else {
    $collectionsToReorder = $PROCESS_COLLECTIONS -split "," | ForEach-Object { $_.Trim() }
}

function Normalize-Culture([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "en-US" }
    $t = $s.Trim()
    # Convert en_US.UTF-8 -> en-US
    $t = $t -replace '\.UTF-?8$', '' -replace '_', '-'
    try {
        [void][System.Globalization.CultureInfo]::GetCultureInfo($t)
        return $t
    } catch {
        Log-Message -Type "WRN" -Message "Unsupported culture '$s' (normalized '$t'). Falling back to en-US."
        return "en-US"
    }
}

# Use env or default, then normalize and create CultureInfo
if (-not $LANGUAGE) { $LANGUAGE = "en-US" }
$LANGUAGE = Normalize-Culture $LANGUAGE
$cultureInfo = [System.Globalization.CultureInfo]::GetCultureInfo($LANGUAGE)


# Define culture based on selected language
$cultureInfo = New-Object System.Globalization.CultureInfo($LANGUAGE)

# Define path for tracking collection state
$CollectionStateFile = "$IMAGE_SAVE_PATH/current_collection_state.json"

# Initialize collection state if the file does not exist
if (-not (Test-Path -Path $CollectionStateFile)) {
    @{} | ConvertTo-Json | Set-Content -Path $CollectionStateFile
}


function Log-Message {
    param (
        [string]$Type,
        [string]$Message
    )

    # ANSI escape codes for colors
    $ColorReset = "`e[0m"
    $ColorBlue = "`e[34m"
    $ColorRed = "`e[31m"
    $ColorYellow = "`e[33m"
    $ColorGray = "`e[90m"
    $ColorGreen = "`e[32m"
    $ColorDefault = "`e[37m"

    # Select color based on message type
    $color = switch ($Type) {
        "INF" { $ColorBlue }
        "ERR" { $ColorRed }
        "WRN" { $ColorYellow }
        "DBG" { $ColorGray }
        "SUC" { $ColorGreen }
        default { $ColorDefault }
    }

    # Output the colored type and uncolored message
    Write-Host "$($color)[$Type]$($ColorReset) $Message"
}

if ($REAPPLY_OVERLAY) {
    Log-Message -Type "INF" -Message "Reapply overlay is enabled. Overlays will be reapplied for all media."
}


function Get-BestPlexImageUrl {
    param([Parameter(Mandatory=$true)][string]$MetadataId)

    $base  = $PLEX_URL.TrimEnd('/')
    $token = $PLEX_TOKEN

    # Fetch metadata (XML) first
    try {
        $meta = Invoke-RestMethod -Uri "$base/library/metadata/$MetadataId" `
                                  -Headers @{ "X-Plex-Token" = $token } `
                                  -Method GET -ErrorAction Stop
    } catch {
        Log-Message -Type "WRN" -Message "Metadata lookup failed for $MetadataId on ${base}: $_"
        return $null
    }

    $mc = $meta.MediaContainer
    if (-not $mc) { return $null }

    # Pick the primary node (movie = Video, show/season/episode may differ)
    $node = $null
    foreach ($name in @('Video','Directory','Track','Metadata','Photo')) {
        if ($mc.$name) { $node = $mc.$name; break }
    }
    if ($node -is [System.Array]) { $node = $node[0] }
    if (-not $node) { return $null }

    # Build candidate list in the preferred order.
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1) EXACT versioned paths from metadata 
    foreach ($p in @($node.thumb, $node.art, $node.parentThumb, $node.grandparentThumb, $node.parentArt, $node.grandparentArt)) {
        if ($p) { $candidates.Add($p) }
    }

    # 2) URLs from <Image> nodes (often duplicate of above, but keep as fallback)
    if ($node.Image) {
        $node.Image | ForEach-Object {
            if ($_.url) { $candidates.Add($_.url) }
        }
    }

    # 3) Fallbacks, in case versioned are missing
    $candidates.Add("/library/metadata/$MetadataId/thumb")
    $candidates.Add("/library/metadata/$MetadataId/art")

    # Dedup while preserving order
    $seen = @{}
    $ordered = foreach ($p in $candidates) { if (-not $seen[$p]) { $seen[$p] = $true; $p } }

    foreach ($p in $ordered) {
        $u = if ($p -like 'http*') { $p }
             elseif ($p.StartsWith('/')) { "$base$p" }
             else { "$base/$p" }

        try {
        
            $tmp = [System.IO.Path]::GetTempFileName()
            Invoke-WebRequest -Uri $u -Headers @{ "X-Plex-Token" = $token } `
                              -UseBasicParsing -OutFile $tmp -ErrorAction Stop | Out-Null
            Remove-Item $tmp -ErrorAction SilentlyContinue
            return $u
        } catch {
            continue
        }
    }

    return $null
}


function Load-CollectionState {
    if (Test-Path -Path $CollectionStateFile) {
        try {
            $rawContent = Get-Content -Path $CollectionStateFile -Raw
            Write-Host "Raw State File Content: $rawContent"
            $state = $rawContent | ConvertFrom-Json -Depth 10

            if ($state -eq $null) {
                Log-Message -Type "WRN" -Message "Warning: Parsed state is null. Initializing as empty."
                return @{}
            }

            if ($state -is [PSCustomObject]) {
                $result = @{}
                foreach ($prop in $state.PSObject.Properties) {
                    $result[$prop.Name] = $prop.Value
                }
                return $result
            }

            return $state
        } catch {
            Log-Message -Type "ERR" -Message "Failed to load or parse state file: $_. Initializing as empty."
            return @{}
        }
    } else {
        Log-Message -Type "WRN" -Message "State file does not exist. Initializing as empty."
        return @{}
    }
}


function Save-CollectionState {
    param (
        [hashtable]$state
    )

    $stringKeyedState = @{}
    foreach ($key in $state.Keys) {
        $stringKeyedState["$key"] = $state[$key]
    }

    try {
        $json = $stringKeyedState | ConvertTo-Json -Depth 10
        $tmp  = "$CollectionStateFile.tmp"

        # Write to a temp file first, then replace (reduces risk of partial writes)
        $json | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $CollectionStateFile -Force

        Log-Message -Type "SUC" -Message "Saved state to $CollectionStateFile"
    } catch {
        Log-Message -Type "ERR" -Message "Failed to save state: $_"
    }
}

# Function to calculate the calendar date
function Calculate-Date {
    param (
        [Parameter(Mandatory=$true)]
        [datetime]$addDate,

        [Parameter(Mandatory=$true)]
        [int]$deleteAfterDays
    )

    Log-Message -Type "INF" -Message "Attempting to parse date: $addDate"
    $deleteDate = $addDate.AddDays($deleteAfterDays)
    
    # Format the date using the specified culture
    $formattedDate = $deleteDate.ToString($DATE_FORMAT, $cultureInfo)

    if ($ENABLE_DAY_SUFFIX) {
        $daySuffix = switch ($deleteDate.Day) {
            1  { "st" }
            2  { "nd" }
            3  { "rd" }
            21 { "st" }
            22 { "nd" }
            23 { "rd" }
            31 { "st" }
            default { "th" }
        }
        $formattedDate = $formattedDate + $daySuffix
    }
    
    if ($ENABLE_UPPERCASE) {
        $formattedDate = $formattedDate.ToUpper()
    }
    
    return $formattedDate
}

function Get-TargetCollectionName {
    param([pscustomobject]$Collection)

    $isManual = $false
    if ($null -ne $Collection.manualCollection) {
        if ($Collection.manualCollection -is [bool]) { $isManual = $Collection.manualCollection }
        else {
            $s = "$($Collection.manualCollection)".ToLower()
            $isManual = ($s -eq "true" -or $s -eq "1" -or $s -eq "yes")
        }
    }

    $manualName = "$($Collection.manualCollectionName)".Trim()
    if ($isManual -and $manualName) {
        return $manualName
    }

    return "$($Collection.title)".Trim()
}


function Download-Poster {
    param (
        [string]$posterUrl,
        [string]$savePathBase
    )

    try {
        Log-Message -Type "INF" -Message "Downloading poster from: $posterUrl"

        $tempFile = "${savePathBase}.jpg"
        Invoke-WebRequest -Uri $posterUrl -Headers @{"X-Plex-Token"=$PLEX_TOKEN} -OutFile $tempFile -UseBasicParsing

        # Check if file size is too small (likely invalid)
        if ((Get-Item $tempFile).Length -lt 1024) {
            Log-Message -Type "WRN" -Message "Downloaded file at $tempFile is too small (<1 KB). Treating as invalid."
            Remove-Item -Path $tempFile -Force
            throw "Downloaded file too small to be valid image."
        }

        # Identify real file type
        $formatInfo = & magick "$tempFile" -format "%m" info:
        Log-Message -Type "INF" -Message "Actual format detected: $formatInfo"

        if ([string]::IsNullOrEmpty($formatInfo)) {
            Remove-Item -Path $tempFile -Force
            throw "Unable to detect format."
        }

        $ext = switch ($formatInfo.ToLower()) {
            "jpeg" { ".jpg" }
            "jpg" { ".jpg" }
            "png" { ".png" }
            "webp" { ".webp" }
            default { ".jpg" } # Safe fallback
        }

        # Correct final path
        $savePath = "${savePathBase}${ext}"

        if ($ext -ne ".jpg") {
            Move-Item -Path $tempFile -Destination $savePath -Force
        } else {
            $savePath = $tempFile
        }

        # Final validate
        if (-not (Validate-Poster -filePath $savePath)) {
            Log-Message -Type "WRN" -Message "Downloaded file at $savePath is not a valid image. Deleting file."
            Remove-Item -Path $savePath -Force
            throw "Invalid poster file format detected."
        }

        Log-Message -Type "SUC" -Message "Downloaded and saved poster to: $savePath"
        return $savePath
    } catch {
        Log-Message -Type "WRN" -Message "Failed to download poster from $posterUrl. Error: $_"
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force
        }
        throw
    }
}

# Function to revert to the original poster
function Revert-ToOriginalPoster {
    param (
        [Parameter(Mandatory=$true)][string]$plexId,
        [Parameter(Mandatory=$true)][string]$originalImagePath
    )

    if (-not (Test-Path -Path $originalImagePath)) {
        Log-Message -Type "WRN" -Message "Original image not found for Plex ID: $plexId. Skipping revert."
        return $false
    }

    $ext = [System.IO.Path]::GetExtension($originalImagePath).ToLower()
    $contentType = switch ($ext) {
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".png"  { "image/png"  }
        ".webp" { "image/webp" }
        default { "application/octet-stream" }
    }

    $uploadUrl = "$PLEX_URL/library/metadata/$plexId/posters?X-Plex-Token=$PLEX_TOKEN"

    try {
        Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster ($ext)."
        $posterBytes = [System.IO.File]::ReadAllBytes($originalImagePath)
        Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType $contentType -ErrorAction Stop
        Log-Message -Type "SUC" -Message "Reverted Plex ID: $plexId to original."
        return $true
    } catch {
        Log-Message -Type "ERR" -Message "Failed to revert Plex ID: $plexId. Error: $_"
        return $false
    }
}


function Reset-AllOverlays {
    $state = Load-CollectionState
    if (-not $state -or $state.Keys.Count -eq 0) {
        Log-Message -Type "INF" -Message "No processed state to reset. Nothing to do."
        return
    }

    $processed = @(
        $state.GetEnumerator() |
        Where-Object {
            $v = $_.Value
            if ($v -is [bool]) { return ($v -eq $true) }
            if ($v -is [string]) { return ($v -eq "true") }
            if ($v -is [pscustomobject] -or $v -is [hashtable]) {
                return (("$($v.processed)") -eq "True")
            }
            return $false
        } | Select-Object -ExpandProperty Key
    )

    if (-not $processed -or $processed.Count -eq 0) {
        Log-Message -Type "INF" -Message "No items marked as processed. Nothing to revert."
    } else {
        Log-Message -Type "INF" -Message "Reverting overlays for $($processed.Count) items..."
        foreach ($plexId in $processed) {
            $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
            if ($posterFiles -and $posterFiles.Count -gt 0) {
                $originalImagePath = $posterFiles[0].FullName
                $ok = Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
                if ($ok) {
                    try {
                        Remove-Item -Path $originalImagePath -Force -ErrorAction Stop
                        Log-Message -Type "INF" -Message "Deleted original poster after revert for Plex ID $plexId."
                    } catch {
                        Log-Message -Type "WRN" -Message "Could not delete original poster for ${plexId}: $_"
                    }
                }
            } else {
                Log-Message -Type "WRN" -Message "Original poster not found for Plex ID $plexId in '$ORIGINAL_IMAGE_PATH'."
            }
        }
    }

    # Clear state and purge temp folder
    Save-CollectionState -state @{}
    Log-Message -Type "SUC" -Message "Reset complete. State cleared and original poster files deleted."

    # Clean temp images created during overlays
    try {
        Get-ChildItem -Path $TEMP_IMAGE_PATH -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Log-Message -Type "INF" -Message "Cleaned up temporary images in '$TEMP_IMAGE_PATH'."
    } catch { }
}

function Add-Overlay {
    param (
        [string]$imagePath,
        [string]$text,
        [string]$fontColor = $FONT_COLOR,
        [string]$backColor = $BACK_COLOR,
        [string]$fontPath  = $FONT_PATH,

        [string]$fontSizeValue         = $FONT_SIZE,          # % of height
        [string]$paddingValue          = $PADDING,            # % of height
        [string]$backRadiusValue       = $BACK_RADIUS,        # % of height
        [string]$horizontalOffsetValue = $HORIZONTAL_OFFSET,  # % of width
        [string]$verticalOffsetValue   = $VERTICAL_OFFSET,    # % of height
        [string]$horizontalAlign       = $HORIZONTAL_ALIGN,
        [string]$verticalAlign         = $VERTICAL_ALIGN
    )

    function Normalize-IMColor([string]$c) {
        if (-not $c) { return $null }
        $t=$c.Trim()
        if ($t -match '^#([0-9A-Fa-f]{8})$') {
            $hex=$matches[1]
            $r=[Convert]::ToInt32($hex.Substring(0,2),16)
            $g=[Convert]::ToInt32($hex.Substring(2,2),16)
            $b=[Convert]::ToInt32($hex.Substring(4,2),16)
            $a=[Convert]::ToInt32($hex.Substring(6,2),16)/255
            return "rgba($r,$g,$b,$a)"
        }
        return $t
    }

    function To-Fraction([string]$v) {
        if ([string]::IsNullOrWhiteSpace($v)) { return 0.0 }
        $s = $v.Trim().Replace("%","")
        if (-not ($s -match "^[0-9]*\.?[0-9]+$")) { return 0.0 }
        $n = [double]$s
        if ($n -le 1.0) { return $n } else { return $n/100.0 }
    }

    # 1) Image size
    $dims = & magick "$imagePath" -format "%w %h" info:
    if ($LASTEXITCODE -ne 0 -or -not $dims) { throw "Could not read image dimensions." }
    $imgW,$imgH = ($dims -split ' ') | ForEach-Object {[int]$_}

    # 2) Percentages
    $fontFrac   = To-Fraction $fontSizeValue
    $padFrac    = To-Fraction $paddingValue
    $radFrac    = To-Fraction $backRadiusValue
    $offXFrac   = To-Fraction $horizontalOffsetValue
    $offYFrac   = To-Fraction $verticalOffsetValue

    # 3) Font sizing
    $widthBudgetPct = 0.88
    $minFontFrac    = 0.02
    $maxFontFrac    = 0.10

    $pointSize = [math]::Round($imgH * ([math]::Min($maxFontFrac,[math]::Max($minFontFrac,$fontFrac))))
    $maxBoxW   = [math]::Floor($imgW * $widthBudgetPct)

    # 4) Gravity (for anchor logic only)
    $gX = switch (($horizontalAlign ?? "center").ToLower()) { 
        "left" {"West"} "center" {"Center"} "right" {"East"} default {"Center"} 
    }
    $gY = switch (($verticalAlign ?? "bottom").ToLower()) { 
        "top"  {"North"} "center" {"Center"} "bottom" {"South"} default {"South"} 
    }

    # 5) Render label + shrink-to-fit
    $tmpDir = $TEMP_IMAGE_PATH
    $label  = Join-Path $tmpDir "label.png"
    function RenderLabel([int]$pt) {
        Remove-Item -Path $label -ErrorAction SilentlyContinue
        & magick -background none -fill "$fontColor" -font "$fontPath" -pointsize $pt label:"$text" -alpha set "$label"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $label)) { return $null }
        $d = & magick "$label" -format "%w %h" info:
        if (-not $d) { return $null }
        $w,$h = ($d -split ' ') | ForEach-Object {[int]$_}
        return @{W=$w;H=$h}
    }

    $m = RenderLabel $pointSize
    if (-not $m) { throw "Initial label render failed." }
    while ($m.W -gt $maxBoxW -and $pointSize -gt [math]::Round($imgH*$minFontFrac)) {
        $pointSize = [math]::Max([math]::Round($imgH*$minFontFrac), $pointSize - [math]::Ceiling([math]::Max(1,$pointSize*0.08)))
        $m = RenderLabel $pointSize
        if (-not $m) { throw "Label render failed during shrink-to-fit." }
    }

    $labelW,$labelH = [int]$m.W, [int]$m.H

    # 6) Padding & radius
    $padPx = [math]::Max(2, [math]::Round([math]::Max($imgH*$padFrac, $pointSize*0.45)))
    $radPx = [math]::Round([math]::Max($imgH*$radFrac, $pointSize*0.35))

    $targetW = $labelW + 2*$padPx
    $targetH = $labelH + 2*$padPx
    $effRad  = [math]::Min($radPx, [math]::Floor([math]::Min($targetW,$targetH)/2))

    # 7) Background pill
    $backColorNorm = Normalize-IMColor $backColor
    $transparentBg = -not ($backColorNorm -and $backColorNorm.Trim().ToLower() -notin @("none","transparent"))

    $labelWithBg = Join-Path $tmpDir "label_bg.png"
    Remove-Item -Path $labelWithBg -ErrorAction SilentlyContinue
    if ($transparentBg) {
        & magick "$label" -alpha set -bordercolor none -border $padPx "$labelWithBg"
    } else {
        $bg = Join-Path $tmpDir "bg.png"
        $draw = "roundrectangle 0,0 $($targetW-1),$($targetH-1) $effRad,$effRad"
        & magick -size "${targetW}x${targetH}" canvas:none -alpha set -fill "$backColorNorm" -draw "$draw" "$bg"
        & magick "$bg" -alpha set "$label" -alpha set -gravity center -compose over -composite "$labelWithBg"
        Remove-Item -Path $bg -ErrorAction SilentlyContinue
    }

    # 8) Shadow
    $shadowed = Join-Path $tmpDir "label_shadow.png"
    & magick "$labelWithBg" -alpha set "(" "+clone" "-alpha" "set" "-background" "black" "-shadow" "60x3+3+3" ")" `
        "+swap" "-background" "none" "-layers" "merge" "+repage" -alpha set "$shadowed"

    # 9) Compute anchor coordinates (NorthWest gravity always)
    $anchorX = switch ($gX) {
        "West"   { [math]::Round($imgW * $offXFrac) }
        "Center" { [math]::Round(($imgW - $targetW) / 2) + [math]::Round($imgW * $offXFrac) }
        "East"   { $imgW - $targetW - [math]::Round($imgW * $offXFrac) }
    }
    $anchorY = switch ($gY) {
        "North"  { [math]::Round($imgH * $offYFrac) }
        "Center" { [math]::Round(($imgH - $targetH) / 2) + [math]::Round($imgH * $offYFrac) }
        "South"  { $imgH - $targetH - [math]::Round($imgH * $offYFrac) }
    }

    # 10) Composite (always with NorthWest gravity now)
    $outPath = Join-Path -Path $TEMP_IMAGE_PATH -ChildPath ([IO.Path]::GetFileName($imagePath))
    & magick "$imagePath" "$shadowed" -gravity NorthWest -geometry +$anchorX+$anchorY -compose over -composite "$outPath"

    # Cleanup
    Remove-Item -Path $label,$labelWithBg,$shadowed -ErrorAction SilentlyContinue
    return $outPath
}


# Function to upload the modified poster back to Plex
function Upload-Poster {
    param (
        [Parameter(Mandatory=$true)][string]$posterPath,
        [Parameter(Mandatory=$true)][string]$metadataId
    )

    $uploadUrl = "$PLEX_URL/library/metadata/$metadataId/posters"
    $extension = [System.IO.Path]::GetExtension($posterPath).ToLower()

    switch ($extension) {
        ".jpg"  { $contentType = "image/jpeg" }
        ".jpeg" { $contentType = "image/jpeg" }
        ".png"  { $contentType = "image/png"  }
        ".webp" { $contentType = "image/webp" }
        default { $contentType = "application/octet-stream" }
    }

    $posterBytes = [System.IO.File]::ReadAllBytes($posterPath)

    Log-Message -Type "DBG" -Message "POST $uploadUrl (token in header, Content-Type: $contentType)"
    Invoke-RestMethod -Uri $uploadUrl `
        -Method POST `
        -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
        -Body $posterBytes `
        -ContentType $contentType `
        -ErrorAction Stop

    try {
        Remove-Item -Path $posterPath -ErrorAction Stop
        Log-Message -Type "INF" -Message "Deleted temporary file: $posterPath"
    } catch {
        Log-Message -Type "WRN" -Message "Failed to delete temporary file ${posterPath}: $_"
    }
}

function Get-PlexCollectionItemIds {
    param(
        [Parameter(Mandatory=$true)][string]$MAINTAINERR_URL,
        [Parameter(Mandatory=$true)][string]$PLEX_URL,
        [Parameter(Mandatory=$true)][string]$PLEX_TOKEN,
        [Parameter(Mandatory=$true)][string]$LibrarySectionId,
        [Parameter(Mandatory=$true)][string]$CollectionName
    )

    # Find the collection ratingKey via Maintainerr proxy
    $collectionsUrl = "$MAINTAINERR_URL/api/plex/library/$LibrarySectionId/collections"
    $collectionsResponse = Invoke-RestMethod -Uri $collectionsUrl -ErrorAction Stop
    $found = $collectionsResponse | Where-Object { $_.title -ieq $CollectionName }
    if (-not $found) {
        Log-Message -Type "WRN" -Message "Plex collection '$CollectionName' not found in section $LibrarySectionId."
        return @()
    }

    $collectionId = $found.ratingKey

    # Fetch items in the collection directly from Plex
    $itemsUrl = "$PLEX_URL/library/metadata/$collectionId/children"
    $resp = Invoke-RestMethod -Uri $itemsUrl -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop

    $mc = $resp.MediaContainer
    if (-not $mc) { return @() }

    # Items can be Video/Directory depending on lib type - normalize to an array
    $nodes = @()
    foreach ($name in @('Video','Directory','Photo','Metadata')) {
        if ($mc.$name) { $nodes += $mc.$name }
    }
    if (-not $nodes) { return @() }

    $ids = @()
    foreach ($n in $nodes) {
        # ratingKey is the metadata id = PlexId
        if ($n.ratingKey) { $ids += "$($n.ratingKey)" }
    }
    return @($ids | Select-Object -Unique)
}

function Validate-Poster {
    param (
        [string]$filePath
    )
    try {
        $result = & magick "$filePath" -format "%m" info:
        if ($LASTEXITCODE -eq 0) {
            return $true
        } else {
            Log-Message -Type "ERR" -Message "File at $filePath is not a valid image (identify failed)."
            return $false
        }
    } catch {
        Log-Message -Type "ERR" -Message "File at $filePath is not a valid image. Error: $_"
        return $false
    }
}


# Function to perform janitorial tasks: revert and delete unused posters
function Janitor-Posters {
    param (
        [array]$mediaList,          # List of current Plex media GUIDs
        [array]$maintainerrGUIDs,   # List of GUIDs in the Maintainerr collection
        [hashtable]$newState,       # Current valid state from Process-MediaItems
        [string]$originalImagePath, # Path to original poster images
        [string]$collectionName     # Name of the collection for context/logging
    )

    Log-Message -Type "INF" -Message "Running janitorial logic for collection: $collectionName"

    # Gather all downloaded posters (any image extension)
    $downloadedPosters = Get-ChildItem -Path $originalImagePath -Include *.jpg, *.jpeg, *.png, *.webp -Recurse |
        ForEach-Object { @{ BaseName = $_.BaseName; FullName = $_.FullName } }

    $downloadedGUIDs = $downloadedPosters | Select-Object -ExpandProperty BaseName

    # GUIDs considered valid (in Plex, in Maintainerr, or in newState)
    $validGUIDs = $mediaList + $maintainerrGUIDs + $newState.Keys

    # GUIDs to handle
    $unusedGUIDs = $downloadedGUIDs | Where-Object { $_ -notin $validGUIDs }
    $revertGUIDs = $downloadedGUIDs | Where-Object { $_ -in $mediaList -and $_ -notin $maintainerrGUIDs }

    # Revert posters for media still in Plex but no longer in Maintainerr
    foreach ($guid in $revertGUIDs) {
        $poster = $downloadedPosters | Where-Object { $_.BaseName -eq $guid }
        if ($poster) {
            Log-Message -Type "INF" -Message "Reverting poster for GUID: $guid"
            Revert-ToOriginalPoster -plexId $guid -originalImagePath $poster.FullName
            Remove-Item -Path $poster.FullName -ErrorAction SilentlyContinue
        } else {
            Log-Message -Type "WRN" -Message "No poster file found to revert for GUID: $guid"
        }
    }

    # Delete posters for media removed from Plex or no longer valid
    foreach ($guid in $unusedGUIDs) {
        $poster = $downloadedPosters | Where-Object { $_.BaseName -eq $guid }
        if ($poster) {
            Log-Message -Type "INF" -Message "Deleting unused poster for GUID: $guid"
            Remove-Item -Path $poster.FullName -ErrorAction SilentlyContinue
        }
    }
}

  function Test-PlexItemExistsLocal {
        param([Parameter(Mandatory=$true)][string]$PlexId)
        try {
            $url = "$PLEX_URL/library/metadata/$PlexId"
            $null = Invoke-RestMethod -Uri $url -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
            return $true
        } catch { return $false }
    }

function Process-MediaItems {
    $collectionsUrl = "$MAINTAINERR_URL/api/collections"
    Log-Message -Type "DBG" -Message "Resolved collectionsUrl = '$collectionsUrl'"

    try {
        $maintainerrData = Invoke-RestMethod -Uri $collectionsUrl -Method Get
        Log-Message -Type "INF" -Message "Fetched collection data from Maintainerr."
    } catch {
        Log-Message -Type "ERR" -Message "Failed to fetch Maintainerr data from $collectionsUrl. Error: $_"
        return
    }

    # Load current state and ensure keys are strings
    $loadedState = Load-CollectionState
    $currentState = @{}
    foreach ($entry in $loadedState.GetEnumerator()) {
        $currentState["$($entry.Key)"] = $entry.Value
    }

    $newState = @{}

    foreach ($collection in $maintainerrData) {
        # Resolve target name (manual vs automatic)
        $TargetCollectionName = Get-TargetCollectionName -Collection $collection
        $IsManual = ($TargetCollectionName -ne $collection.title)
        if ($IsManual) {
            Log-Message -Type "INF" -Message "Detected custom (manual) collection. Using Plex collection name: '$TargetCollectionName' (from manualCollectionName)."
        } else {
            Log-Message -Type "DBG" -Message "Using Maintainerr title as Plex collection name: '$TargetCollectionName'."
        }

        Log-Message -Type "INF" -Message "Processing collection: $($collection.title)"
        $deleteAfterDays   = $collection.deleteAfterDays
        $LibrarySectionId  = $collection.libraryId
        if (-not $LibrarySectionId) { $LibrarySectionId = "2" }
        $CollectionName    = $TargetCollectionName

        # Filter by configured list
        if ("*" -notin $collectionsToReorder) {
            $namesToCheck = @("$($collection.title)","$CollectionName") | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
            $shouldProcess = $false
            foreach ($n in $namesToCheck) {
                if ($n -in $collectionsToReorder) { $shouldProcess = $true; break }
            }
            # AFTER:
if (-not $shouldProcess) {
    Log-Message -Type "INF" -Message "Skipping collection: '$($collection.title)' (target: '$CollectionName'). Carrying state forward."
    foreach ($item in $collection.media) {
        $plexId = "$($item.plexId)"
        # If we have prior state, keep it - otherwise mark as untouched
        $prior = $currentState["$plexId"]
        if ($null -ne $prior) {
            $newState["$plexId"] = $prior
        } else {
            
            $newState["$plexId"] = @{ processed = $false; deleteDate = $null }
        }
    }
    continue
}
        }

       # Build sortable list
$mediaList = @()
foreach ($item in $collection.media) {
    $plexId     = $item.plexId.ToString()
    $deleteDate = $item.addDate.AddDays($deleteAfterDays)
    $mediaList += [PSCustomObject]@{
        PlexId     = $plexId
        DeleteDate = $deleteDate
        Item       = $item
    }
}

# If Maintainerr reports nothing, carry state forward using actual Plex collection items
if (-not $mediaList -or $mediaList.Count -eq 0) {
    Log-Message -Type "INF" -Message "Collection '$CollectionName' has no items from Maintainerr. Carrying state forward from Plex and skipping."
    $plexIdsInCollection = Get-PlexCollectionItemIds -MAINTAINERR_URL $MAINTAINERR_URL -PLEX_URL $PLEX_URL -PLEX_TOKEN $PLEX_TOKEN -LibrarySectionId $LibrarySectionId -CollectionName $CollectionName
    foreach ($mid in $plexIdsInCollection) {
        $prior = $currentState["$mid"]
        if ($null -ne $prior) {
            $newState["$mid"] = $prior
        } else {
            
            $newState["$mid"] = @{ processed = $false; deleteDate = $null }
        }
    }
    continue
}

        $sortedMedia = $mediaList | Sort-Object -Property DeleteDate

        foreach ($media in $sortedMedia) {
            $item   = $media.Item
            $plexId = $media.PlexId

            # New deletion date
            $deleteDateUtc    = ($media.DeleteDate).ToUniversalTime()
            $newDeleteDateIso = $deleteDateUtc.ToString("o")

            # Read prior state 
            $prior = $currentState["$plexId"]
            $priorProcessed = $false
            $priorDeleteDateIso = $null

            if     ($prior -is [bool])          { $priorProcessed = $prior }
            elseif ($prior -is [string])        { $priorProcessed = ($prior -eq "true") }
            elseif ($prior -is [pscustomobject] -or $prior -is [hashtable]) {
                $priorProcessed     = (("$($prior.processed)") -eq "True")
                $priorDeleteDateIso = "$($prior.deleteDate)"
            }

            # Compare on date-only
            function To-DateOnlyIso([datetime]$dt) { return $dt.ToUniversalTime().ToString("yyyy-MM-dd") }

            $priorDateOnly = $null
            if ($priorDeleteDateIso) {
                try { $priorDateOnly = (Get-Date $priorDeleteDateIso).ToUniversalTime().ToString("yyyy-MM-dd") } catch { $priorDateOnly = $priorDeleteDateIso }
            }
            $newDateOnly = To-DateOnlyIso $media.DeleteDate

            $needsReoverlayDueToDateChange = $false
            if ($priorProcessed -and $priorDateOnly) {
                if ($priorDateOnly -ne $newDateOnly) {
                    $needsReoverlayDueToDateChange = $true
                    Log-Message -Type "INF" -Message "Delete date changed for $plexId. Old=$priorDateOnly New=$newDateOnly → will rebuild overlay."
                }
            }

            # Case 1: Already processed, date unchanged, and reapply disabled - skip (carry state forward)
            if (-not $needsReoverlayDueToDateChange -and -not $REAPPLY_OVERLAY -and $priorProcessed) {
                Log-Message -Type "INF" -Message "Skipping Plex ID: $plexId (already processed; date unchanged)."
                $newState["$plexId"] = @{
                    processed  = $true
                    deleteDate = $deleteDateUtc.ToString("o")
                }
                continue
            }

            # Otherwise:
            #  date changed - ALWAYS rebuild (even if REAPPLY_OVERLAY=false) or REAPPLY_OVERLAY=true - rebuild
            try {
                # Always base overlay on the ORIGINAL file if available else download ONCE and keep.
                $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
                if ($posterFiles -and $posterFiles.Count -gt 0) {
                    $originalImagePath = $posterFiles[0].FullName
                    Log-Message -Type "INF" -Message "Using saved original for $plexId ($([IO.Path]::GetExtension($originalImagePath)))"
                } else {
                    $posterUrl = Get-BestPlexImageUrl -MetadataId $plexId
                    if (-not $posterUrl) {
                        Log-Message -Type "WRN" -Message "No usable image found for Plex ID: $plexId (server=$PLEX_URL). Skipping."
                        $newState["$plexId"] = @{
                            processed  = $false
                            deleteDate = $newDeleteDateIso
                        }
                        continue
                    }
                    Log-Message -Type "WRN" -Message "Original poster not found for $plexId. Downloading once and saving as original..."
                    $originalImagePath = Download-Poster -posterUrl $posterUrl -savePathBase ("$ORIGINAL_IMAGE_PATH/$plexId")
                }

                # Build overlay from ORIGINAL - TEMP - upload
                $ext = [System.IO.Path]::GetExtension($originalImagePath)
                $tempImagePath = Join-Path $TEMP_IMAGE_PATH "$plexId$ext"
                Copy-Item -Path $originalImagePath -Destination $tempImagePath -Force

                $formattedDate = Calculate-Date -addDate $item.addDate -deleteAfterDays $deleteAfterDays
                Log-Message -Type "INF" -Message "Item $plexId formatted date: $formattedDate"

                $tempImagePath = Add-Overlay -imagePath $tempImagePath -text "$OVERLAY_TEXT $formattedDate"
                Upload-Poster -posterPath $tempImagePath -metadataId $plexId

                # Save new state (object with deleteDate)
                $newState["$plexId"] = @{
                    processed  = $true
                    deleteDate = $newDeleteDateIso
                }
                Log-Message -Type "INF" -Message "Updated state for ${plexId}: processed=true, deleteDate=$newDeleteDateIso"
            } catch {
                Log-Message -Type "WRN" -Message "Failed to process Plex ID: $plexId. Error: $_"
            }
        }

        

       # Sort collection in Plex (candidate order from Maintainerr)
$sortedPlexIds = @($sortedMedia | ForEach-Object { $_.PlexId })  # force array

# Quick skips
if (-not $sortedPlexIds -or $sortedPlexIds.Count -eq 0) {
    Log-Message -Type "INF" -Message "Skipping reorder for '$CollectionName' (Maintainerr reports no items)."
    continue
}
if ($sortedPlexIds.Count -eq 1) {
    Log-Message -Type "INF" -Message "Skipping reorder for '$CollectionName' (only one item)."
    continue
}

# Fetch actual Plex collection items
$plexCollectionIds = Get-PlexCollectionItemIds -MAINTAINERR_URL $MAINTAINERR_URL -PLEX_URL $PLEX_URL -PLEX_TOKEN $PLEX_TOKEN -LibrarySectionId $LibrarySectionId -CollectionName $CollectionName

if (-not $plexCollectionIds -or $plexCollectionIds.Count -eq 0) {
    Log-Message -Type "INF" -Message "Skipping reorder for '$CollectionName' (Plex collection is empty)."
    continue
}

# Compare sets
$maintSet = @($sortedPlexIds | Sort-Object -Unique)
$plexSet  = @($plexCollectionIds | Sort-Object -Unique)

$maintOnly = Compare-Object -ReferenceObject $maintSet -DifferenceObject $plexSet -PassThru | Where-Object { $_ -in $maintSet }
$plexOnly  = Compare-Object -ReferenceObject $plexSet  -DifferenceObject $maintSet -PassThru | Where-Object { $_ -in $plexSet  }

if ($maintOnly.Count -gt 0 -or $plexOnly.Count -gt 0) {
    Log-Message -Type "WRN" -Message ("Collection membership mismatch for '$CollectionName'. " +
        "Maintainerr-only: [{0}] | Plex-only: [{1}]" -f ($maintOnly -join ','), ($plexOnly -join ','))
    Log-Message -Type "INF" -Message "Skipping reorder until memberships match."
    continue
}

Set-PlexCollectionOrder `
    -MAINTAINERR_URL $MAINTAINERR_URL `
    -PLEX_URL $PLEX_URL `
    -PLEX_TOKEN $PLEX_TOKEN `
    -LibrarySectionId $LibrarySectionId `
    -CollectionName $CollectionName `
    -SortedPlexIds $sortedPlexIds
    }

    # Handle removals (restore and delete)
foreach ($plexId in $currentState.Keys) {
    if (-not $newState.ContainsKey($plexId)) {
        Log-Message -Type "INF" -Message "Item $plexId detected as removed (not in newState)."

        $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
        $originalImagePath = if ($posterFiles) { $posterFiles[0].FullName } else { $null }

        if (-not $originalImagePath -or -not (Test-Path -Path $originalImagePath)) {
            Log-Message -Type "WRN" -Message "Original poster not found for Plex ID: $plexId. Skipping revert."
            continue
        }

        if (-not (Test-PlexItemExistsLocal -PlexId $plexId)) {
            # Media no longer exists in Plex - just delete the saved original
            Log-Message -Type "INF" -Message "Plex ID: $plexId no longer exists in Plex. Deleting saved original."
            Remove-Item -Path $originalImagePath -Force -ErrorAction SilentlyContinue
            continue
        }

        # Still exists → revert and then delete the saved original
        Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster."
        $ok = Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
        if ($ok) {
            Remove-Item -Path $originalImagePath -Force -ErrorAction SilentlyContinue
            Log-Message -Type "INF" -Message "Deleted original poster after revert for Plex ID $plexId."
        }
        continue
    } else {
        Log-Message -Type "INF" -Message "Item $plexId is still in the collection."
    }
}

    # Janitorial cleanup
    $plexGUIDs        = $currentState.Keys
    $maintainerrGUIDs = $newState.Keys
    Janitor-Posters -mediaList $plexGUIDs -maintainerrGUIDs $maintainerrGUIDs -newState $newState -originalImagePath $ORIGINAL_IMAGE_PATH -collectionName "All Media"

    # Save updated state (string keys)
    $tempState = @{}
    foreach ($key in $newState.Keys) {
        $tempState["$key"] = $newState[$key]
    }
    Log-Message -Type "INF" -Message "Saving State: $(ConvertTo-Json $tempState -Depth 10)"
    Save-CollectionState -state $newState
}


if (-not (Test-Path -Path $IMAGE_SAVE_PATH)) {
    New-Item -ItemType Directory -Path $IMAGE_SAVE_PATH
}
if (-not (Test-Path -Path $ORIGINAL_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $ORIGINAL_IMAGE_PATH
}
if (-not (Test-Path -Path $TEMP_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $TEMP_IMAGE_PATH
}

function Set-PlexCollectionOrder {
    param(
        [Parameter(Mandatory=$true)][string]$MAINTAINERR_URL,
        [Parameter(Mandatory=$true)][string]$PLEX_TOKEN,
        [Parameter(Mandatory=$true)][string]$PLEX_URL,
        [Parameter(Mandatory=$true)][string]$LibrarySectionId,
        [Parameter(Mandatory=$true)][string]$CollectionName,
        [Parameter(Mandatory=$true)][array]$SortedPlexIds
    )

    # Determine order (asc/desc) from env var
    $order = $env:PLEX_COLLECTION_ORDER
    if (-not $order) { $order = "asc" }
    $order = $order.ToLower()

    switch ($order) {
        "asc"  { $finalOrder = $SortedPlexIds }
        "desc" { 
            $finalOrder = $SortedPlexIds.Clone()
            [Array]::Reverse($finalOrder)
        }
        default {
            Log-Message -Type "WRN" -Message "Unknown order '$order', defaulting to ascending."
            $finalOrder = $SortedPlexIds
        }
    }

    # 1) Find collection (via Maintainerr proxy)
    $collectionsUrl = "$MAINTAINERR_URL/api/plex/library/$LibrarySectionId/collections"
    try {
        Log-Message -Type "DBG" -Message "GET $collectionsUrl"
        $collectionsResponse = Invoke-RestMethod -Uri $collectionsUrl -ErrorAction Stop
        $foundCollection = $collectionsResponse | Where-Object { $_.title -ieq $CollectionName }
        if (-not $foundCollection) {
            Log-Message -Type "ERR" -Message "Could not find collection '$CollectionName' in library section $LibrarySectionId."
            return
        }
        $collectionId = $foundCollection.ratingKey
        Log-Message -Type "INF" -Message "Found collection '$CollectionName' (ratingKey $collectionId) in library section $LibrarySectionId."
    } catch {
        Log-Message -Type "ERR" -Message "Failed to retrieve collections from Maintainerr in section ${LibrarySectionId}: $_"
        return
    }

    # 2) Put collection into custom sort mode (collectionSort=2)
    $setCustomSortUrl = "$PLEX_URL/library/metadata/$collectionId/prefs"
    $body = "collectionSort=2"
    try {
        Log-Message -Type "DBG" -Message "PUT $setCustomSortUrl (token in header, x-www-form-urlencoded)"
        Invoke-RestMethod -Uri $setCustomSortUrl `
            -Method PUT `
            -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
            -Body $body `
            -ContentType "application/x-www-form-urlencoded" `
            -ErrorAction Stop
        Log-Message -Type "INF" -Message "Set collection '$CollectionName' to custom sort mode."
    } catch {
        Log-Message -Type "ERR" -Message "Failed to set collection '$CollectionName' to custom sort: $_"
        return
    }

    # 3) Move each item after the previous
    for ($i = 1; $i -lt $finalOrder.Count; $i++) {
        $itemId  = $finalOrder[$i]
        $afterId = $finalOrder[$i - 1]
        $moveUrl = "$PLEX_URL/library/collections/$collectionId/items/$itemId/move?after=$afterId"
        try {
            Log-Message -Type "DBG" -Message "PUT $moveUrl (token in header)"
            Invoke-RestMethod -Uri $moveUrl `
                -Method PUT `
                -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
                -ErrorAction Stop
            Log-Message -Type "INF" -Message "Moved item $itemId after $afterId in collection $collectionId."
        } catch {
            Log-Message -Type "ERR" -Message "Failed to move item $itemId after '$afterId': $_"
        }
    }

    Log-Message -Type "SUC" -Message "Finished reordering collection '$CollectionName' ($order) with custom sort."
}


if ($RESET_OVERLAY) {
    Log-Message -Type "INF" -Message "RESET_OVERLAY is enabled. Reverting all processed posters and clearing state..."
    Reset-AllOverlays
    
    exit 0
}

Process-MediaItems
