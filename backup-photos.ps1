<#
.SYNOPSIS
    System-wide photo sweep, SHA-256 deduplication, and EXIF-based organisation.

.DESCRIPTION
    Scans the system (or a specified directory) for image files, optionally skips
    files already backed up (deduplication via SHA-256 hash comparison), and
    copies or moves them into a date-organised folder structure under the output path.

    Folder structure: <OutputPath>\<YYYY>\<MM>\<DD>\<filename>

    Requires exiftool for reliable EXIF date reading. Falls back to file
    LastWriteTime and (for JPG/PNG) .NET System.Drawing if exiftool is absent.

.PARAMETER OutputPath
    Destination directory. Required for -NoDuplicates and copy/move operations.
    Without it, the script runs in report mode (lists found images, no file changes).

.PARAMETER Source
    Root directory to scan recursively.
    Default: all ready fixed and removable drives on the system.

.PARAMETER Jpg
    Only include JPG/JPEG files.

.PARAMETER Png
    Only include PNG files.

.PARAMETER NoDuplicates
    Skip files whose SHA-256 hash already exists anywhere under -OutputPath.
    Requires -OutputPath.

.PARAMETER Move
    Move files instead of copying (destructive — prompts for confirmation).

.PARAMETER DryRun
    Preview what would happen without making any changes.

.PARAMETER NoZip
    Skip scanning inside ZIP archives for images. By default, any .zip files
    found during scanning are inspected for image files matching the current
    extension filter. Only matching images are extracted temporarily and processed.

.EXAMPLE
    .\backup-photos.ps1 -OutputPath D:\Backup

.EXAMPLE
    .\backup-photos.ps1 -OutputPath D:\Backup -Jpg -NoDuplicates

.EXAMPLE
    .\backup-photos.ps1 -OutputPath D:\Backup -NoDuplicates -DryRun

.EXAMPLE
    .\backup-photos.ps1 -Source C:\Users\Me\Downloads -OutputPath D:\Backup

.EXAMPLE
    # Report mode — list all found images, no output path
    .\backup-photos.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Source,
    [switch]$Jpg,
    [switch]$Png,
    [switch]$NoDuplicates,
    [switch]$Move,
    [switch]$DryRun,
    [switch]$NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Validation ───────────────────────────────────────────────────────────────
if ($NoDuplicates -and -not $OutputPath) {
    Write-Error "-NoDuplicates requires -OutputPath."
    exit 1
}

if ($Move -and -not $DryRun) {
    Write-Warning "-Move is destructive. Original files will be deleted after copying."
    $confirm = Read-Host "Continue? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Aborted."
        exit 0
    }
}

# ─── exiftool check ───────────────────────────────────────────────────────────
$HaveExiftool = [bool](Get-Command exiftool -ErrorAction SilentlyContinue)

if (-not $HaveExiftool) {
    Write-Warning "exiftool not found. Falling back to file LastWriteTime for folder organisation."
    Write-Host "  Install: winget install OliverBetz.ExifTool"
    Write-Host "           or download from https://exiftool.org"
    Write-Host ""
}

# ─── Extension filter ─────────────────────────────────────────────────────────
$Extensions = if ($Jpg -and $Png) {
    @('jpg','jpeg','png')
} elseif ($Jpg) {
    @('jpg','jpeg')
} elseif ($Png) {
    @('png')
} else {
    @('jpg','jpeg','png','heic','heif',
      'cr2','nef','arw','dng','orf','rw2','pef',
      'tiff','tif','bmp','gif','webp')
}

# ─── SHA-256 helper ───────────────────────────────────────────────────────────
function Get-FileSHA256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $bytes = $sha.ComputeHash($stream)
            return ([BitConverter]::ToString($bytes) -replace '-', '').ToUpper()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

# ─── EXIF date helper ─────────────────────────────────────────────────────────
# Returns a hashtable with Year, Month, Day strings (zero-padded).
function Get-PhotoDate {
    param([System.IO.FileInfo]$File)

    # 1. exiftool (handles all formats)
    if ($HaveExiftool) {
        $raw = & exiftool -s3 -DateTimeOriginal $File.FullName 2>$null
        if ($raw -match '^(\d{4}):(\d{2}):(\d{2})') {
            return @{ Year = $Matches[1]; Month = $Matches[2]; Day = $Matches[3] }
        }
    }

    # 2. .NET System.Drawing fallback (JPG/PNG only — no exiftool needed)
    if ($File.Extension -imatch '\.(jpg|jpeg|png)$') {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $img = [System.Drawing.Image]::FromFile($File.FullName)
            try {
                $prop = $img.GetPropertyItem(0x9003)  # ExifDTOrig / DateTimeOriginal
                $dateStr = [System.Text.Encoding]::ASCII.GetString($prop.Value).Trim([char]0)
                if ($dateStr -match '^(\d{4}):(\d{2}):(\d{2})') {
                    return @{ Year = $Matches[1]; Month = $Matches[2]; Day = $Matches[3] }
                }
            } catch {
                # Property not present — fall through
            } finally {
                $img.Dispose()
            }
        } catch {
            # System.Drawing unavailable — fall through
        }
    }

    # 3. Last resort: file LastWriteTime
    $d = $File.LastWriteTime
    return @{
        Year  = $d.Year.ToString('D4')
        Month = $d.Month.ToString('D2')
        Day   = $d.Day.ToString('D2')
    }
}

# ─── Helper: test if extension matches filter ──────────────────────────────────
function Test-Extension {
    param([System.IO.FileInfo]$File)
    $ext = $File.Extension.TrimStart('.').ToLower()
    return $Extensions -contains $ext
}

# ─── Build dedup hash index ───────────────────────────────────────────────────
$HashIndex = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

if ($NoDuplicates -and $OutputPath -and (Test-Path $OutputPath)) {
    Write-Host "Building hash index of existing files in: $OutputPath"
    $existing = Get-ChildItem -Path $OutputPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { Test-Extension $_ }
    foreach ($f in $existing) {
        try {
            $h = Get-FileSHA256 -Path $f.FullName
            [void]$HashIndex.Add($h)
        } catch {
            Write-Warning "Could not hash existing file: $($f.FullName)"
        }
    }
    Write-Host "  Indexed $($HashIndex.Count) existing file(s)."
    Write-Host ""
}

# ─── Determine scan roots ─────────────────────────────────────────────────────
$ScanRoots = if ($Source) {
    @($Source)
} else {
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -in 'Fixed','Removable' -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName }
}

# ─── Counters ─────────────────────────────────────────────────────────────────
$Scanned      = 0
$Skipped      = 0
$Copied       = 0
$Errors       = 0
$ZipArchives  = 0
$ZipExtracted = 0

# ─── Report mode header ───────────────────────────────────────────────────────
if (-not $OutputPath) {
    Write-Host ("{0,-80} {1,-8} {2,-12} {3}" -f "PATH", "EXT", "DATE TAKEN", "SIZE")
    Write-Host ("-" * 120)
}

# ─── Main scan loop ───────────────────────────────────────────────────────────
foreach ($root in $ScanRoots) {
    $files = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object {
                 (Test-Extension $_) -and
                 (-not $OutputPath -or
                  -not $_.FullName.StartsWith($OutputPath, [StringComparison]::OrdinalIgnoreCase))
             }

    foreach ($file in $files) {
        $Scanned++

        # Hash
        $hash = $null
        try {
            $hash = Get-FileSHA256 -Path $file.FullName
        } catch {
            Write-Warning "Cannot hash: $($file.FullName)"
            $Errors++
            continue
        }

        # Dedup check
        if ($NoDuplicates -and $HashIndex.Contains($hash)) {
            $Skipped++
            continue
        }

        # Date
        $dateParts = Get-PhotoDate -File $file
        $year  = $dateParts.Year
        $month = $dateParts.Month
        $day   = $dateParts.Day

        # ── Report mode ───────────────────────────────────────────────────────
        if (-not $OutputPath) {
            $sizeKB = "{0:N0} KB" -f ($file.Length / 1KB)
            Write-Host ("{0,-80} {1,-8} {2,-12} {3}" -f `
                $file.FullName,
                $file.Extension.TrimStart('.').ToLower(),
                "${year}-${month}-${day}",
                $sizeKB)
            continue
        }

        # ── Resolve destination ───────────────────────────────────────────────
        $destDir  = Join-Path $OutputPath "$year\$month\$day"
        $destFile = Join-Path $destDir $file.Name
        $base     = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $ext      = $file.Extension
        $counter  = 1
        while (Test-Path $destFile) {
            $destFile = Join-Path $destDir "${base}_${counter}${ext}"
            $counter++
        }

        if ($DryRun) {
            Write-Host "[DRY-RUN] $($file.FullName)"
            Write-Host "       -> $destFile"
        } else {
            try {
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                if ($Move) {
                    Move-Item -Path $file.FullName -Destination $destFile -ErrorAction Stop
                } else {
                    Copy-Item -Path $file.FullName -Destination $destFile -ErrorAction Stop
                }
                [void]$HashIndex.Add($hash)  # prevent self-duplication within this run
                $Copied++
            } catch {
                Write-Warning "Error processing $($file.FullName): $_"
                $Errors++
            }
        }
    }
}

# ─── ZIP archive scan ───────────────────────────────────────────────────────
if (-not $NoZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Scanning ZIP archives for images…"

    $zipTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "backup-photos-zip-$PID"
    if (-not (Test-Path $zipTmpDir)) {
        New-Item -ItemType Directory -Path $zipTmpDir -Force | Out-Null
    }

    try {
        foreach ($root in $ScanRoots) {
            $zipFiles = Get-ChildItem -Path $root -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
                        Where-Object {
                            -not $OutputPath -or
                            -not $_.FullName.StartsWith($OutputPath, [StringComparison]::OrdinalIgnoreCase)
                        }

            foreach ($zipFile in $zipFiles) {
                try {
                    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
                } catch {
                    Write-Warning "Cannot open ZIP: $($zipFile.FullName): $_"
                    $Errors++
                    continue
                }

                try {
                    # Filter entries for image files
                    $imageEntries = $archive.Entries | Where-Object {
                        $_.Name -ne '' -and  # skip directory entries
                        $Extensions -contains ($_.Name.Split('.')[-1].ToLower())
                    }

                    if (-not $imageEntries -or @($imageEntries).Count -eq 0) {
                        continue
                    }

                    $ZipArchives++
                    $entryCount = @($imageEntries).Count
                    Write-Host "  Found $entryCount image(s) in: $($zipFile.FullName)"

                    # Per-ZIP extraction subdirectory
                    $zipExtractDir = Join-Path $zipTmpDir "$($zipFile.BaseName)_${ZipArchives}"
                    if (-not (Test-Path $zipExtractDir)) {
                        New-Item -ItemType Directory -Path $zipExtractDir -Force | Out-Null
                    }

                    foreach ($entry in $imageEntries) {
                        try {
                            # Build extraction path preserving structure
                            $entryRelPath = $entry.FullName -replace '/', '\'
                            $extractPath  = Join-Path $zipExtractDir $entryRelPath
                            $extractDir   = Split-Path $extractPath -Parent

                            if (-not (Test-Path $extractDir)) {
                                New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
                            }

                            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extractPath, $true)
                        } catch {
                            Write-Warning "Error extracting '$($entry.FullName)' from $($zipFile.FullName): $_"
                            $Errors++
                            continue
                        }

                        if (-not (Test-Path $extractPath)) { continue }

                        $extractedFile = Get-Item $extractPath
                        $Scanned++
                        $ZipExtracted++

                        # Hash
                        $hash = $null
                        try {
                            $hash = Get-FileSHA256 -Path $extractedFile.FullName
                        } catch {
                            Write-Warning "Cannot hash extracted: $($entry.FullName) (from $($zipFile.FullName))"
                            $Errors++
                            continue
                        }

                        # Dedup check
                        if ($NoDuplicates -and $HashIndex.Contains($hash)) {
                            $Skipped++
                            continue
                        }

                        # Date
                        $dateParts = Get-PhotoDate -File $extractedFile
                        $year  = $dateParts.Year
                        $month = $dateParts.Month
                        $day   = $dateParts.Day

                        # ── Report mode ──────────────────────────────────────
                        if (-not $OutputPath) {
                            $sizeKB = "{0:N0} KB" -f ($extractedFile.Length / 1KB)
                            Write-Host ("{0,-80} {1,-8} {2,-12} {3}" -f `
                                "[ZIP] $($zipFile.FullName)/$($entry.FullName)",
                                $extractedFile.Extension.TrimStart('.').ToLower(),
                                "${year}-${month}-${day}",
                                $sizeKB)
                            continue
                        }

                        # ── Resolve destination ──────────────────────────────
                        $destDir  = Join-Path $OutputPath "$year\$month\$day"
                        $destFile = Join-Path $destDir $extractedFile.Name
                        $base     = [System.IO.Path]::GetFileNameWithoutExtension($extractedFile.Name)
                        $ext      = $extractedFile.Extension
                        $counter  = 1
                        while (Test-Path $destFile) {
                            $destFile = Join-Path $destDir "${base}_${counter}${ext}"
                            $counter++
                        }

                        if ($DryRun) {
                            Write-Host "[DRY-RUN] [ZIP] $($zipFile.FullName)/$($entry.FullName)"
                            Write-Host "       -> $destFile"
                        } else {
                            try {
                                if (-not (Test-Path $destDir)) {
                                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                                }
                                Copy-Item -Path $extractedFile.FullName -Destination $destFile -ErrorAction Stop
                                [void]$HashIndex.Add($hash)
                                $Copied++
                            } catch {
                                Write-Warning "Error copying extracted: $($entry.FullName) (from $($zipFile.FullName)): $_"
                                $Errors++
                            }
                        }
                    }

                    # Clean up per-ZIP extraction
                    Remove-Item -Path $zipExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                } finally {
                    $archive.Dispose()
                }
            }
        }
    } finally {
        # Clean up temp directory
        Remove-Item -Path $zipTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "────────────────────────────────────────"
Write-Host " Summary"
Write-Host "────────────────────────────────────────"
Write-Host "  Scanned              : $Scanned"
if ($ZipArchives -gt 0) {
    Write-Host "  ZIP archives scanned : $ZipArchives"
    Write-Host "  Images from ZIPs     : $ZipExtracted"
}
Write-Host "  Skipped (duplicates) : $Skipped"
if ($DryRun) {
    Write-Host "  Would copy/move      : $($Scanned - $Skipped - $Errors)"
} else {
    $action = if ($Move) { "Moved" } else { "Copied" }
    Write-Host "  $action               : $Copied"
}
Write-Host "  Errors               : $Errors"
Write-Host "────────────────────────────────────────"
