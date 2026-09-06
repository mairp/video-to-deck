#!/usr/bin/env bash
# regroup_by_source.sh <decks_dir> [--dry-run] [--src-root DIR] [--quarantine DIR]
#
# Reconstruct the PARENT/CHILD folder hierarchy of a FLAT decks/ directory.
#
# Some runs emit every deck straight into <decks>/<stem>/ — the source course subfolders are lost
# (e.g. drive_decks.sh with a non-mirroring output, or an older flat run). drive_decks.sh mirrors
# subfolders going forward, but existing flat output needs fixing. This does that fix, ROBUSTLY:
#
# It never parses folder names. Each deck's evidence.md records the exact source video:
#     - **Source:** `/path/to/videos/CourseA/Unit 4 - Link Layer.mkv`
# so the correct parent is read straight from the evidence. Each leaf deck dir is MOVED under
# its source's subfolder, rebuilding the mirror:
#     <decks>/Unit 4 - Link Layer/           ->  <decks>/InfiniBand Professional/Unit 4 - Link Layer/
#     <decks>/vokoscreen-2025-03-15_10-04-04/ -> <decks>/Data Center .../vokoscreen-.../
#
# Parent folders keep the SOURCE names verbatim (same as drive_decks.sh mirroring); the LEAF
# deck folders are left named as-is here — run rename_by_topic.sh afterwards to slugify the
# leaves by topic while preserving this hierarchy.
#
# Duplicates (>1 deck dir for the same source video) are de-duped: the already-topic-renamed
# copy (a <slug>.md rather than deck.md) wins, else the newest; the losers are QUARANTINED
# (moved to <decks>/_duplicates/, never deleted) so nothing is lost.
#
# Options:
#   --dry-run          print the planned moves; change nothing
#   --src-root DIR     root the source paths are under (default: parent of <decks_dir>).
#                      Used to preserve the FULL relative subfolder hierarchy. If a source
#                      isn't under it, falls back to the video's immediate parent folder name.
#   --quarantine DIR   where duplicate losers go (default: <decks_dir>/_duplicates)
#
# Idempotent: a deck already sitting under its correct parent is left untouched; re-run any time.
# Writes <decks_dir>/regroup-map.tsv (old<TAB>new).
set -euo pipefail

DECKS=""; DRY=0; SRC_ROOT=""; QUAR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY=1; shift ;;
    --src-root)   SRC_ROOT="${2:?}"; shift 2 ;;
    --quarantine) QUAR="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            [[ -z "$DECKS" ]] && DECKS="$1" || { echo "regroup: extra arg $1" >&2; exit 2; }; shift ;;
  esac
done
[[ -n "$DECKS" && -d "$DECKS" ]] || { echo "usage: regroup_by_source.sh <decks_dir> [--dry-run]" >&2; exit 2; }
DECKS="$(cd "$DECKS" && pwd)"
SRC_ROOT="${SRC_ROOT:-$(dirname "$DECKS")}"
QUAR="${QUAR:-$DECKS/_duplicates}"

# reldir for a source video path -> subfolder hierarchy under SRC_ROOT (verbatim course names);
# fall back to the video's immediate parent folder name if it's not under SRC_ROOT.
reldir_for() {
  local src="$1" rel
  if [[ "$src" == "$SRC_ROOT/"* ]]; then
    rel="${src#$SRC_ROOT/}"; dirname "$rel"
  else
    basename "$(dirname "$src")"
  fi
}
# Finalized (topic-renamed) deck: rename_by_topic.sh has consumed deck.md into <slug>.md, so a
# finalized dir has a real *.md AND NO leftover deck.md. Requiring deck.md to be ABSENT is the
# reliable signal — merely "a *.md not named deck.md" is fooled by a stray/half-renamed *.md
# sitting next to an un-consumed deck.md.
is_renamed() {
  [[ -f "$1/deck.md" ]] && return 1
  find "$1" -maxdepth 1 -name '*.md' ! -name '*.bak' -print -quit | grep -q .
}

# ---- pass 1: collect leaf deck dirs (immediate children that hold their own evidence.md) ----
declare -A GROUP_DIRS   # key "reldir\tvstem" -> newline-joined dir list
declare -a LEAVES
noev=0; nosrc=0
for d in "$DECKS"/*/; do
  d="${d%/}"
  [[ "$d" == "$QUAR" ]] && continue
  ev="$d/evidence.md"
  [[ -f "$ev" ]] || { noev=$((noev+1)); continue; }          # course dirs & non-leaves have none
  src="$(grep -m1 -oE '/[^`]*\.(mkv|mp4|mov|webm|avi|m4v|MKV|MP4|MOV)' "$ev" || true)"
  [[ -n "$src" ]] || { echo "skip (no Source line): ${d#$DECKS/}" >&2; nosrc=$((nosrc+1)); continue; }
  rel="$(reldir_for "$src")"
  vstem="$(basename "$src")"; vstem="${vstem%.*}"
  key="$rel"$'\t'"$vstem"
  GROUP_DIRS["$key"]+="$d"$'\n'
  LEAVES+=("$d")
done

MAP="$DECKS/regroup-map.tsv"; : > "${MAP}.tmp"
moved=0; kept=0; quar=0; inplace=0

# ---- pass 2: per source-video group, pick keeper, quarantine the rest, then place keeper ----
for key in "${!GROUP_DIRS[@]}"; do
  rel="${key%%$'\t'*}"; vstem="${key##*$'\t'}"
  mapfile -t dirs < <(printf '%s' "${GROUP_DIRS[$key]}" | sed '/^$/d')

  keeper="${dirs[0]}"
  if [[ "${#dirs[@]}" -gt 1 ]]; then
    # rank: finalized(renamed) beats raw; within a tier, newest mtime wins
    best_score=-1; best_mtime=-1
    for d in "${dirs[@]}"; do
      score=0; is_renamed "$d" && score=1
      mt="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
      if (( score > best_score )) || { (( score == best_score )) && (( mt > best_mtime )); }; then
        best_score=$score; best_mtime=$mt; keeper="$d"
      fi
    done
    for d in "${dirs[@]}"; do
      [[ "$d" == "$keeper" ]] && continue
      if [[ "$DRY" -eq 1 ]]; then
        printf 'DUP  quarantine  %-45s (dup of %s)\n' "${d#$DECKS/}" "$vstem"
      else
        mkdir -p "$QUAR"; dest="$QUAR/$(basename "$d")"
        i=2; while [[ -e "$dest" ]]; do dest="$QUAR/$(basename "$d")-$i"; i=$((i+1)); done
        mv "$d" "$dest"
        printf 'dup  %-45s -> _duplicates/%s\n' "${d#$DECKS/}" "$(basename "$dest")"
      fi
      quar=$((quar+1))
    done
  fi

  # place the keeper under its reconstructed parent
  target_parent="$DECKS/$rel"; [[ "$rel" == "." ]] && target_parent="$DECKS"
  target="$target_parent/$(basename "$keeper")"
  printf '%s\t%s\n' "${keeper#$DECKS/}" "${target#$DECKS/}" >> "${MAP}.tmp"
  if [[ "$keeper" == "$target" ]]; then
    inplace=$((inplace+1)); continue
  fi
  if [[ "$DRY" -eq 1 ]]; then
    printf 'MOVE %-45s -> %s/\n' "${keeper#$DECKS/}" "${target#$DECKS/}"
  else
    mkdir -p "$target_parent"
    if [[ -e "$target" ]]; then echo "skip (target exists): ${target#$DECKS/}" >&2; continue; fi
    mv "$keeper" "$target"
    printf 'ok   %-45s -> %s/\n' "${keeper#$DECKS/}" "${target#$DECKS/}"
  fi
  moved=$((moved+1)); kept=$((kept+1))
done

if [[ "$DRY" -eq 1 ]]; then
  rm -f "${MAP}.tmp"
  echo "-- dry run: ${#LEAVES[@]} leaf deck(s); would move $moved, keep-in-place $inplace, quarantine $quar --"
else
  mv "${MAP}.tmp" "$MAP"
  echo "-- regrouped: moved $moved, in-place $inplace, quarantined $quar. map: $MAP --"
fi