#!/usr/bin/env bash
# Stop hook: ensure today's progress/PROGRESS-YYYY-MM-DD.md exists, and
# auto-append entries for any commits made today that aren't already logged.
#
# Source dirs to watch are read from .claude/progress-watch.txt (one glob per
# line), with a sensible default set if missing. Only commits touching those
# paths are logged; pure-progress commits are skipped to avoid recursion.
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

# Always make sure today's file exists with a header.
if [ ! -f "$PROGRESS_FILE" ]; then
  mkdir -p progress
  printf '# Progress %s\n\n' "$TODAY" > "$PROGRESS_FILE"
fi

# Load source-dir globs to watch.
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
    'App/**/*'
    'lib/**/*'
    'pages/**/*'
    'components/**/*'
    'Core/**/*'
    'Features/**/*'
    'Navigation/**/*'
    'WatchApp/**/*'
    'Algorithms/**/*'
  )
fi

# Auto-log: walk today's commits across ALL refs (so work on Claude worktree
# branches still gets logged), skip ones already in the progress file, skip
# ones that only touch progress/ (avoid recursion), append the rest.
SINCE="$TODAY 00:00"
UNTIL="$TODAY 23:59"

# --all walks every ref, --reverse sorts ascending by date so we append in
# chronological order. Dedup by SHA in case a commit is reachable from
# multiple refs.
COMMITS="$(git --no-pager log --all --since="$SINCE" --until="$UNTIL" --reverse --format='%H' 2>/dev/null | awk '!seen[$0]++')"

APPENDED=0
if [ -n "$COMMITS" ]; then
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    short="$(git rev-parse --short=7 "$sha")"

    # Skip if this commit's SHA is already mentioned anywhere in today's file.
    if grep -qF "($short)" "$PROGRESS_FILE"; then
      continue
    fi

    # Does this commit touch any watched source path?
    files="$(git --no-pager show --name-only --format= "$sha" 2>/dev/null)"
    [ -z "$files" ] && continue

    touched_source=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # Skip pure progress-log changes
      case "$f" in
        progress/*) continue ;;
      esac
      for glob in "${WATCH_GLOBS[@]}"; do
        # bash extglob/glob match. Use case for portable globbing.
        case "$f" in
          $glob) touched_source=1; break ;;
        esac
      done
      [ "$touched_source" -eq 1 ] && break
    done <<< "$files"

    [ "$touched_source" -eq 0 ] && continue

    # Build the entry line. Tag with branch name if this commit is NOT on
    # the current branch (so it's clear when work happened in a worktree).
    time_hm="$(git --no-pager show -s --format='%cd' --date=format:'%H:%M' "$sha")"
    subject="$(git --no-pager show -s --format='%s' "$sha")"
    cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    branch_tag=""
    if [ -n "$cur_branch" ] && ! git merge-base --is-ancestor "$sha" "$cur_branch" 2>/dev/null; then
      # Find a non-HEAD branch this commit is on.
      other_branch="$(git branch --contains "$sha" --format='%(refname:short)' 2>/dev/null \
        | grep -v "^$cur_branch$" | head -1)"
      [ -n "$other_branch" ] && branch_tag=" — branch $other_branch"
    fi
    printf -- '- %s — %s (%s%s)\n' "$time_hm" "$subject" "$short" "$branch_tag" >> "$PROGRESS_FILE"
    APPENDED=$((APPENDED + 1))
  done <<< "$COMMITS"
fi

# If there are uncommitted source-file changes and the file still has no
# entries, nudge Claude to log a manual one — auto-log only catches commits.
DIRTY="$(git status --porcelain -- "${WATCH_GLOBS[@]}" 2>/dev/null)"
if [ -n "$DIRTY" ] && ! grep -qE '^- [0-9]{2}:[0-9]{2} —' "$PROGRESS_FILE"; then
  cat <<EOF
Before stopping: source files changed but today's progress log (${PROGRESS_FILE}) has no entries. Append a one-line entry describing what changed, format: "- HH:MM — short description".
EOF
  exit 2
fi

if [ "$APPENDED" -gt 0 ]; then
  echo "[progress hook] auto-logged $APPENDED commit(s) to $PROGRESS_FILE"
fi
exit 0
