#!/usr/bin/env bash
# fix_mermaid_labels.sh <decks_dir> [--dry-run]
#
# Post-generation sanitizer: local models sometimes put ';' inside Mermaid message/Note
# labels (e.g.  R->>F: Remove key; release resources). Mermaid treats ';' as a statement
# separator even inside a label, so it errors with "Parse error … got 'NEWLINE'".
# This rewrites ';' -> ',' on Mermaid lines INSIDE ```mermaid fences, EXCEPT on
# classDef/style/linkStyle lines where a trailing ';' is legal.
#
# Idempotent. Edits <decks_dir>/*/deck.md in place unless --dry-run.
set -euo pipefail

DECKS="${1:?usage: fix_mermaid_labels.sh <decks_dir> [--dry-run]}"
DRY=0; [[ "${2:-}" == "--dry-run" ]] && DRY=1
[[ -d "$DECKS" ]] || { echo "not a directory: $DECKS" >&2; exit 2; }
DECKS="$(cd "$DECKS" && pwd)"

files=0; changed=0
# RECURSIVE: deck.md at any depth (flat <decks>/<stem>/ or mirrored <decks>/<course>/<stem>/).
while IFS= read -r -d '' deck; do
  files=$((files+1))
  # awk: inside a mermaid fence, on non-classDef/style/linkStyle lines, ; -> ,
  new="$(awk '
    /^[[:space:]]*```mermaid/ { inm=1; print; next }
    /^[[:space:]]*```/        { inm=0; print; next }
    inm && /;/ && $0 !~ /classDef|linkStyle|^[[:space:]]*style / { gsub(/;/, ","); print; next }
    { print }
  ' "$deck")"
  if [[ "$new" != "$(cat "$deck")" ]]; then
    changed=$((changed+1))
    if [[ "$DRY" -eq 1 ]]; then
      echo "WOULD FIX: ${deck#$DECKS/}"
      diff <(cat "$deck") <(printf '%s\n' "$new") | grep -E '^[<>]' | head -8 || true
    else
      printf '%s\n' "$new" > "$deck"
      echo "fixed: ${deck#$DECKS/}"
    fi
  fi
done < <(find "$DECKS" -mindepth 2 -name deck.md -print0)
echo "-- scanned $files deck.md, $([[ "$DRY" -eq 1 ]] && echo 'would fix' || echo 'fixed') $changed --"
