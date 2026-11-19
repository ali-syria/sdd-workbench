#!/usr/bin/env bash
# T6: one preset's composed dev container, built and used.
#
#   test/preset-smoke.sh <preset> [--keep] [--work <dir>]
#
# Generates a project the way app Step 5 does (`sdd init`, then
# `sdd scaffold --preset <preset>`), builds its composed dev container with the
# dev-container CLI, holds the image to the sum of its parts' size budgets
# (the base and each add-on it carries, budgets.json), and inside it runs the
# framework's gates and every codebase's own tests.
#
# Inputs (environment):
#   SDD_FRAMEWORK                  a checkout of the framework (required)
#   SDD_SCAFFOLD_SCRIPTS           a checkout of scaffold-scripts; without it the
#                                  registry's URLs are cloned as scaffolds.json says
#   LARAVEL_SCAFFOLD_TEMPLATE_DIR  a checkout of laravel-scaffold (optional)
#   SDD_WORKBENCH_SRC              this checkout, to compose against the local
#                                  workbench instead of the published images
#                                  (optional; CI leaves it unset)
#
# Needs Docker, git, python3, and Node for `npx @devcontainers/cli`. Every host
# path the container mounts points into the work directory, never at the
# person's own SSH key or Claude configuration. Removes what it started unless
# --keep.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
CLI="@devcontainers/cli@0.80.0"
PRESET="${1:?usage: preset-smoke.sh <preset> [--keep] [--work <dir>]}"; shift
KEEP=0; WORK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --work) WORK="$2"; shift 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done
FW="${SDD_FRAMEWORK:?set SDD_FRAMEWORK to a framework checkout}"
[ -n "$WORK" ] || WORK="$(mktemp -d "${TMPDIR:-/tmp}/sdd-t6-$PRESET-XXXX")"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
P="$WORK/smoke-$PRESET"; NAME="preset-smoke-$PRESET"
fails=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
sdd()  { python3 "$FW/tools/sdd" "$@"; }

cleanup() {
  [ "$KEEP" = 1 ] && { echo "kept: $WORK (project $P, container $NAME)"; return; }
  local proj
  proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$NAME" 2>/dev/null)"
  if [ -n "$proj" ]; then
    docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 \
      || docker rm -f $(docker ps -aq --filter "label=com.docker.compose.project=$proj") >/dev/null 2>&1
    docker volume ls -q --filter "label=com.docker.compose.project=$proj" | xargs -r docker volume rm >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== $PRESET: generate"
rm -rf "$P"
sdd init --target "$P" --name "Preset Smoke" --date "$(date -u +%F)" >/dev/null || { fail "sdd init"; exit 1; }
git -C "$P" init -q && git -C "$P" add -A \
  && git -C "$P" -c user.name=T6 -c user.email=t6@example.invalid commit -qm "sdd init" || { fail "git"; exit 1; }
if [ -n "${SDD_SCAFFOLD_SCRIPTS:-}" ]; then
  # Point every registered scaffold at the local checkout, so a branch nobody
  # pushed is what runs.
  python3 - "$FW/tools/sdd/scaffolds.json" "$SDD_SCAFFOLD_SCRIPTS" "$WORK/scaffolds.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
for name, entry in data["scaffolds"].items():
    if isinstance(entry, dict) and "script_path" in entry:
        script = os.path.join(sys.argv[2], entry["script_path"])
        if os.path.isfile(script):
            entry["url"] = script
            del entry["script_path"]
json.dump(data, open(sys.argv[3], "w"), indent=2)
PY
  export SDD_SCAFFOLD_REGISTRY="$WORK/scaffolds.json"
fi
export LARAVEL_SCAFFOLD_INSTALL=none
compose_args=()
[ -n "${SDD_WORKBENCH_SRC:-}" ] && compose_args=(--workbench "$SDD_WORKBENCH_SRC")
out="$(sdd scaffold --preset "$PRESET" --name "Preset Smoke" --target "$P" 2>&1)"; code=$?
if [ "$code" != 0 ] && [ "$code" != 2 ]; then
  echo "$out" | tail -40; fail "sdd scaffold --preset $PRESET (exit $code)"; exit 1
fi
if [ ${#compose_args[@]} -gt 0 ]; then sdd compose --target "$P" "${compose_args[@]}" >/dev/null; fi
ok "generated: $(python3 -c "import json;print(', '.join(json.load(open('$P/.sdd-codebases.json'))['codebases']))")"

# Every host path the container mounts goes into the work directory.
H="$WORK/host"; mkdir -p "$H/claude-config" "$H/history" "$H/plannotator"; : > "$H/dummy-key"
python3 - "$P/.devcontainer/.env" "$H" "$NAME" <<'PY'
import sys
env, h, name = sys.argv[1:4]
values = {"GIT_AUTHOR_NAME": "T6", "GIT_AUTHOR_EMAIL": "t6@example.invalid",
          "GITHUB_SSH_KEY": f"{h}/dummy-key", "GITHUB_TOKEN": "",
          "CLAUDE_CONFIG_HOST_DIR": f"{h}/claude-config",
          "COMMAND_HISTORY_HOST_DIR": f"{h}/history",
          "PLANNOTATOR_CONFIG_HOST_DIR": f"{h}/plannotator",
          "DEVCONTAINER_NAME": name}
lines, seen = [], set()
for line in open(env).read().splitlines():
    key = line.split("=", 1)[0]
    if key in values and not line.startswith("#"):
        lines.append(f"{key}={values[key]}"); seen.add(key)
    else:
        lines.append(line)
lines += [f"{k}={v}" for k, v in values.items() if k not in seen]
open(env, "w").write("\n".join(lines) + "\n")
PY

echo "== $PRESET: build and start the dev container"
# A build that runs out of Docker's disk fails deep in a post-create step,
# as ENOSPC from npm (seen 2026-11-19). Say so first instead.
free_gb="$(docker run --rm alpine:3.20 df -Pk / 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')"
need_gb="${SDD_T6_MIN_FREE_GB:-5}"
if [ -n "$free_gb" ] && [ "$free_gb" -lt "$need_gb" ]; then
  fail "Docker has ${free_gb} GB free and a preset's container needs about ${need_gb}: free some (docker system df), or set SDD_T6_MIN_FREE_GB"
  exit 1
fi
export npm_config_fetch_retries=6 npm_config_fetch_timeout=600000
# The CLI can miss the container's start event and wait for it forever
# (seen 2026-11-19). The watchdog stops it only in that state: the container
# has run for two minutes and the CLI has not run anything in it yet, so no
# life-cycle command has started and a second `up` loses nothing.
up_log="$WORK/up.log"
python3 - "$CLI" "$P" "$NAME" "$up_log" <<'PY'
import calendar, subprocess, sys, time
cli, project, name, log = sys.argv[1:5]
def started_for():
    r = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}} {{.State.StartedAt}}", name],
                       capture_output=True, text=True)
    if r.returncode or not r.stdout.startswith("true"):
        return 0
    stamp = r.stdout.split()[1][:19]
    return time.time() - calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%S"))
for attempt in (1, 2):
    with open(log, "a") as fh:
        proc = subprocess.Popen(["npx", "-y", cli, "up", "--workspace-folder", project,
                                 "--log-level", "debug"], stdout=fh, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            time.sleep(10)
            text = open(log).read()
            if "Run in container" not in text.split("=== attempt")[-1] and started_for() > 120:
                proc.kill(); proc.wait()
                fh.write("\n=== attempt 2: the CLI missed the start event\n"); fh.flush()
                break
        else:
            sys.exit(proc.returncode)
sys.exit(1)
PY
up_code=$?
outcome="$(grep -o '{"outcome":"[a-z]*"' "$up_log" | tail -1)"
if [ "$up_code" = 0 ] && [ "$outcome" = '{"outcome":"success"' ]; then ok "devcontainer up"
else tail -30 "$up_log"; fail "devcontainer up (exit $up_code, $outcome)"; exit 1; fi

echo "== $PRESET: size"
image="$(docker inspect -f '{{.Image}}' "$NAME")"
mb="$(docker image inspect -f '{{.Size}}' "$image" | awk '{printf "%d", $1/1048576}')"
limit="$(python3 - "$ROOT/budgets.json" "$P/.devcontainer/devcontainer.json" <<'PY'
import json, re, sys
budgets = json.load(open(sys.argv[1]))
text = re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[2]).read())
features = json.loads(text).get("features") or {}
total = budgets["base"]
for ref in features:
    m = re.search(r"sdd-workbench/([a-z-]+):", ref) or re.search(r"features/([a-z-]+)$", ref)
    if m and m.group(1) in budgets:
        total += budgets[m.group(1)]
print(total)
PY
)"
if [ "$mb" -le "$limit" ]; then ok "image ${mb} MB (budget ${limit}: the base and its add-ons)"
else fail "image ${mb} MB, over its budget of ${limit}"; fi

echo "== $PRESET: inside"
inside() { npx -y "$CLI" exec --workspace-folder "$P" bash -lc "$1" 2>&1 | grep -v 'setlocale'; return "${PIPESTATUS[0]}"; }
want_hash="$(sdd compose --hash --target "$P")"
got="$(inside 'echo "$(id -un) $SDD_DEVCONTAINER_HASH"' | tail -1)"
[ "$got" = "dev $want_hash" ] && ok "user dev, hash $want_hash" || fail "user and hash: '$got', want 'dev $want_hash'"
inside 'node --version && python3 --version && gh --version | head -1 && (php --version 2>/dev/null | head -1 || true)' | sed 's/^/      /'
out="$(inside 'cd /workspace && python3 tools/spec-check/spec_check.py --root specs; echo "exit $?"')"
echo "$out" | grep -q Traceback && fail "spec-check crashed" || ok "spec-check runs: $(echo "$out" | grep -E '^spec-check:' | tail -1)"
inside 'cd /workspace && python3 tools/sdd compose --check' >/dev/null && ok "compose --check clean inside" || fail "compose --check inside"
for cb in $(python3 -c "
import json
for n, c in json.load(open('$P/.sdd-codebases.json'))['codebases'].items():
    if c.get('kind') in ('service', 'client'): print(n + ':' + c['path'])"); do
  name="${cb%%:*}"; path="${cb#*:}"
  if [ -f "$P/$path/artisan" ]; then cmd="cd $path && php artisan test"
  elif [ -f "$P/$path/package.json" ]; then
    # The template's own gates, those it declares, in this order.
    # e2e only where a channel driver runs in this container; a codebase whose
    # driver needs a device (the phone's, on the bridge) builds its bundle
    # instead, which is what the container can prove.
    steps="$(python3 -c "
import json, sys
scripts = json.load(open(sys.argv[1])).get('scripts') or {}
try:
    drivers = (json.load(open(sys.argv[2])).get('agent_assets') or {}).get('channel_drivers') or []
except (OSError, ValueError):
    drivers = []
here = any(d.get('runs_on', 'container') == 'container' for d in drivers if isinstance(d, dict))
gates = ['typecheck', 'lint', 'test'] + (['e2e'] if here or not drivers else ['export'])
print(' && '.join('npm run -s ' + s for s in ('verify',) if s in scripts)
      or ' && '.join('npm run -s ' + s for s in gates if s in scripts))
" "$P/$path/package.json" "$P/$path/.sdd-scaffold.json")"
    [ -n "$steps" ] || { echo "skip  $name: no T1 command known"; continue; }
    cmd="cd $path && $steps"
  else echo "skip  $name: no T1 command known"; continue; fi
  log="$WORK/t1-$name.log"
  if inside "cd /workspace && $cmd" > "$log" 2>&1; then ok "T1 $name ($cmd)"
  else tail -25 "$log" | sed 's/^/      /'; fail "T1 $name ($cmd)"; fi
done

echo "== $PRESET: $([ $fails = 0 ] && echo PASS || echo "$fails FAILED")"
[ $fails = 0 ]
