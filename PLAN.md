# Implementation Plan: backup-photos.ps1 + backup-photos.sh

## Summary

Two scripts (one PowerShell for Windows, one Bash for Linux/macOS) that perform a
system-wide sweep for image files, optionally deduplicate against an existing backup
destination, and copy/move found files into a date-organised output tree.

---

## Files to Create

| File | Purpose |
|---|---|
| `backup-photos.ps1` | Windows PowerShell script |
| `backup-photos.sh` | Linux/macOS Bash script |
| `README.md` (update) | Usage docs and dependency install instructions |

---

## Flags / Parameters

| PowerShell | Bash | Default | Notes |
|---|---|---|---|
| `-OutputPath <path>` | `--output <path>` | *(none)* | Required for copy/move/dedup. Without it the script runs in **report mode** (list only). |
| `-Source <path>` | `--source <path>` | All drives (Win) / `/` (Linux) | Root to scan recursively. |
| `-Jpg` | `--jpg` | off | Include only JPG/JPEG. |
| `-Png` | `--png` | off | Include only PNG. |
| `-NoDuplicates` | `--no-duplicates` | off | Skip files whose SHA-256 hash already exists anywhere under `--output`. Requires `--output`. |
| `-Move` | `--move` | off (copy) | Move files instead of copying. Destructive – user must confirm. |
| `-DryRun` | `--dry-run` | off | Print what would happen; no file changes. |
| `-Help` | `--help` | — | Print usage and exit. |

`--jpg` and `--png` are combinable. If neither is set, **all image types** are scanned.

---

## Default File Extensions ("everything")

```
jpg  jpeg  png  heic  heif
cr2  nef  arw  dng  orf  rw2  pef   ← RAW
tiff  tif  bmp  gif  webp
```

---

## Dependency: exiftool

EXIF date reading (for folder organisation) requires **exiftool**.

- Script checks for `exiftool` at startup.
- **If missing:** prints install instructions (see below) and falls back to
  **file modification date** for folder organisation (no crash, just a warning).
- PowerShell additionally tries `.NET System.Drawing` as a secondary fallback
  for JPG/PNG when exiftool is absent.

Install instructions printed by the scripts:
- **Windows:** `winget install OliverBetz.ExifTool`  or  download from https://exiftool.org
- **Linux:** `sudo apt install libimage-exiftool-perl`  /  `sudo dnf install perl-Image-ExifTool`
- **macOS:** `brew install exiftool`

---

## Script Logic (both scripts follow identical logic)

### 1. Parse & validate arguments
- If `-NoDuplicates` / `--no-duplicates` is set but `-OutputPath` / `--output` is not → exit with error.
- If `-Move` is set in non-dry-run mode → print a confirmation warning.

### 2. Build extension filter
- No `--jpg` / `--png` flags → use full default list.
- `--jpg` only → `[jpg, jpeg]`
- `--png` only → `[png]`
- Both → `[jpg, jpeg, png]`

### 3. Build dedup hash index (only if `--no-duplicates`)
- Walk every file under `--output` recursively.
- Compute SHA-256 of each file's bytes; store in a hash set.

### 4. Scan source
- Walk `--source` (or all drives / `/`) recursively.
- For each file whose extension matches the filter:
  a. Compute SHA-256.
  b. If `--no-duplicates` and hash is in index → **skip**.
  c. Read EXIF `DateTimeOriginal` via exiftool → parse `YYYY/MM/DD`.
     - Fallback: file modification timestamp.
  d. Resolve destination: `<output>/<YYYY>/<MM>/<DD>/<filename>`
     - Collision: append `_1`, `_2`, … before the extension.
  e. In **dry-run** mode → print the source → dest mapping only.
  f. Otherwise → create destination directory tree if needed, then copy (or move).
  g. Add new file's hash to the index (prevents copying a duplicate of itself
     found in a second source location in the same run).

### 5. Print summary
- Total scanned, skipped (duplicate), copied/moved, errors.

---

## Output Folder Structure Example

```
OutputPath/
  2023/
    06/
      15/
        IMG_1234.jpg
        IMG_1234_1.jpg   ← collision-handled
  2024/
    01/
      01/
        DSC_0001.NEF
```

---

## Report Mode (no `--output`)

Prints a table: path | extension | date taken | file size.
No files are copied or moved.

---

## README Updates

- Short description of each flag with examples.
- Dependency install instructions per OS.
- Example invocations:
  - Full system backup: `./backup-photos.sh --output /mnt/backup`
  - JPG only, new files only: `./backup-photos.sh --output /mnt/backup --jpg --no-duplicates`
  - Dry run preview: `./backup-photos.sh --output /mnt/backup --no-duplicates --dry-run`
