#!/usr/bin/env bash
# plannotator-wrapper:per-worktree-port
#
# Shim installed at /home/dev/.local/bin/plannotator. Assigns a unique
# PLANNOTATOR_PORT so multiple concurrent Claude Code sessions inside the
# same devcontainer never collide on the default port (9999, or REMOTE
# mode's 19432).
#
# Storage strategy:
# - In a git worktree → cache the port in $GIT_DIR/plannotator-port. For
#   the main checkout that's .git/plannotator-port; for a worktree it's
#   .git/worktrees/<name>/plannotator-port. Both paths sit inside .git/,
#   which `claude -w` does not touch.
# - Outside a git worktree → cache by process-group ID. Each Claude Code
#   session in a terminal has its own PGID, so different sessions get
#   different ports and a single session's plannotator invocations reuse
#   the same URL across plan-mode revisions. The file lives in $TMPDIR,
#   so it's cleaned up automatically when the container is rebuilt.
#
# The real Plannotator binary lives at /home/dev/.local/bin/plannotator.real.

GIT_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null)
if [ -n "$GIT_DIR" ]; then
  PORT_FILE="$GIT_DIR/plannotator-port"
else
  PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  PORT_FILE="${TMPDIR:-/tmp}/plannotator-port-${PGID:-$$}"
fi

# The port comes from DEVCONTAINER_PORT_RANGE (what docker-compose.yml publishes,
# 20000-20099 by default), so the UI is reachable from the host without an IDE's
# port forwarding. A cached port is kept only while it is usable: any port when no
# range is set, otherwise one inside the range, so changing the range (or caching
# a port before there was one) re-picks instead of leaving a URL that cannot load.
# Any free port is the last resort, with a warning, since the host cannot reach it.
PORT=$(python3 - "$PORT_FILE" <<'PY'
import os, random, socket, sys

lo, _, hi = os.environ.get("DEVCONTAINER_PORT_RANGE", "").partition("-")
ranged = lo.isdigit() and hi.isdigit() and int(lo) <= int(hi)
pool = range(int(lo), int(hi) + 1) if ranged else range(0)
try:
    cached = int(open(sys.argv[1]).read().strip())
except (OSError, ValueError):
    cached = 0
if cached and (not ranged or cached in pool):
    print(cached)
    sys.exit()

if not ranged and os.environ.get("DEVCONTAINER") == "true":
    sys.stderr.write("plannotator: DEVCONTAINER_PORT_RANGE is not set (or not <first>-<last>): the port "
                     "picked is not published, so the host cannot reach it. Recreate the dev container.\n")
ports = list(pool)
random.shuffle(ports)
for p in ports:
    s = socket.socket()
    try:
        s.bind(("", p))
        print(p)
        sys.exit()
    except OSError:
        pass
    finally:
        s.close()
if ranged:
    sys.stderr.write("plannotator: no free port in %s: the port picked is not published, so the host "
                     "cannot reach it.\n" % os.environ["DEVCONTAINER_PORT_RANGE"])
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
PY
)
printf '%s\n' "$PORT" > "$PORT_FILE"
export PLANNOTATOR_PORT="$PORT"

# Open the review page on the host's browser through host-open (the workbench
# installs it in /usr/local/bin), unless a browser was chosen already. Set here
# rather than in the compose file so it can never name a program that is not
# there.
if [ -z "${PLANNOTATOR_BROWSER:-}" ] && command -v host-open >/dev/null 2>&1; then
  PLANNOTATOR_BROWSER="$(command -v host-open)"
  export PLANNOTATOR_BROWSER
fi

# Hook-mode invocation (no CLI args, JSON event on stdin): post-process the
# response to strip any `setMode` entries from updatedPermissions, so Claude
# Code keeps the session's current permission mode (e.g., the project's
# `auto`) after plan approval. The Plannotator setup dialog still shows on
# first use, but whatever the user picks there is silently ignored — only
# the mode set in .claude/settings.json governs.
if [ $# -eq 0 ]; then
  response=$(/home/dev/.local/bin/plannotator.real)
  rc=$?
  filtered=$(printf '%s' "$response" | jq -c '
    if .hookSpecificOutput?.decision?.updatedPermissions then
      .hookSpecificOutput.decision.updatedPermissions
        |= map(select(.type != "setMode"))
      | if (.hookSpecificOutput.decision.updatedPermissions | length) == 0
          then del(.hookSpecificOutput.decision.updatedPermissions)
          else . end
    else . end
  ' 2>/dev/null)
  if [ -n "$filtered" ]; then
    printf '%s\n' "$filtered"
  else
    printf '%s' "$response"
  fi
  exit "$rc"
fi

exec /home/dev/.local/bin/plannotator.real "$@"
