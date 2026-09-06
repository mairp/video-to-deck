#!/usr/bin/env bash
# find_videos.sh <folder> [--recursive|-r]
# Print one video path per line for every video file under <folder>.
# Default is recursive. Extensions matched case-insensitively.
set -euo pipefail

folder="${1:-.}"
if [[ ! -d "$folder" ]]; then
  echo "find_videos.sh: not a directory: $folder" >&2
  exit 1
fi

# Case-insensitive extension match, null-delimited so weird filenames survive.
find "$folder" -type f \
  \( -iname '*.mkv'  -o -iname '*.mp4'  -o -iname '*.mov'  -o -iname '*.webm' \
  -o -iname '*.avi'  -o -iname '*.m4v'  -o -iname '*.flv'  -o -iname '*.wmv'  \
  -o -iname '*.mpg'  -o -iname '*.mpeg' -o -iname '*.ts'   -o -iname '*.mts'  \) \
  -print0 | sort -z | while IFS= read -r -d '' f; do
  printf '%s\n' "$f"
done
