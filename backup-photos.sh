#!/usr/bin/env bash
# backup-photos.sh
# System-wide photo sweep, SHA-256 deduplication, and EXIF-based organisation.
#
# Usage: ./backup-photos.sh [OPTIONS]
# Run with --help for full option reference.

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
OUTPUT=""
SOURCE=""
MOVE=false
DRY_RUN=false
NO_DUPLICATES=false
FILTER_JPG=false
FILTER_PNG=false

# Counters
SCANNED=0
SKIPPED=0
COPIED=0
ERRORS=0

# Hash index (associative array — requires Bash 4+)
declare -A HASH_INDEX

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --output <path>      Destination directory. Required for --no-duplicates and
                       copy/move operations. Without it, runs in report mode.
  --source <path>      Root path to scan recursively.
                       Default: / on Linux/macOS (skips /proc, /sys, /dev, /run).
  --jpg                Only include JPG/JPEG files.
  --png                Only include PNG files.
  --no-duplicates      Skip files whose SHA-256 hash already exists in --output.
                       Requires --output.
  --move               Move files instead of copying (destructive, prompts first).
  --dry-run            Preview actions without making any changes.
  --help               Show this message and exit.

Default file types (when neither --jpg nor --png is set):
  jpg  jpeg  png  heic  heif  cr2  nef  arw  dng  orf  rw2  pef
  tiff  tif  bmp  gif  webp

--jpg and --png are combinable.

Dependencies:
  exiftool — used for EXIF date reading (folder organisation).
             Falls back to file modification date if not installed.
  Install:
    Debian/Ubuntu : sudo apt install libimage-exiftool-perl
    Fedora/RHEL   : sudo dnf install perl-Image-ExifTool
    macOS         : brew install exiftool

Examples:
  # Full system sweep, copy all images to /mnt/backup
  $(basename "$0") --output /mnt/backup

  # JPG only, skip files already in the backup
  $(basename "$0") --output /mnt/backup --jpg --no-duplicates

  # Dry-run preview
  $(basename "$0") --output /mnt/backup --no-duplicates --dry-run

  # Scan a specific folder
  $(basename "$0") --source ~/Pictures --output /mnt/backup

  # Report mode (no output path) — list found images
  $(basename "$0")
EOF
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)         OUTPUT="$2";          shift 2 ;;
    --source)         SOURCE="$2";          shift 2 ;;
    --jpg)            FILTER_JPG=true;      shift   ;;
    --png)            FILTER_PNG=true;      shift   ;;
    --no-duplicates)  NO_DUPLICATES=true;   shift   ;;
    --move)           MOVE=true;            shift   ;;
    --dry-run)        DRY_RUN=true;         shift   ;;
    --help|-h)        usage; exit 0                 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────
if $NO_DUPLICATES && [[ -z "$OUTPUT" ]]; then
  echo "Error: --no-duplicates requires --output." >&2
  exit 1
fi

if $MOVE && ! $DRY_RUN; then
  echo "Warning: --move is destructive. Original files will be deleted after copying."
  read -r -p "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ─── exiftool check ───────────────────────────────────────────────────────────
HAVE_EXIFTOOL=false
if command -v exiftool &>/dev/null; then
  HAVE_EXIFTOOL=true
else
  echo "Warning: exiftool not found. Falling back to file modification date for folder organisation."
  echo "  Install: sudo apt install libimage-exiftool-perl  (Debian/Ubuntu)"
  echo "           sudo dnf install perl-Image-ExifTool      (Fedora/RHEL)"
  echo "           brew install exiftool                      (macOS)"
  echo ""
fi

# ─── Extension filter ─────────────────────────────────────────────────────────
if $FILTER_JPG && $FILTER_PNG; then
  EXTENSIONS=("jpg" "jpeg" "png")
elif $FILTER_JPG; then
  EXTENSIONS=("jpg" "jpeg")
elif $FILTER_PNG; then
  EXTENSIONS=("png")
else
  EXTENSIONS=("jpg" "jpeg" "png" "heic" "heif"
              "cr2" "nef" "arw" "dng" "orf" "rw2" "pef"
              "tiff" "tif" "bmp" "gif" "webp")
fi

# Build the -iname arguments for find
build_find_iname_args() {
  local args=()
  local first=true
  for ext in "${EXTENSIONS[@]}"; do
    if $first; then
      args+=(-iname "*.${ext}")
      first=false
    else
      args+=(-o -iname "*.${ext}")
    fi
  done
  printf '%s\0' "${args[@]}"
}

# ─── SHA-256 helper ───────────────────────────────────────────────────────────
sha256_file() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    # macOS / BSD
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ─── EXIF date helper ─────────────────────────────────────────────────────────
# Echoes "YYYY MM DD". Falls back to mtime.
get_date_parts() {
  local file="$1"
  local exif_date year month day

  if $HAVE_EXIFTOOL; then
    exif_date=$(exiftool -s3 -DateTimeOriginal "$file" 2>/dev/null | head -1)
    if [[ "$exif_date" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2}) ]]; then
      echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
      return
    fi
  fi

  # Fallback: file modification time
  if stat --version &>/dev/null 2>&1; then
    # GNU stat (Linux)
    stat -c '%y' "$file" | awk -F'[-: ]' '{print $1, $2, $3}'
  else
    # BSD stat (macOS)
    stat -f '%Sm' -t '%Y %m %d' "$file"
  fi
}

# ─── Build dedup hash index ───────────────────────────────────────────────────
if $NO_DUPLICATES && [[ -n "$OUTPUT" ]] && [[ -d "$OUTPUT" ]]; then
  echo "Building hash index of existing files in: $OUTPUT"
  # Temporarily allow null-separated find without set -e problems
  while IFS= read -r -d '' existing; do
    hash=$(sha256_file "$existing" 2>/dev/null) || continue
    HASH_INDEX["$hash"]=1
  done < <(
    eval "find $(printf '%q' "$OUTPUT") -type f \( $(
      first=true
      for ext in "${EXTENSIONS[@]}"; do
        $first && echo -n "-iname '*.${ext}'" || echo -n " -o -iname '*.${ext}'"
        first=false
      done
    ) \) -print0 2>/dev/null"
  )
  echo "  Indexed ${#HASH_INDEX[@]} existing file(s)."
  echo ""
fi

# ─── Determine scan root(s) ───────────────────────────────────────────────────
if [[ -n "$SOURCE" ]]; then
  SCAN_ROOTS=("$SOURCE")
else
  SCAN_ROOTS=("/")
fi

# ─── Report mode header ───────────────────────────────────────────────────────
if [[ -z "$OUTPUT" ]]; then
  printf "%-80s %-8s %-12s %s\n" "PATH" "EXT" "DATE TAKEN" "SIZE"
  printf '%0.s─' {1..120}; echo
fi

# ─── Prune paths to skip on default system-wide scan ─────────────────────────
PRUNE_PATHS=(-not -path "*/proc/*" -not -path "*/sys/*" -not -path "*/dev/*" -not -path "*/run/*")

# ─── Main scan loop ───────────────────────────────────────────────────────────
# Build the find iname filter as a single -\( ... \) group
INAME_FILTER=()
first=true
for ext in "${EXTENSIONS[@]}"; do
  if $first; then
    INAME_FILTER+=(-iname "*.${ext}")
    first=false
  else
    INAME_FILTER+=(-o -iname "*.${ext}")
  fi
done

while IFS= read -r -d '' file; do
  ((SCANNED++)) || true

  # Skip the output directory itself to avoid re-hashing what we just wrote
  if [[ -n "$OUTPUT" ]] && [[ "$file" == "$OUTPUT"/* ]]; then
    continue
  fi

  # Compute hash
  hash=$(sha256_file "$file" 2>/dev/null) || {
    echo "Error hashing: $file" >&2
    ((ERRORS++)) || true
    continue
  }

  # Dedup check
  if $NO_DUPLICATES && [[ -n "${HASH_INDEX[$hash]+_}" ]]; then
    ((SKIPPED++)) || true
    continue
  fi

  # Get date parts
  date_parts=$(get_date_parts "$file" 2>/dev/null) || date_parts="unknown unknown unknown"
  read -r year month day <<< "$date_parts"

  ext_lower="${file##*.}"
  size=$(du -h "$file" 2>/dev/null | cut -f1)

  # ── Report mode ─────────────────────────────────────────────────────────────
  if [[ -z "$OUTPUT" ]]; then
    printf "%-80s %-8s %-12s %s\n" "$file" "$ext_lower" "${year}-${month}-${day}" "$size"
    continue
  fi

  # ── Resolve destination ───────────────────────────────────────────────────
  filename="$(basename "$file")"
  base="${filename%.*}"
  file_ext="${filename##*.}"
  dest_dir="${OUTPUT}/${year}/${month}/${day}"
  dest="${dest_dir}/${filename}"

  # Collision handling
  counter=1
  while [[ -e "$dest" ]]; do
    dest="${dest_dir}/${base}_${counter}.${file_ext}"
    ((counter++))
  done

  if $DRY_RUN; then
    echo "[DRY-RUN] $file"
    echo "       -> $dest"
  else
    mkdir -p "$dest_dir"
    if $MOVE; then
      if mv -- "$file" "$dest" 2>/dev/null; then
        HASH_INDEX["$hash"]=1
        ((COPIED++)) || true
      else
        echo "Error moving: $file" >&2
        ((ERRORS++)) || true
      fi
    else
      if cp -- "$file" "$dest" 2>/dev/null; then
        HASH_INDEX["$hash"]=1
        ((COPIED++)) || true
      else
        echo "Error copying: $file" >&2
        ((ERRORS++)) || true
      fi
    fi
  fi

done < <(
  find "${SCAN_ROOTS[@]}" -type f \( "${INAME_FILTER[@]}" \) \
    "${PRUNE_PATHS[@]}" \
    -print0 2>/dev/null
)

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo " Summary"
echo "────────────────────────────────────────"
echo "  Scanned              : $SCANNED"
echo "  Skipped (duplicates) : $SKIPPED"
if $DRY_RUN; then
  echo "  Would copy/move      : $((SCANNED - SKIPPED - ERRORS))"
else
  action=$( $MOVE && echo "Moved" || echo "Copied" )
  echo "  $action               : $COPIED"
fi
echo "  Errors               : $ERRORS"
echo "────────────────────────────────────────"
