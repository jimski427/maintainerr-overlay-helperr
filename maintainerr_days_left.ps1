# Define your Plex server and Maintainerr details
$PLEX_URL = $env:PLEX_URL
$PLEX_TOKEN = $env:PLEX_TOKEN
$MAINTAINERR_URL = $env:MAINTAINERR_URL
$IMAGE_SAVE_PATH = $env:IMAGE_SAVE_PATH
$ORIGINAL_IMAGE_PATH = $env:ORIGINAL_IMAGE_PATH
$TEMP_IMAGE_PATH = $env:TEMP_IMAGE_PATH
$FONT_PATH = $env:FONT_PATH
$FONT_COLOR = $env:FONT_COLOR
$BACK_COLOR = $env:BACK_COLOR
$FONT_SIZE = [int]$env:FONT_SIZE
$PADDING = [int]$env:PADDING
$BACK_RADIUS = [int]$env:BACK_RADIUS
$HORIZONTAL_OFFSET = [int]$env:HORIZONTAL_OFFSET
$HORIZONTAL_ALIGN = $env:HORIZONTAL_ALIGN
$VERTICAL_OFFSET = [int]$env:VERTICAL_OFFSET
$VERTICAL_ALIGN = $env:VERTICAL_ALIGN
$RUN_INTERVAL = [int]$env:RUN_INTERVAL
$OVERLAY_TEXT = $env:OVERLAY_TEXT
$ENABLE_DAY_SUFFIX = [bool]($env:ENABLE_DAY_SUFFIX -eq "true")
$ENABLE_UPPERCASE = [bool]($env:ENABLE_UPPERCASE -eq "true")
$LANGUAGE = $env:LANGUAGE 
$DATE_FORMAT = $env:DATE_FORMAT

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
if (-not $RUN_INTERVAL) {
    $RUN_INTERVAL = 8 * 60 * 60 # Default to 8 hours in seconds
} else {
    $RUN_INTERVAL = $RUN_INTERVAL * 60 # Convert minutes to seconds
}

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

function Load-CollectionState {
    if (Test-Path -Path $CollectionStateFile) {
        try {
            $rawContent = Get-Content -Path $CollectionStateFile -Raw
            Write-Host "Raw State File Content: $rawContent"

            # Enforce parsing into a valid object
            $state = $rawContent | ConvertFrom-Json -Depth 10

            if ($state -eq $null) {
                Log-Message -Type "WRN" -Message "Warning: Parsed state is null. Initializing as empty."
                return @{}
            }

            if ($state -is [PSCustomObject]) {
                return $state.PSObject.Properties | ForEach-Object { @{ $_.Name = $_.Value } }
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
        $stringKeyedState | ConvertTo-Json -Depth 10 | Set-Content -Path $CollectionStateFile
        Log-Message -Type "SUC" -Message "Saved state: $(ConvertTo-Json $stringKeyedState -Depth 10)"
    } catch {
        Log-Message -Type "ERR" -Message "Failed to save state: $_"
    }
}

# Function to get data from Maintainerr
function Get-MaintainerrData {
    if ($MAINTAINERR_URL -notmatch "/api/collections$") {
        $MAINTAINERR_URL = "$MAINTAINERR_URL/api/collections"
    }

    Log-Message -Type "INF" -Message "Fetching data from: $MAINTAINERR_URL"
    $response = Invoke-RestMethod -Uri $MAINTAINERR_URL -Method Get
    return $response
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
        [string]$plexId,
        [string]$originalImagePath
    )

    if (-not (Test-Path -Path $originalImagePath)) {
        Log-Message -Type "WRN" -Message "Original image not found for Plex ID: $plexId. Skipping revert."
        return
    }

    Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster."
    $uploadUrl = "$PLEX_URL/library/metadata/$plexId/posters?X-Plex-Token=$PLEX_TOKEN"
    $posterBytes = [System.IO.File]::ReadAllBytes($originalImagePath)
    Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType "image/jpeg"
}

function Add-Overlay {
    param (
        [string]$imagePath,
        [string]$text,
        [string]$fontColor = $FONT_COLOR,
        [string]$backColor = $BACK_COLOR,
        [string]$fontPath = $FONT_PATH,
        [int]$fontSize = $FONT_SIZE,
        [int]$padding = $PADDING,
        [int]$backRadius = $BACK_RADIUS,
        [int]$horizontalOffset = $HORIZONTAL_OFFSET,
        [string]$horizontalAlign = $HORIZONTAL_ALIGN,
        [int]$verticalOffset = $VERTICAL_OFFSET,
        [string]$verticalAlign = $VERTICAL_ALIGN
    )

    $fileName = [System.IO.Path]::GetFileName($imagePath)
    $outputImagePath = Join-Path -Path $TEMP_IMAGE_PATH -ChildPath $fileName

    # Get poster dimensions
    $dimensions = & magick "$imagePath" -format "%w %h" info:
    $width, $height = $dimensions -split " "

    # Scaling
    $scaleFactor = $width / 1000
    $scaledFontSize = [math]::Min([math]::Round($fontSize * $scaleFactor), 100)
    $scaledPadding = [math]::Round($padding * $scaleFactor)
    $scaledHorizontalOffset = [math]::Round($horizontalOffset * $scaleFactor)
    $scaledVerticalOffset = [math]::Round($verticalOffset * $scaleFactor)
    $scaledBackRadius = [math]::Round($backRadius * $scaleFactor)

    # Gravity alignment
    $gravityX = switch ($horizontalAlign.ToLower()) {
        "left"    { "West" }
        "center"  { "Center" }
        "right"   { "East" }
        default   { "Center" }
    }
    $gravityY = switch ($verticalAlign.ToLower()) {
        "top"     { "North" }
        "center"  { "Center" }
        "bottom"  { "South" }
        default   { "South" }
    }

    $gravity = if ($gravityY -eq "Center") {
        $gravityX
    } elseif ($gravityX -eq "Center") {
        $gravityY
    } else {
        "$gravityY$gravityX"
    }

    $labelPath = Join-Path -Path $TEMP_IMAGE_PATH -ChildPath "label.png"

    # Create label
    & magick -background "$backColor" `
             -fill "$fontColor" `
             -font "$fontPath" `
             -pointsize $scaledFontSize `
             label:"$text" `
             "$labelPath"

    # Add padding
    & magick "$labelPath" `
             -bordercolor "$backColor" `
             -border $scaledPadding `
             "$labelPath"

    # Rounded corners
    if ($scaledBackRadius -gt 0) {
        $labelDimensions = & magick "$labelPath" -format "%w %h" info:
        $labelWidth, $labelHeight = $labelDimensions -split " "
        $drawExpr = "roundrectangle 0,0 $($labelWidth - 1),$($labelHeight - 1) $scaledBackRadius,$scaledBackRadius"

        & magick "$labelPath" `
            "(" "+clone" "-alpha" "extract" "-draw" "$drawExpr" ")" `
            "-compose" "CopyOpacity" "-composite" `
            "$labelPath"
    }

    # Add shadow
    $shadowedLabelPath = Join-Path -Path $TEMP_IMAGE_PATH -ChildPath "shadowed_label.png"
    & magick "$labelPath" `
             "(" "+clone" "-background" "black" "-shadow" "60x3+3+3" ")" `
             "+swap" "-background" "none" "-layers" "merge" "+repage" `
             "$shadowedLabelPath"

    # Composite onto poster
    & magick "$imagePath" `
             "$shadowedLabelPath" `
             -gravity $gravity `
             -geometry +$scaledHorizontalOffset+$scaledVerticalOffset `
             -compose over -composite `
             "$outputImagePath"

    # Cleanup
    Remove-Item -Path $labelPath -ErrorAction SilentlyContinue
    Remove-Item -Path $shadowedLabelPath -ErrorAction SilentlyContinue

    return $outputImagePath
}


# Function to upload the modified poster back to Plex
function Upload-Poster {
    param (
        [string]$posterPath,
        [string]$metadataId
    )

    $uploadUrl = "$PLEX_URL/library/metadata/$metadataId/posters?X-Plex-Token=$PLEX_TOKEN"
    $extension = [System.IO.Path]::GetExtension($posterPath).ToLower()

    switch ($extension) {
        ".jpg" { $contentType = "image/jpeg" }
        ".jpeg" { $contentType = "image/jpeg" }
        ".png" { $contentType = "image/png" }
        ".webp" { $contentType = "image/webp" }
        default { $contentType = "application/octet-stream" }
    }

    $posterBytes = [System.IO.File]::ReadAllBytes($posterPath)
    Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType $contentType

    try {
        Remove-Item -Path $posterPath -ErrorAction Stop
        Log-Message -Type "INF" -Message "Deleted temporary file: $posterPath"
    } catch {
        Log-Message -Type "ERR" -Message "Failed to delete temporary file ${posterPath}: $_"
    }
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
            Write-WarLog-Message -Type "ERR" -Messagening "File at $filePath is not a valid image (identify failed)."
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

function Process-MediaItems {
    $maintainerrData = Get-MaintainerrData
    $currentState = Load-CollectionState

    # Initialize new state
    $newState = @{}

    foreach ($collection in $maintainerrData) {
        Log-Message -Type "INF" -Message "Processing collection: $($collection.Name)"
        $deleteAfterDays = $collection.deleteAfterDays

        foreach ($item in $collection.media) {
            $plexId = $item.plexId.ToString()

            # Find the original poster file, whatever the extension
            $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse
            $originalImagePath = if ($posterFiles) { $posterFiles[0].FullName } else { $null }

            # If no poster found yet, define default jpg
            if (-not $originalImagePath) {
                $originalImagePath = "$ORIGINAL_IMAGE_PATH/$plexId.jpg"
            }

            $ext = [System.IO.Path]::GetExtension($originalImagePath)
            $tempImagePath = "$TEMP_IMAGE_PATH/$plexId$ext"
            $posterUrl = "$PLEX_URL/library/metadata/$plexId/thumb?X-Plex-Token=$PLEX_TOKEN"

            # Add media item to new state
            $newState[$plexId] = $true
            Log-Message -Type "INF" -Message "Added to newState: Plex ID = $plexId, State = true"

            try {
                # Ensure the original poster is downloaded first
                if (-not (Test-Path -Path $originalImagePath)) {
                    Log-Message -Type "ERR" -Message "Original poster not found for Plex ID: $plexId. Downloading..."
                    $originalImagePath = Download-Poster -posterUrl $posterUrl -savePathBase ("$ORIGINAL_IMAGE_PATH/$plexId")

                    if (-not (Test-Path -Path $originalImagePath)) {
                        throw "Failed to download original poster for Plex ID: $plexId"
                    }
                } else {
                    Log-Message -Type "INF" -Message "Original poster already exists for Plex ID: $plexId."
                }

                # Calculate the formatted date for overlay
                $formattedDate = Calculate-Date -addDate $item.addDate -deleteAfterDays $deleteAfterDays
                Log-Message -Type "INF" -Message "Item $plexId has a formatted date: $formattedDate"

                # Apply overlay and upload the modified poster
                Copy-Item -Path $originalImagePath -Destination $tempImagePath -Force
                $tempImagePath = Add-Overlay -imagePath $tempImagePath -text "$OVERLAY_TEXT $formattedDate"
                Upload-Poster -posterPath $tempImagePath -metadataId $plexId
            } catch {
                Log-Message -Type "WRN" -Message "Failed to process Plex ID: $plexId. Error: $_"
            }
        }
    }

    # Compare currentState with newState to identify removed items
    foreach ($plexId in $currentState.Keys) {
        if (-not $newState.ContainsKey($plexId)) {
            Log-Message -Type "INF" -Message "Item $plexId detected as removed (not in newState)."

            # Find the original image
            $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse
            $originalImagePath = if ($posterFiles) { $posterFiles[0].FullName } else { $null }

            if ($originalImagePath -and (Test-Path -Path $originalImagePath)) {
                Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster."
                Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
            } else {
                Log-Message -Type "WRN" -Message "Original poster not found for Plex ID: $plexId. Skipping revert."
            }

            # Mark as removed
            $newState[$plexId] = $false
        } else {
            Log-Message -Type "INF" -Message "Item $plexId is still in the collection."
        }
    }

    # Run janitorial logic
    $plexGUIDs = $currentState.Keys
    $maintainerrGUIDs = $newState.Keys
    Janitor-Posters -mediaList $plexGUIDs -maintainerrGUIDs $maintainerrGUIDs -newState $newState -originalImagePath $ORIGINAL_IMAGE_PATH -collectionName "All Media"

    # Save the new state
    $tempState = @{}
    foreach ($key in $newState.Keys) {
        $tempState["$key"] = $newState[$key]
    }
    Log-Message -Type "INF" -Message "Saving State: $(ConvertTo-Json $tempState -Depth 10)"
    Save-CollectionState -state $newState
}


# Ensure the images directories exist
if (-not (Test-Path -Path $IMAGE_SAVE_PATH)) {
    New-Item -ItemType Directory -Path $IMAGE_SAVE_PATH
}
if (-not (Test-Path -Path $ORIGINAL_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $ORIGINAL_IMAGE_PATH
}
if (-not (Test-Path -Path $TEMP_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $TEMP_IMAGE_PATH
}

# Run the main function in a loop with the specified interval
while ($true) {
    Process-MediaItems
    Log-Message -Type "INF" -Message "Waiting for $RUN_INTERVAL seconds before the next run."
    Start-Sleep -Seconds $RUN_INTERVAL
}
