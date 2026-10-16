#!/usr/bin/env bash
# find_videos.sh <folder> [--exclude DIR]...
# Print one video path per line for every video file under <folder>.
# Recursive. Extensions matched case-insensitively. Never descends into an --exclude DIR (the
# driver passes its output root, which may live inside <folder>) or into the pipeline's own
# working dirs (video_native/ holds upload proxies, asr_chunks/ audio chunks).
set -euo pipefail

folder="${1:-.}"; shift || true
prune=( -name video_native -o -name asr_chunks -o -name frames )
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude) [[ -d "${2:-}" ]] && prune+=( -o -path "$(cd "$2" && pwd)" ); shift 2 ;;
    *) shift ;;
  esac
done
if [[ ! -d "$folder" ]]; then
  echo "find_videos.sh: not a directory: $folder" >&2
  exit 1
fi

# Case-insensitive extension match, null-delimited so weird filenames survive.
folder="$(cd "$folder" && pwd)"   # absolute, so --exclude paths compare equal
find "$folder" -type d \( "${prune[@]}" \) -prune -o -type f \
  \( -iname '*.mkv'  -o -iname '*.mp4'  -o -iname '*.mov'  -o -iname '*.webm' \
  -o -iname '*.avi'  -o -iname '*.m4v'  -o -iname '*.flv'  -o -iname '*.wmv'  \
  -o -iname '*.mpg'  -o -iname '*.mpeg' -o -iname '*.ts'   -o -iname '*.mts'  \) \
  -print0 | sort -z | while IFS= read -r -d '' f; do
  printf '%s\n' "$f"
done
