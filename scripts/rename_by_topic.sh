#!/usr/bin/env bash
# rename_by_topic.sh — after decks are generated, rename each deck dir AND its deck.md
# to the deck's topic (the first "# H1" title in deck.md), slugified.
#
#   <decks>/vokoscreen-2025-03-16_07-08-57/deck.md   (# AI Transformation Across Industries)
#   ->  <decks>/ai-transformation-across-industries/ai-transformation-across-industries.md
#
# RECURSIVE + hierarchy-aware: finds deck.md at ANY depth and renames the folder IN PLACE,
# within its own parent directory. So a mirrored tree is preserved:
#   <decks>/InfiniBand Professional/Unit 4 - Link Layer/deck.md
#   ->  <decks>/InfiniBand Professional/unit-4-link-layer/unit-4-link-layer.md
# Slug collisions are de-conflicted per-parent (two courses may reuse a slug independently).
#
# Usage:
#   rename_by_topic.sh <decks_dir> [--dry-run]
#
# Idempotent: a deck already renamed has <slug>.md (not deck.md) so it is not re-touched;
# dirs whose deck.md has no H1 are skipped. Mapping -> <decks_dir>/renamed-map.tsv (old<TAB>new).
set -euo pipefail

DECKS="${1:?usage: rename_by_topic.sh <decks_dir> [--dry-run]}"
DRY=0; [[ "${2:-}" == "--dry-run" ]] && DRY=1
[[ -d "$DECKS" ]] || { echo "not a directory: $DECKS" >&2; exit 2; }
DECKS="$(cd "$DECKS" && pwd)"

slugify() {  # stdin -> lowercase, spaces/punct -> single dash, trimmed, max 60 chars
  tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-60 | sed -E 's/-+$//'
}

MAP="$DECKS/renamed-map.tsv"
: > "${MAP}.tmp"
declare -A seen                       # key: "<parent>/<slug>" -> de-collide within a parent
n=0; skipped=0

# -mindepth 2: deck.md lives at <...>/<stem>/deck.md, so its dir is never $DECKS itself.
while IFS= read -r -d '' deck; do
  dir="$(dirname "$deck")"
  parent="$(dirname "$dir")"
  # first markdown H1 ("# Title") in the BODY — skip the YAML frontmatter block, whose
  # template placeholder ("# Fill in from evidence.md…") would otherwise win.
  title="$(awk '
    NR==1 && /^---[[:space:]]*$/ { infm=1; next }
    infm && /^---[[:space:]]*$/  { infm=0;  next }
    infm { next }
    /^# / { sub(/^#[[:space:]]+/, ""); print; exit }
  ' "$deck")"
  if [[ -z "$title" ]]; then
    echo "skip (no H1): ${dir#$DECKS/}" >&2; skipped=$((skipped+1)); continue
  fi
  slug="$(printf '%s' "$title" | slugify)"
  [[ -z "$slug" ]] && { echo "skip (empty slug): ${dir#$DECKS/}" >&2; skipped=$((skipped+1)); continue; }

  # de-collide within this parent
  base="$slug"; i=2
  while [[ -n "${seen[$parent/$slug]:-}" || ( -e "$parent/$slug" && "$parent/$slug" != "$dir" ) ]]; do
    slug="${base}-$i"; i=$((i+1))
  done
  seen["$parent/$slug"]=1

  newdir="$parent/$slug"
  printf '%s\t%s\n' "${dir#$DECKS/}" "${newdir#$DECKS/}" >> "${MAP}.tmp"
  if [[ "$DRY" -eq 1 ]]; then
    printf 'DRY  %-55s -> %s/%s.md\n' "${dir#$DECKS/}" "${newdir#$DECKS/}" "$slug"
  else
    [[ "$dir" != "$newdir" ]] && mv "$dir" "$newdir"
    mv "$newdir/deck.md" "$newdir/$slug.md"
    printf 'ok   %-55s -> %s/%s.md\n' "${dir#$DECKS/}" "${newdir#$DECKS/}" "$slug"
  fi
  n=$((n+1))
done < <(find "$DECKS" -mindepth 2 -name deck.md -print0)

if [[ "$DRY" -eq 1 ]]; then
  rm -f "${MAP}.tmp"
  echo "-- dry run: $n would be renamed, $skipped skipped --"
else
  mv "${MAP}.tmp" "$MAP"
  echo "-- renamed $n, skipped $skipped. map: $MAP --"
fi
