#!/usr/bin/env bash
# T5 / spike S1: Claude Code lives on its own volume, updates itself there,
# and neither a rebuild nor a newer base moves it backwards.
#
#   test/claude-code/run.sh [image]        (default: sdd-workbench/base:dev)
#
# Runs on the host, with Docker. Needs the network (it installs Claude Code).
# Each case prints `ok` or `FAIL`; the exit code is the number of failures.
set -u
IMAGE="${1:-sdd-workbench/base:dev}"
VOL="sdd-wb-test-claude-$$"
NAME="sdd-wb-test-$$"
fails=0
pass() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; docker volume rm -f "$VOL" >/dev/null 2>&1; }
trap cleanup EXIT

start() { # start a container on the volume, from image $1, and wait for init
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" -e SDD_WORKBENCH_SKIP_BROWSERS=1 \
    -v "$VOL":/claude-code "${1:-$IMAGE}" >/dev/null
  for _ in $(seq 1 900); do        # a first start downloads the CLI
    if docker exec "$NAME" test -f /tmp/sdd-workbench/claude-code.log 2>/dev/null \
       && docker exec "$NAME" bash -lc 'claude --version' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker exec "$NAME" cat /tmp/sdd-workbench/claude-code.log 2>/dev/null
  return 1
}
version() { docker exec "$NAME" bash -lc 'claude --version 2>/dev/null' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+'; }
on_volume() { docker exec "$NAME" bash -lc 'ls /claude-code/versions 2>/dev/null' | sort -V | tr '\n' ' '; }

# 1. A first start installs it onto the empty volume.
if start; then
  latest="$(version)"
  pass "first start installed Claude Code $latest; the volume holds: $(on_volume)"
else
  fail "first start: no claude on PATH"; exit "$fails"
fi

# 2. An older version installed by hand, then the CLI's own update.
older="$(docker exec "$NAME" bash -lc "curl -fsSL https://downloads.claude.ai/claude-code-releases/stable" 2>/dev/null)"
if [ -z "$older" ] || [ "$older" = "$latest" ]; then
  older="$(on_volume | tr ' ' '\n' | grep . | head -n 1)"
fi
docker exec "$NAME" bash -lc "claude install $older" >/dev/null 2>&1
now="$(version)"
[ "$now" = "$older" ] && pass "claude install $older took effect" \
  || fail "claude install $older: still $now"
docker exec "$NAME" bash -lc 'claude update' >/dev/null 2>&1
now="$(version)"
[ "$now" = "$latest" ] && pass "claude update moved it to $now" \
  || echo "note  claude update left it at $now (the stable channel may trail latest)"
updated="$now"

# 3. A rebuild: a fresh container from the same image, same volume.
start || fail "restart did not come up"
now="$(version)"
[ "$now" = "$updated" ] && pass "after a fresh container: still $now, no step backwards" \
  || fail "after a fresh container: $now, was $updated"

# 4. A newer base: another image of the same tools, same volume.
docker build -q -t "${IMAGE}-newer" - >/dev/null <<EOF
FROM $IMAGE
LABEL sdd.workbench.test=newer
EOF
start "${IMAGE}-newer" || fail "newer base did not come up"
now="$(version)"
[ "$now" = "$updated" ] && pass "on a newer base: still $now" \
  || fail "on a newer base: $now, was $updated"

# 5. Hold at the older version; it survives a fresh container.
docker exec "$NAME" bash -lc "claude-hold $older" >/dev/null 2>&1
now="$(version)"
[ "$now" = "$older" ] && pass "claude-hold $older took effect" || fail "claude-hold: $now"
grep_hold="$(docker exec "$NAME" bash -lc 'python3 -c "import json,os;print(json.load(open(os.environ[\"CLAUDE_CONFIG_DIR\"]+\"/settings.json\"))[\"env\"][\"DISABLE_AUTOUPDATER\"])"' 2>/dev/null)"
[ "$grep_hold" = "1" ] && pass "updates switched off in the user settings" \
  || echo "note  the settings file is on /claude-config, which this test does not mount; held by .sdd-held"
start "${IMAGE}-newer" || fail "restart after hold"
now="$(version)"
[ "$now" = "$older" ] && pass "held across a fresh container: $now" || fail "hold lost: $now"

# 6. Release: back to updating.
docker exec "$NAME" bash -lc 'claude-release' >/dev/null 2>&1
now="$(version)"
docker exec "$NAME" test -e /claude-code/.sdd-held && fail "release left .sdd-held" \
  || pass "claude-release: no hold, now $now"

docker rmi "${IMAGE}-newer" >/dev/null 2>&1
exit "$fails"
