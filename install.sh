#!/usr/bin/env sh
# Symlink each skill in this repo into ~/.claude/skills/, and the codex-* skills
# (which Codex runs, not Claude) additionally into ~/.codex/skills/.
# Re-runnable: replaces existing symlinks, refuses to clobber real directories.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${HOME}/.claude/skills"
CODEX_DEST="${CODEX_HOME:-${HOME}/.codex}/skills"
mkdir -p "$DEST"

link() {
  skill="$1"; target="$2"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    echo "skip: $target exists and is not a symlink — remove it first" >&2
    return 0
  fi
  ln -s "$skill" "$target"
  echo "linked: $target -> $skill"
}

for skill in "$REPO_DIR"/skills/*/; do
  name="$(basename "$skill")"
  case "$name" in
    # The codex-* skills are written for Codex as the executing agent — they instruct it to
    # spawn its own subagents, which Claude Code has no equivalent of. They go to
    # $CODEX_HOME/skills only; linking them into ~/.claude/skills would offer Claude a
    # workflow it cannot run.
    codex-*)
      if [ -d "${CODEX_HOME:-${HOME}/.codex}" ]; then
        mkdir -p "$CODEX_DEST"
        link "${skill%/}" "$CODEX_DEST/$name"
      else
        echo "skip: $name is a Codex skill and no Codex home was found" >&2
      fi
      ;;
    *)
      link "${skill%/}" "$DEST/$name"
      ;;
  esac
done
