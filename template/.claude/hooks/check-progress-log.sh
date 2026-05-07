#!/usr/bin/env bash
# Stop hook: ensure today's progress/PROGRESS-YYYY-MM-DD.md exists with a header,
# and if source files changed, remind Claude to append an entry.
#
# Source dirs to watch are read from .claude/progress-watch.txt (one glob per line),
# falling back to a sensible default set.
set -u

# Resolve to the main repo root, even when invoked from inside a worktree.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's,/\.git$,,')"
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
cd "$REPO_ROOT" || exit 0

TODAY="$(date +%Y-%m-%d)"
PROGRESS_FILE="progress/PROGRESS-${TODAY}.md"

# Always make sure today's file exists with a header — so the dashboard's
# "Today" view always has something to render, even before the first entry.
if [ ! -f "$PROGRESS_FILE" ]; then
  mkdir -p progress
  printf '# Progress %s\n\n' "$TODAY" > "$PROGRESS_FILE"
fi

# Load source-dir globs to watch. Default to common code dirs across stacks.
WATCH_FILE=".claude/progress-watch.txt"
WATCH_GLOBS=()
if [ -f "$WATCH_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] && WATCH_GLOBS+=("$line")
  done < "$WATCH_FILE"
fi
if [ "${#WATCH_GLOBS[@]}" -eq 0 ]; then
  WATCH_GLOBS=(
    'src/**/*'
    'app/**/*'
    'lib/**/*'
    'pages/**/*'
    'components/**/*'
  )
fi

DIRTY="$(git status --porcelain -- "${WATCH_GLOBS[@]}" 2>/dev/null)"

if [ -z "$DIRTY" ]; then
  exit 0
fi

if grep -qE '^- [0-9]{2}:[0-9]{2} —' "$PROGRESS_FILE"; then
  exit 0
fi

cat <<EOF
Before stopping: source files changed but today's progress log (${PROGRESS_FILE}) has no entries. Append a one-line entry describing what changed, format: "- HH:MM — short description".
EOF
exit 2
