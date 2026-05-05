# Deduplicate-and-Meta-Tag-Photos

System-wide sweep to find image files you may have missed when backing up just photos
instead of the whole drive/user. Copies (or moves) them into a date-organised output
tree, with optional SHA-256 deduplication against an existing backup.

---

## Scripts

| Script | Platform |
|---|---|
| `backup-photos.sh` | Linux / macOS (Bash 4+) |
| `backup-photos.ps1` | Windows (PowerShell 5.1+) |

---

## Dependencies

Both scripts use **exiftool** for reliable EXIF date reading across all supported
formats. Without it, the scripts fall back to the file's modification date for folder
organisation and print install instructions automatically — they will not crash.

| Platform | Install command |
|---|---|
| Debian / Ubuntu | `sudo apt install libimage-exiftool-perl` |
| Fedora / RHEL | `sudo dnf install perl-Image-ExifTool` |
| macOS | `brew install exiftool` |
| Windows | `winget install OliverBetz.ExifTool` or [exiftool.org](https://exiftool.org) |

---

## Options

| Bash | PowerShell | Default | Description |
|---|---|---|---|
| `--output <path>` | `-OutputPath <path>` | *(none)* | Destination directory. Required for `--no-duplicates` and copy/move. Without it, runs in **report mode** (prints a list, no file changes). |
| `--source <path>` | `-Source <path>` | `/` on Linux/macOS; all fixed drives on Windows | Root directory to scan recursively. |
| `--jpg` | `-Jpg` | off | Only include JPG/JPEG files. |
| `--png` | `-Png` | off | Only include PNG files. |
| `--no-duplicates` | `-NoDuplicates` | off | Skip files whose SHA-256 hash already exists anywhere under `--output`. Requires `--output`. |
| `--move` | `-Move` | off | Move instead of copy (destructive — prompts for confirmation). |
| `--dry-run` | `-DryRun` | off | Preview what would happen; no files are changed. |
| `--help` | `-?` / `Get-Help` | — | Show usage and exit. |

`--jpg` and `--png` are combinable (e.g. both flags = JPG + PNG only).
No filter flags = **all image types**:

```
jpg  jpeg  png  heic  heif
cr2  nef  arw  dng  orf  rw2  pef
tiff  tif  bmp  gif  webp
```

---

## Output Folder Structure

Files are organised by EXIF **DateTimeOriginal** (falls back to file modification date):

```
OutputPath/
  2023/
    06/
      15/
        IMG_1234.jpg
        DSC_0001.CR2
  2024/
    01/
      01/
        photo.jpg
        photo_1.jpg     <- automatic collision handling
```

---

## Deduplication

When `--no-duplicates` / `-NoDuplicates` is used, the script:

1. Walks every image file currently in `--output` and computes its **SHA-256** hash.
2. During the scan, any source file whose hash matches an existing one is **skipped**.
3. Newly copied/moved files are added to the hash index mid-run, so duplicate files
   found at multiple source locations are only copied once.

This compares **content, not filenames**, so renamed copies of the same photo are
correctly detected as duplicates.

---

## Examples

### Full system sweep — copy everything to a backup drive

```sh
# Linux/macOS
./backup-photos.sh --output /mnt/backup

# Windows
.\backup-photos.ps1 -OutputPath D:\Backup
```

### JPG only, skip files already backed up

```sh
./backup-photos.sh --output /mnt/backup --jpg --no-duplicates
.\backup-photos.ps1 -OutputPath D:\Backup -Jpg -NoDuplicates
```

### Dry-run preview before committing

```sh
./backup-photos.sh --output /mnt/backup --no-duplicates --dry-run
.\backup-photos.ps1 -OutputPath D:\Backup -NoDuplicates -DryRun
```

### Scan a specific folder instead of the whole system

```sh
./backup-photos.sh --source ~/Downloads --output /mnt/backup
.\backup-photos.ps1 -Source C:\Users\Me\Downloads -OutputPath D:\Backup
```

### Move files instead of copying (saves space)

```sh
./backup-photos.sh --output /mnt/backup --move
.\backup-photos.ps1 -OutputPath D:\Backup -Move
```

### Report mode — list all found images without copying anything

```sh
./backup-photos.sh
.\backup-photos.ps1
```

### Combined filter — JPG and PNG only, move, skip duplicates

```sh
./backup-photos.sh --output /mnt/backup --jpg --png --no-duplicates --move
.\backup-photos.ps1 -OutputPath D:\Backup -Jpg -Png -NoDuplicates -Move
```

---

## First Run (Linux/macOS)

Make the script executable:

```sh
chmod +x backup-photos.sh
```

## First Run (Windows)

If script execution is restricted, allow it for the current session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\backup-photos.ps1 -OutputPath D:\Backup
```
