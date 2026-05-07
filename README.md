# Claude Progress Dashboard

Drop-in productivity dashboard for any project worked on with Claude Code.

- **Tasks tab** — live tasks backed by `progress/tasks.json` (Claude and the dashboard read/write the same file).
- **History tab** — auto-renders `progress/PROGRESS-YYYY-MM-DD.md` files as a daily activity log.
- **Memory / Notes tabs** — static panes for whatever you want to keep handy.
- **Stop hook** — auto-creates today's progress file at the end of every Claude session, and reminds Claude to log entries when source files changed.

## Install into a project

```bash
./install.sh /path/to/your/project
# or with a custom display name:
./install.sh /path/to/your/project "My Cool App"
```

Idempotent — safe to re-run. Pass `--force` to overwrite.

## What it installs

```
your-project/
├── dashboard.html              # the UI
├── dashboard-server.py         # static server + /api/tasks endpoints
├── progress/
│   ├── tasks.json              # seeded empty
│   └── PROGRESS-YYYY-MM-DD.md  # today's log, seeded with header
└── .claude/
    ├── progress-watch.txt      # source dirs the Stop hook watches
    ├── hooks/
    │   └── check-progress-log.sh
    └── settings.json           # Stop hook entry appended (existing JSON preserved)
```

## Run

```bash
cd /path/to/your/project
python3 dashboard-server.py
open http://localhost:8765/dashboard.html
```

## Customize per project

Edit `.claude/progress-watch.txt` to list the source dirs that should trigger the
"log your progress" reminder. One glob per line. Defaults cover common JS/TS
layouts; for a Swift project use `App/**/*.swift`, `Core/**/*.swift`, etc.
