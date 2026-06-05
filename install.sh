#!/usr/bin/env sh
# Symlink each skill in this repo into ~/.claude/skills/
# Re-runnable: replaces existing symlinks, refuses to clobber real directories.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${HOME}/.claude/skills"
mkdir -p "$DEST"

for skill in "$REPO_DIR"/skills/*/; do
  name="$(basename "$skill")"
  target="$DEST/$name"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    echo "skip: $target exists and is not a symlink — remove it first" >&2
    continue
  fi
  ln -s "${skill%/}" "$target"
  echo "linked: $target -> ${skill%/}"
done
