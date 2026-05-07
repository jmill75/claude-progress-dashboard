#!/usr/bin/env bash
# Install the Claude progress dashboard into a target project.
#
# Usage:
#   ./install.sh /path/to/your/project
#   ./install.sh /path/to/your/project "My Project Name"
#
# Idempotent — safe to re-run. Existing files are NOT overwritten unless --force.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/template"

FORCE=0
TARGET=""
PROJECT_NAME=""

for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      elif [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$arg"
      fi
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "error: target project path required" >&2
  echo "usage: $0 /path/to/project [\"Project Name\"] [--force]" >&2
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"

if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$TARGET")"
fi

# Slug used for localStorage keys: lowercase, alphanum + underscore only.
PROJECT_SLUG="$(echo "$PROJECT_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '_' \
  | sed 's/__*/_/g; s/^_//; s/_$//')"

if [ -z "$PROJECT_SLUG" ]; then
  PROJECT_SLUG="project"
fi

echo "Installing dashboard"
echo "  target:       $TARGET"
echo "  project name: $PROJECT_NAME"
echo "  slug:         $PROJECT_SLUG"
echo

mkdir -p "$TARGET/.claude/hooks" "$TARGET/progress"

copy_with_substitution() {
  local src="$1"
  local dst="$2"
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    echo "  skip (exists): ${dst#$TARGET/}"
    return
  fi
  sed -e "s/__PROJECT_NAME__/$PROJECT_NAME/g" \
      -e "s/__PROJECT_SLUG__/$PROJECT_SLUG/g" \
      "$src" > "$dst"
  echo "  wrote:         ${dst#$TARGET/}"
}

copy_plain() {
  local src="$1"
  local dst="$2"
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    echo "  skip (exists): ${dst#$TARGET/}"
    return
  fi
  cp "$src" "$dst"
  echo "  wrote:         ${dst#$TARGET/}"
}

copy_with_substitution "$TEMPLATE_DIR/dashboard.html"      "$TARGET/dashboard.html"
copy_with_substitution "$TEMPLATE_DIR/dashboard-server.py" "$TARGET/dashboard-server.py"
copy_plain             "$TEMPLATE_DIR/.claude/hooks/check-progress-log.sh" \
                       "$TARGET/.claude/hooks/check-progress-log.sh"
chmod +x "$TARGET/dashboard-server.py" "$TARGET/.claude/hooks/check-progress-log.sh" 2>/dev/null || true

# Seed an empty tasks.json so the API has something to read.
TASKS_JSON="$TARGET/progress/tasks.json"
if [ ! -f "$TASKS_JSON" ]; then
  cat > "$TASKS_JSON" <<'JSON'
{
  "version": 1,
  "updatedAt": "1970-01-01T00:00:00Z",
  "tasks": []
}
JSON
  echo "  wrote:         progress/tasks.json"
fi

# Seed today's progress file so the dashboard has something to show right away.
TODAY="$(date +%Y-%m-%d)"
TODAYS_FILE="$TARGET/progress/PROGRESS-${TODAY}.md"
if [ ! -f "$TODAYS_FILE" ]; then
  printf '# Progress %s\n\n' "$TODAY" > "$TODAYS_FILE"
  echo "  wrote:         progress/PROGRESS-${TODAY}.md"
fi

# Seed a watch-globs file with sensible defaults if missing.
WATCH_FILE="$TARGET/.claude/progress-watch.txt"
if [ ! -f "$WATCH_FILE" ]; then
  cat > "$WATCH_FILE" <<'TXT'
# One source-dir glob per line. The Stop hook nudges Claude to log progress
# whenever git status shows changes under any of these. Comments start with #.
src/**/*
app/**/*
lib/**/*
pages/**/*
components/**/*
TXT
  echo "  wrote:         .claude/progress-watch.txt"
fi

# Wire the Stop hook into the project's .claude/settings.json (idempotent).
SETTINGS_FILE="$TARGET/.claude/settings.json"
HOOK_CMD=".claude/hooks/check-progress-log.sh"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
already = any(
    any(h.get("command") == cmd for h in (entry.get("hooks") or []))
    for entry in stop if isinstance(entry, dict)
)
if not already:
    stop.append({
        "hooks": [{
            "type": "command",
            "command": cmd,
            "asyncRewake": True,
            "rewakeSummary": "Progress log reminder"
        }]
    })
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  wrote:         .claude/settings.json (added Stop hook)")
else:
    print(f"  skip (exists): .claude/settings.json hook already wired")
PY
else
  echo "  warn: python3 not available; manually add the Stop hook to .claude/settings.json"
fi

echo
echo "Done. To run:"
echo "  cd $TARGET"
echo "  python3 dashboard-server.py"
echo "  open http://localhost:8765/dashboard.html"
