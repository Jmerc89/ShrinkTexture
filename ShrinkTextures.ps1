# ShrinkTextures.ps1
# Robust texture shrink tool using ImageMagick.
# - Recursive processing
# - Format selection + custom extensions
# - Reads supported formats on THIS machine (magick -list format)
# - Safe overwrite via temp file + atomic replace
# - Optional backups
# - Dry run mode
# - Logging
# - Excludes common cache/build folders
# - Optional normal-map skipping + pixel-art filter
# - NEW: Output format conversion (optional)

param(
    # Optional: allow passing a target root folder (from .cmd drag-drop)
    [string]$TargetFolder = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------- Helpers ----------------

function Assert-MagickAvailable {
    $cmd = Get-Command magick -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "ImageMagick 'magick' was not found in PATH. Install ImageMagick and ensure 'magick -version' works."
    }
}

function Should-ExcludePath([string]$fullPath) {
    # Covers Unity/Unreal + typical build/tooling folders
    $excludeParts = @(
        "\Library\", "\Temp\", "\obj\", "\Build\", "\Builds\", "\Logs\",
        "\Binaries\", "\DerivedDataCache\", "\Intermediate\", "\Saved\",
        "\.git\", "\.vs\", "\.idea\", "\node_modules\"
    )
    foreach ($p in $excludeParts) {
        if ($fullPath -like "*$p*") { return $true }
    }
    return $false
}

function Get-MagickFormats {
    # Parse `magick -list format` into objects: Ext, Module, Mode, Description
    # Expected columns: Format  Module  Mode  Description
    $lines = & magick -list format 2>$null
    if (-not $lines) { return @() }

    $formats = New-Object System.Collections.Generic.List[object]

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Skip headers/separators and continuation "See ..." lines
        if ($line -match "^\s*Format\s+Module\s+Mode\s+Description") { continue }
        if ($line -match "^\s*-+\s*$") { continue }
        if ($line -match "^\s*See\s+") { continue }

        $trim = $line.Trim()

        # Split into up to 4 parts: Format, Module, Mode, Description
        $parts = $trim -split "\s+", 4
        if ($parts.Count -lt 3) { continue }

        $fmtRaw = $parts[0]
        $module = $parts[1]
        $mode   = $parts[2]
        $desc   = if ($parts.Count -ge 4) { $parts[3] } else { "" }

        # Clean trailing * from format token
        $fmtClean = $fmtRaw.TrimEnd('*').Trim()
        if ($fmtClean.Length -eq 0) { continue }

        # Mode should look like r--, rw-, rw+, etc. If not, skip this row.
        if ($mode -notmatch "^[r-][w-][+-]?$") { continue }

        $formats.Add([pscustomobject]@{
            Ext = $fmtClean.ToLowerInvariant()
            Module = $module
            Mode = $mode
            Description = $desc
        }) | Out-Null
    }

    return $formats.ToArray()
}


function Get-MagickFormatsText([int]$maxLines = 200) {
    $lines = & magick -list format 2>$null
    if (-not $lines) { return "Could not query formats. Try: magick -list format" }
    return (($lines | Select-Object -First $maxLines) -join "`r`n")
}

function Ensure-Folder([string]$path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

function Normalize-Extensions([string[]]$extsFromChecklist, [string]$customText) {
    $set = New-Object System.Collections.Generic.HashSet[string]

    foreach ($e in $extsFromChecklist) {
        $x = $e.Trim().TrimStart(".").ToLowerInvariant()
        if ($x.Length -gt 0) { [void]$set.Add($x) }
    }

    if (-not [string]::IsNullOrWhiteSpace($customText)) {
        $customText.Split(",") | ForEach-Object {
            $x = $_.Trim().TrimStart(".").ToLowerInvariant()
            if ($x.Length -gt 0) { [void]$set.Add($x) }
        }
    }

    return @($set)
}

function Resize-ImageToTemp(
    [string]$filePath,
    [string]$tempPath,
    [int]$maxSize,
    [bool]$strip,
    [bool]$compressPng,
    [bool]$pixelArtMode,
    [string]$outputExt
) {
    # Decide output extension for options that depend on output format
    $outExtClean = $outputExt.Trim().TrimStart(".").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($outExtClean)) {
        # fallback to source extension
        $outExtClean = [System.IO.Path]::GetExtension($filePath).TrimStart(".").ToLowerInvariant()
    }

    $args = @($filePath)

    if ($strip) { $args += "-strip" }

    if ($pixelArtMode) {
        $args += "-filter"; $args += "point"
    }

    # Only shrink if larger than max, never upscale
    $args += "-resize"
    $args += "$($maxSize)x$($maxSize)>"

    # Only apply PNG compression flags when OUTPUT is PNG
    if ($compressPng -and $outExtClean -eq "png") {
        $args += "-define"
        $args += "png:compression-level=9"
    }

    $args += $tempPath

    & magick @args
    return $LASTEXITCODE
}

function Safe-ReplaceFile([string]$src, [string]$tmp) {
    Move-Item -Force $tmp $src
}

function Start-Log([string]$logPath) {
    "---- ShrinkTextures Run ----" | Out-File -FilePath $logPath -Encoding UTF8
    "Start: $(Get-Date -Format o)" | Out-File -FilePath $logPath -Append -Encoding UTF8
}

function Log-Line([string]$logPath, [string]$line) {
    $line | Out-File -FilePath $logPath -Append -Encoding UTF8
}

# ---------------- UI ----------------

function Show-ConfigDialog([string]$initialFolder) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $magickFormats = Get-MagickFormats

    $supportedSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $magickFormats) { [void]$supportedSet.Add($f.Ext) }

# Common alias normalization (ImageMagick lists formats like "tiff" but users expect "tif")
if ($supportedSet.Contains("tiff")) { [void]$supportedSet.Add("tif") }
if ($supportedSet.Contains("jpeg")) { [void]$supportedSet.Add("jpg") }
if ($supportedSet.Contains("jpe"))  { [void]$supportedSet.Add("jpg") }


  # Track writable formats (Mode contains "w" or "W")
$writableSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($f in $magickFormats) {
    if ($f.Mode -match "(?i)w") { [void]$writableSet.Add($f.Ext) }
}

# Alias writable formats too
if ($writableSet.Contains("tiff")) { [void]$writableSet.Add("tif") }
if ($writableSet.Contains("jpeg")) { [void]$writableSet.Add("jpg") }
if ($writableSet.Contains("jpe"))  { [void]$writableSet.Add("jpg") }


    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Shrink Textures (ImageMagick)"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(860, 620)
    $form.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(12, 10)
    $title.Text = "Downscale textures in a folder (recursive)"
    $form.Controls.Add($title)

    $folderLabel = New-Object System.Windows.Forms.Label
    $folderLabel.AutoSize = $true
    $folderLabel.Location = New-Object System.Drawing.Point(12, 44)
    $folderLabel.Text = "Target folder:"
    $form.Controls.Add($folderLabel)

    $folderText = New-Object System.Windows.Forms.TextBox
    $folderText.Location = New-Object System.Drawing.Point(120, 40)
    $folderText.Width = 560
    $folderText.ReadOnly = $true
    $folderText.Text = $initialFolder
    $form.Controls.Add($folderText)

    $pickFolder = New-Object System.Windows.Forms.Button
    $pickFolder.Text = "Browse..."
    $pickFolder.Width = 90
    $pickFolder.Location = New-Object System.Drawing.Point(710, 38)
    $pickFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select target folder"
        $dlg.SelectedPath = $folderText.Text
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $folderText.Text = $dlg.SelectedPath
        }
    })
    $form.Controls.Add($pickFolder)

    # Max size
    $sizeLabel = New-Object System.Windows.Forms.Label
    $sizeLabel.AutoSize = $true
    $sizeLabel.Location = New-Object System.Drawing.Point(5, 78)
    $sizeLabel.Text = "Max size (px):"
    $form.Controls.Add($sizeLabel)

    $sizeCombo = New-Object System.Windows.Forms.ComboBox
    $sizeCombo.DropDownStyle = 'DropDownList'
    $sizeCombo.Location = New-Object System.Drawing.Point(120, 74)
    $sizeCombo.Width = 120
    @("256","512","1024","2048","4096","8192") | ForEach-Object { [void]$sizeCombo.Items.Add($_) }
    $sizeCombo.SelectedItem = "1024"
    $form.Controls.Add($sizeCombo)

    $shrinkNote = New-Object System.Windows.Forms.Label
    $shrinkNote.AutoSize = $true
    $shrinkNote.Location = New-Object System.Drawing.Point(250, 78)
    $shrinkNote.Text = "Only shrinks (never upscales). Longest side fits within this size."
    $form.Controls.Add($shrinkNote)

    # Options (left column)
    $optStrip = New-Object System.Windows.Forms.CheckBox
    $optStrip.AutoSize = $true
    $optStrip.Location = New-Object System.Drawing.Point(12, 110)
    $optStrip.Text = "Strip metadata (recommended)"
    $optStrip.Checked = $true
    $form.Controls.Add($optStrip)

    $optCompress = New-Object System.Windows.Forms.CheckBox
    $optCompress.AutoSize = $true
    $optCompress.Location = New-Object System.Drawing.Point(12, 135)
    $optCompress.Text = "Max PNG compression (slower, smaller)"
    $optCompress.Checked = $true
    $form.Controls.Add($optCompress)

    $optSkipNormals = New-Object System.Windows.Forms.CheckBox
    $optSkipNormals.AutoSize = $true
    $optSkipNormals.Location = New-Object System.Drawing.Point(12, 160)
    $optSkipNormals.Text = "Skip files containing 'Normal' in name"
    $optSkipNormals.Checked = $false
    $form.Controls.Add($optSkipNormals)

    $optPixelArt = New-Object System.Windows.Forms.CheckBox
    $optPixelArt.AutoSize = $true
    $optPixelArt.Location = New-Object System.Drawing.Point(12, 185)
    $optPixelArt.Text = "Pixel art mode (nearest-neighbor)"
    $optPixelArt.Checked = $false
    $form.Controls.Add($optPixelArt)

    $optDryRun = New-Object System.Windows.Forms.CheckBox
    $optDryRun.AutoSize = $true
    $optDryRun.Location = New-Object System.Drawing.Point(12, 210)
    $optDryRun.Text = "Dry run (no files changed)"
    $optDryRun.Checked = $false
    $form.Controls.Add($optDryRun)

    $optBackup = New-Object System.Windows.Forms.CheckBox
    $optBackup.AutoSize = $true
    $optBackup.Location = New-Object System.Drawing.Point(12, 235)
    $optBackup.Text = "Create backups (.bak next to original)"
    $optBackup.Checked = $false
    $form.Controls.Add($optBackup)

    # Extensions selection group (right side)
    $extGroup = New-Object System.Windows.Forms.GroupBox
    $extGroup.Text = "File types to process"
    $extGroup.Location = New-Object System.Drawing.Point(430, 110)
    $extGroup.Size = New-Object System.Drawing.Size(410, 340)
    $form.Controls.Add($extGroup)

    $extList = New-Object System.Windows.Forms.CheckedListBox
    $extList.Location = New-Object System.Drawing.Point(12, 22)
    $extList.Size = New-Object System.Drawing.Size(180, 280)

    # Curated list. Mark as “(unsupported)” if not found in magick -list format
    $curated = @("png","jpg","jpeg","tga","tif","tiff","webp","bmp","gif","psd","exr","hdr","heic","jp2")
    foreach ($e in $curated) {
        $label = if ($supportedSet.Contains($e)) { $e } else { "$e (unsupported)" }
        [void]$extList.Items.Add($label)
    }

    # Default selections (safe-ish for game repos)
    foreach ($default in @("png","jpg","jpeg","tga","tif","tiff","webp")) {
        for ($i=0; $i -lt $extList.Items.Count; $i++) {
            if ($extList.Items[$i].ToString() -eq $default) {
                $extList.SetItemChecked($i, $true)
            }
        }
    }

    $extGroup.Controls.Add($extList)

    $customLabel = New-Object System.Windows.Forms.Label
    $customLabel.AutoSize = $true
    $customLabel.Location = New-Object System.Drawing.Point(205, 18)
    $customLabel.Text = "Custom extensions:"
    $extGroup.Controls.Add($customLabel)

    $customText = New-Object System.Windows.Forms.TextBox
    $customText.Location = New-Object System.Drawing.Point(205, 50)
    $customText.Width = 190
    $customText.Text = ""
    $extGroup.Controls.Add($customText)

    $customHint = New-Object System.Windows.Forms.Label
    $customHint.AutoSize = $true
    $customHint.Location = New-Object System.Drawing.Point(205, 75)
    $customHint.Text = "Comma-separated"
    $extGroup.Controls.Add($customHint)

    $showFormatsBtn = New-Object System.Windows.Forms.Button
    $showFormatsBtn.Text = "Show ImageMagick formats"
    $showFormatsBtn.Width = 190
    $showFormatsBtn.Location = New-Object System.Drawing.Point(205, 105)
    $showFormatsBtn.Add_Click({
        $txt = Get-MagickFormatsText 220
        [System.Windows.Forms.MessageBox]::Show(
            $txt,
            "ImageMagick Formats (this machine)",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })
    $extGroup.Controls.Add($showFormatsBtn)

    $warnLabel = New-Object System.Windows.Forms.Label
    $warnLabel.AutoSize = $true
    $warnLabel.Location = New-Object System.Drawing.Point(205, 145)
    $warnLabel.MaximumSize = New-Object System.Drawing.Size(190, 0)
    $warnLabel.Text = "Tip: Avoid overwriting source formats like PSD/EXR unless you mean it."
    $extGroup.Controls.Add($warnLabel)

    # Log options
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Logging"
    $logGroup.Location = New-Object System.Drawing.Point(12, 300)
    $logGroup.Size = New-Object System.Drawing.Size(390, 110)
    $form.Controls.Add($logGroup)

    $logCheck = New-Object System.Windows.Forms.CheckBox
    $logCheck.AutoSize = $true
    $logCheck.Location = New-Object System.Drawing.Point(12, 25)
    $logCheck.Text = "Write log file"
    $logCheck.Checked = $true
    $logGroup.Controls.Add($logCheck)

    $logName = New-Object System.Windows.Forms.TextBox
    $logName.Location = New-Object System.Drawing.Point(15, 65)
    $logName.Width = 360
    $logName.Text = "ShrinkTextures_log.txt"
    $logGroup.Controls.Add($logName)

    # NEW: Output format group (below logging)
    $outGroup = New-Object System.Windows.Forms.GroupBox
    $outGroup.Text = "Output format"
    $outGroup.Location = New-Object System.Drawing.Point(12, 420)
    $outGroup.Size = New-Object System.Drawing.Size(390, 150)
    $form.Controls.Add($outGroup)

    $outLabel = New-Object System.Windows.Forms.Label
    $outLabel.AutoSize = $true
    $outLabel.Location = New-Object System.Drawing.Point(12, 28)
    $outLabel.Text = "Write as:"
    $outGroup.Controls.Add($outLabel)

    $outCombo = New-Object System.Windows.Forms.ComboBox
    $outCombo.DropDownStyle = 'DropDownList'
    $outCombo.Location = New-Object System.Drawing.Point(80, 24)
    $outCombo.Width = 150

# Keep original + auto-populated writable output formats from ImageMagick
[void]$outCombo.Items.Add("Keep original")

# Build a sorted list of unique writable formats (Mode contains w)
$writableFormats =
    $magickFormats |
    Where-Object { $_.Mode -match "(?i)w" } |
    Select-Object -ExpandProperty Ext -Unique |
    ForEach-Object { $_.ToLowerInvariant() } |
    Sort-Object

# Prefer a small "top list" first (common game formats), then the rest
$preferred = @("png","tif","tiff","jpg","jpeg","tga","webp","bmp")
$added = New-Object System.Collections.Generic.HashSet[string]

foreach ($p in $preferred) {
    if ($writableFormats -contains $p) {
        [void]$outCombo.Items.Add($p)
        [void]$added.Add($p)
    }
}

foreach ($f in $writableFormats) {
    if (-not $added.Contains($f)) {
        [void]$outCombo.Items.Add($f)
    }
}

$outCombo.SelectedItem = "Keep original"

    $outGroup.Controls.Add($outCombo)

    $outHint = New-Object System.Windows.Forms.Label
    $outHint.AutoSize = $true
    $outHint.Location = New-Object System.Drawing.Point(12, 55)
    $outHint.MaximumSize = New-Object System.Drawing.Size(360, 0)
    $outHint.Text = "Choosing a format converts files (e.g., .tif -> .png) and replaces originals after successful write."
    $outGroup.Controls.Add($outHint)

    # Buttons
    $runBtn = New-Object System.Windows.Forms.Button
    $runBtn.Text = "Run"
    $runBtn.Width = 100
    $runBtn.Location = New-Object System.Drawing.Point(640, 560)
    $runBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $runBtn
    $form.Controls.Add($runBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Width = 100
    $cancelBtn.Location = New-Object System.Drawing.Point(750, 560)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancelBtn
    $form.Controls.Add($cancelBtn)

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    # Build extension list (strip unsupported labels)
    $checkedExts = @()
    foreach ($item in $extList.CheckedItems) {
        $s = $item.ToString()
        $clean = $s.Replace(" (unsupported)", "").Trim().ToLowerInvariant()
        if ($clean.Length -gt 0) { $checkedExts += $clean }
    }

    # Output format clean
    $outSel = $outCombo.SelectedItem.ToString()
    $outClean = $outSel.Replace(" (unsupported)", "").Trim().ToLowerInvariant()
    if ($outClean -eq "keep original") { $outClean = "" }

    # If user picked an unsupported output format, block here
    if (-not [string]::IsNullOrWhiteSpace($outClean) -and (-not $writableSet.Contains($outClean))) {
        [System.Windows.Forms.MessageBox]::Show(
            "Selected output format '$outSel' is not writable on this machine (magick -list format). Pick another format or install ImageMagick with that codec.",
            "Output Format Unsupported",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $null
    }

    return [pscustomobject]@{
        Folder       = $folderText.Text
        Max          = [int]$sizeCombo.SelectedItem
        Strip        = [bool]$optStrip.Checked
        CompressPng  = [bool]$optCompress.Checked
        SkipNormals  = [bool]$optSkipNormals.Checked
        PixelArtMode = [bool]$optPixelArt.Checked
        DryRun       = [bool]$optDryRun.Checked
        Backup       = [bool]$optBackup.Checked
        ExtsChecked  = $checkedExts
        ExtsCustom   = $customText.Text
        WriteLog     = [bool]$logCheck.Checked
        LogFileName  = $logName.Text
        OutputFormat = $outClean   # "" means keep original
    }
}

# ---------------- MAIN ----------------

try {
    Assert-MagickAvailable

    $defaultFolder = if (-not [string]::IsNullOrWhiteSpace($TargetFolder) -and (Test-Path $TargetFolder)) {
        (Resolve-Path $TargetFolder).Path
    } else {
        $PSScriptRoot
    }

    $settings = Show-ConfigDialog -initialFolder $defaultFolder
    if (-not $settings) { return }

    $folder = $settings.Folder
    if (-not (Test-Path $folder)) { throw "Target folder does not exist: $folder" }

    $exts = Normalize-Extensions -extsFromChecklist $settings.ExtsChecked -customText $settings.ExtsCustom
    if ($exts.Count -eq 0) { throw "No file types selected." }

    $outputFmt = $settings.OutputFormat  # "" means keep original

    # Log path
    $logPath = ""
    if ($settings.WriteLog) {
        $name = $settings.LogFileName.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "ShrinkTextures_log.txt" }
        $logPath = Join-Path $folder $name
        Start-Log $logPath
        Log-Line $logPath "Folder: $folder"
        Log-Line $logPath "Max: $($settings.Max)"
        Log-Line $logPath "Extensions: $($exts -join ', ')"
        Log-Line $logPath "Output: $(if ([string]::IsNullOrWhiteSpace($outputFmt)) { 'keep original' } else { $outputFmt })"
        Log-Line $logPath "Strip: $($settings.Strip) | PNG compress: $($settings.CompressPng) | PixelArt: $($settings.PixelArtMode)"
        Log-Line $logPath "SkipNormals: $($settings.SkipNormals) | DryRun: $($settings.DryRun) | Backup: $($settings.Backup)"
        Log-Line $logPath ""
    }

    # Collect files per extension (array-safe)
    $filesAll = @()
    foreach ($e in $exts) {
        $filesAll += Get-ChildItem -Path $folder -Recurse -File -Filter "*.$e" -ErrorAction SilentlyContinue
    }

    $files = @(
        $filesAll |
        Where-Object { -not (Should-ExcludePath $_.FullName) } |
        Select-Object -Unique
    )

    if ($settings.SkipNormals) {
        $files = @($files | Where-Object { $_.Name -notmatch "(?i)normal" })
    }

    Add-Type -AssemblyName System.Windows.Forms

    if ($files.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No matching files found under:`n$folder",
            "Shrink Textures",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    # Confirmation
    $confirmMsg =
        "About to process $($files.Count) file(s) under:`n$folder`n`n" +
        "Max size: $($settings.Max)`n" +
        "File types: $($exts -join ', ')`n" +
        "Output format: $(if ([string]::IsNullOrWhiteSpace($outputFmt)) { 'keep original' } else { $outputFmt })`n" +
        "Strip metadata: $($settings.Strip)`n" +
        "PNG compression: $($settings.CompressPng)`n" +
        "Pixel art mode: $($settings.PixelArtMode)`n" +
        "Skip 'Normal': $($settings.SkipNormals)`n" +
        "Dry run: $($settings.DryRun)`n" +
        "Backups: $($settings.Backup)`n`n" +
        "If Dry run is OFF, this will overwrite files in place (or replace originals if converting). Commit/backup first."

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg,
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $ok = 0
    $skipped = 0
    $fail = 0
    $failList = New-Object System.Collections.Generic.List[string]

    [System.Windows.Forms.Application]::DoEvents() | Out-Null
    $total = [Math]::Max($files.Count, 1)
    $i = 0

    foreach ($f in $files) {
        $i++
        $pct = [int](($i / $total) * 100)
        Write-Progress -Activity "Shrinking textures" -Status "$i / $total" -PercentComplete $pct

        $src = $f.FullName

        # If dry run, just log and continue
        if ($settings.DryRun) {
            $skipped++
            if ($logPath) { Log-Line $logPath "DRYRUN: $src" }
            continue
        }

        try {
            # Optional backup of original source
            if ($settings.Backup) {
                $bak = $src + ".bak"
                if (-not (Test-Path $bak)) {
                    Copy-Item -LiteralPath $src -Destination $bak -Force
                    if ($logPath) { Log-Line $logPath "BACKUP: $bak" }
                }
            }

            # Destination path (convert if outputFmt selected)
            $dst = if ([string]::IsNullOrWhiteSpace($outputFmt)) {
                $src
            } else {
                [System.IO.Path]::ChangeExtension($src, "." + $outputFmt)
            }

            # Temp path MUST end with output format extension so magick writes correct type
            $tmp = if ($dst -eq $src) {
                $src + ".imtmp"
            } else {
                $dst + ".imtmp." + $outputFmt
            }

            if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }

            $code = Resize-ImageToTemp `
                -filePath $src `
                -tempPath $tmp `
                -maxSize $settings.Max `
                -strip $settings.Strip `
                -compressPng $settings.CompressPng `
                -pixelArtMode $settings.PixelArtMode `
                -outputExt $outputFmt

            if ($code -ne 0 -or -not (Test-Path $tmp)) {
                if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
                throw "ImageMagick failed (exit code $code)"
            }

            if ($dst -eq $src) {
                Safe-ReplaceFile -src $src -tmp $tmp
                $ok++
                if ($logPath) { Log-Line $logPath "OK: $src" }
            }
            else {
                # Replace destination (if exists), then delete original after success
                if (Test-Path $dst) { Remove-Item -Force $dst -ErrorAction SilentlyContinue }
                Move-Item -Force $tmp $dst

                # Only now remove original
                if (Test-Path $src) { Remove-Item -Force $src -ErrorAction SilentlyContinue }

                $ok++
                if ($logPath) { Log-Line $logPath "OK: $src -> $dst" }
            }
        }
        catch {
            $fail++
            $failList.Add($src) | Out-Null
            if ($logPath) { Log-Line $logPath "FAIL: $src | $($_.Exception.Message)" }

            # Cleanup temp if left behind
            if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    Write-Progress -Activity "Shrinking textures" -Completed

    if ($logPath) {
        Log-Line $logPath ""
        Log-Line $logPath "End: $(Get-Date -Format o)"
        Log-Line $logPath "Summary | OK: $ok | DryRunSkipped: $skipped | Failed: $fail"
    }

    $doneMsg = "Done.`n`nOK: $ok`nDry-run skipped: $skipped`nFailed: $fail"
    if ($logPath) { $doneMsg += "`nLog: $logPath" }

    if ($fail -gt 0) {
        $doneMsg += "`n`nFailed files (first 10):`n" + (($failList | Select-Object -First 10) -join "`n")
    }

    [System.Windows.Forms.MessageBox]::Show(
        $doneMsg,
        "Shrink Textures",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        "Shrink Textures - Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    throw
}
