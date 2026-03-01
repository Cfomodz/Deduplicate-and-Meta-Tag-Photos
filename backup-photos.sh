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
NO_ZIP=false
DEPTH=3

# Counters
SCANNED=0
SKIPPED=0
COPIED=0
ERRORS=0
ZIP_ARCHIVES=0
ZIP_EXTRACTED=0

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
  --depth <1|2|3>      Number of date folder layers in the output directory.
                         3 (default) = YYYY/MM/DD/photo.jpg
                         2           = YYYY/MM/photo.jpg
                         1           = YYYY/photo.jpg
  --no-zip             Skip scanning inside ZIP archives for images.
  --help               Show this message and exit.

Default file types (when neither --jpg nor --png is set):
  jpg  jpeg  png  heic  heif  cr2  nef  arw  dng  orf  rw2  pef
  tiff  tif  bmp  gif  webp

--jpg and --png are combinable.

ZIP archive support:
  By default, any .zip files found during scanning will be inspected for
  image files matching the current extension filter. Only matching images
  are extracted (to a temporary directory), processed, and cleaned up.
  Use --no-zip to skip ZIP inspection entirely.

Dependencies:
  exiftool — used for EXIF date reading (folder organisation).
             Falls back to file modification date if not installed.
  Install:
    Debian/Ubuntu : sudo apt install libimage-exiftool-perl
    Fedora/RHEL   : sudo dnf install perl-Image-ExifTool
    macOS         : brew install exiftool

  unzip — required for ZIP archive inspection (usually pre-installed).
  Install:
    Debian/Ubuntu : sudo apt install unzip
    Fedora/RHEL   : sudo dnf install unzip
    macOS         : (pre-installed)

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
    --no-zip)         NO_ZIP=true;          shift   ;;
    --depth)          DEPTH="$2";           shift 2 ;;
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

if [[ "$DEPTH" != "1" && "$DEPTH" != "2" && "$DEPTH" != "3" ]]; then
  echo "Error: --depth must be 1, 2, or 3 (got '$DEPTH')." >&2
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

# ─── unzip check (for ZIP archive support) ───────────────────────────────────
HAVE_UNZIP=false
if command -v unzip &>/dev/null; then
  HAVE_UNZIP=true
elif ! $NO_ZIP; then
  echo "Warning: unzip not found. ZIP archive inspection disabled."
  echo "  Install: sudo apt install unzip  (Debian/Ubuntu)"
  echo "           sudo dnf install unzip  (Fedora/RHEL)"
  echo ""
  NO_ZIP=true
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

# ─── Image extension check helper ────────────────────────────────────────────
# Returns 0 (true) if the filename ends with a supported image extension.
is_image_extension() {
  local name="${1,,}"  # lowercase
  local ext="${name##*.}"
  for e in "${EXTENSIONS[@]}"; do
    [[ "$ext" == "$e" ]] && return 0
  done
  return 1
}

# ─── Destination directory helper ─────────────────────────────────────────────
# Builds the output subdirectory based on --depth.
#   build_dest_dir <base_output> <year> <month> <day>
build_dest_dir() {
  local base="$1" y="$2" m="$3" d="$4"
  case "$DEPTH" in
    1) echo "${base}/${y}" ;;
    2) echo "${base}/${y}/${m}" ;;
    3) echo "${base}/${y}/${m}/${d}" ;;
  esac
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
  INDEX_COUNT=0
  # Temporarily allow null-separated find without set -e problems
  while IFS= read -r -d '' existing; do
    hash=$(sha256_file "$existing" 2>/dev/null) || continue
    HASH_INDEX["$hash"]=1
    ((INDEX_COUNT++)) || true
    if (( INDEX_COUNT % 100 == 0 )); then
      echo "  [progress] Indexed $INDEX_COUNT files so far…"
    fi
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

  # Progress: hashing
  if (( SCANNED % 100 == 0 )); then
    echo "  [progress] Scanned $SCANNED files (hashing: $file)…"
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
  dest_dir=$(build_dest_dir "$OUTPUT" "$year" "$month" "$day")
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
    # Progress: copying/moving
    if (( COPIED % 10 == 0 && COPIED > 0 )); then
      action_verb=$( $MOVE && echo "Moved" || echo "Copied" )
      echo "  [progress] $action_verb $COPIED files so far…"
    fi
  fi

done < <(
  find "${SCAN_ROOTS[@]}" -type f \( "${INAME_FILTER[@]}" \) \
    "${PRUNE_PATHS[@]}" \
    -print0 2>/dev/null
)

# ─── ZIP archive scan ───────────────────────────────────────────────────────
if ! $NO_ZIP && $HAVE_UNZIP; then
  echo ""
  echo "Scanning ZIP archives for images…"

  # Create a persistent temp dir for all ZIP extractions (cleaned up at exit)
  ZIP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/backup-photos-zip.XXXXXXXXXX")
  cleanup_zip_tmp() { rm -rf "$ZIP_TMPDIR"; }
  trap cleanup_zip_tmp EXIT

  while IFS= read -r -d '' zipfile; do
    # Skip ZIPs inside the output directory
    if [[ -n "$OUTPUT" ]] && [[ "$zipfile" == "$OUTPUT"/* ]]; then
      continue
    fi

    # List ZIP contents and filter for image files
    # unzip -Z1 lists filenames only, one per line
    mapfile -t zip_entries < <(unzip -Z1 "$zipfile" 2>/dev/null || true)
    [[ ${#zip_entries[@]} -eq 0 ]] && continue

    image_entries=()
    for entry in "${zip_entries[@]}"; do
      # Skip directory entries (end with /)
      [[ "$entry" == */ ]] && continue
      # Get just the filename portion (basename)
      entry_basename="${entry##*/}"
      if is_image_extension "$entry_basename"; then
        image_entries+=("$entry")
      fi
    done

    [[ ${#image_entries[@]} -eq 0 ]] && continue

    ((ZIP_ARCHIVES++)) || true
    echo "  Found ${#image_entries[@]} image(s) in: $zipfile"

    # Extract matching images to temp directory
    # Use a per-ZIP subdirectory to avoid name collisions
    zip_extract_dir="${ZIP_TMPDIR}/$(basename "$zipfile" .zip)_$$_${ZIP_ARCHIVES}"
    mkdir -p "$zip_extract_dir"

    for entry in "${image_entries[@]}"; do
      # Extract this single entry preserving its path inside the ZIP
      if ! unzip -o -q "$zipfile" "$entry" -d "$zip_extract_dir" 2>/dev/null; then
        echo "Error extracting '$entry' from: $zipfile" >&2
        ((ERRORS++)) || true
        continue
      fi

      extracted="${zip_extract_dir}/${entry}"
      [[ -f "$extracted" ]] || continue

      ((SCANNED++)) || true
      ((ZIP_EXTRACTED++)) || true

      # Progress: hashing (ZIP)
      if (( SCANNED % 100 == 0 )); then
        echo "  [progress] Scanned $SCANNED files (hashing ZIP entry: $entry)…"
      fi

      # Compute hash
      hash=$(sha256_file "$extracted" 2>/dev/null) || {
        echo "Error hashing extracted: $entry (from $zipfile)" >&2
        ((ERRORS++)) || true
        continue
      }

      # Dedup check
      if $NO_DUPLICATES && [[ -n "${HASH_INDEX[$hash]+_}" ]]; then
        ((SKIPPED++)) || true
        continue
      fi

      # Get date parts
      date_parts=$(get_date_parts "$extracted" 2>/dev/null) || date_parts="unknown unknown unknown"
      read -r year month day <<< "$date_parts"

      ext_lower="${extracted##*.}"
      size=$(du -h "$extracted" 2>/dev/null | cut -f1)

      # ── Report mode ──────────────────────────────────────────────────────
      if [[ -z "$OUTPUT" ]]; then
        printf "%-80s %-8s %-12s %s\n" "[ZIP] ${zipfile}/${entry}" "$ext_lower" "${year}-${month}-${day}" "$size"
        continue
      fi

      # ── Resolve destination ────────────────────────────────────────────
      filename="$(basename "$extracted")"
      base="${filename%.*}"
      file_ext="${filename##*.}"
      dest_dir=$(build_dest_dir "$OUTPUT" "$year" "$month" "$day")
      dest="${dest_dir}/${filename}"

      # Collision handling
      counter=1
      while [[ -e "$dest" ]]; do
        dest="${dest_dir}/${base}_${counter}.${file_ext}"
        ((counter++))
      done

      if $DRY_RUN; then
        echo "[DRY-RUN] [ZIP] ${zipfile}/${entry}"
        echo "       -> $dest"
      else
        mkdir -p "$dest_dir"
        if cp -- "$extracted" "$dest" 2>/dev/null; then
          HASH_INDEX["$hash"]=1
          ((COPIED++)) || true
        else
          echo "Error copying extracted: $entry (from $zipfile)" >&2
          ((ERRORS++)) || true
        fi
        # Progress: copying (ZIP)
        if (( COPIED % 10 == 0 && COPIED > 0 )); then
          echo "  [progress] Copied $COPIED files so far…"
        fi
      fi
    done

    # Clean up this ZIP's temp extraction
    rm -rf "$zip_extract_dir"

  done < <(
    find "${SCAN_ROOTS[@]}" -type f -iname "*.zip" \
      "${PRUNE_PATHS[@]}" \
      -print0 2>/dev/null
  )

  # Final temp cleanup (also handled by trap)
  rm -rf "$ZIP_TMPDIR" 2>/dev/null || true
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo " Summary"
echo "────────────────────────────────────────"
echo "  Scanned              : $SCANNED"
if [[ $ZIP_ARCHIVES -gt 0 ]]; then
  echo "  ZIP archives scanned : $ZIP_ARCHIVES"
  echo "  Images from ZIPs     : $ZIP_EXTRACTED"
fi
echo "  Skipped (duplicates) : $SKIPPED"
if $DRY_RUN; then
  echo "  Would copy/move      : $((SCANNED - SKIPPED - ERRORS))"
else
  action=$( $MOVE && echo "Moved" || echo "Copied" )
  echo "  $action               : $COPIED"
fi
echo "  Errors               : $ERRORS"
echo "────────────────────────────────────────"
