#!/usr/bin/env bash
# T5: build the base, then the base plus each add-on, run each one's checks
# inside it, and hold every image to its size budget (budgets.json).
#
#   test/run.sh [--platform linux/arm64|linux/amd64] [add-on ...]
#
# Default: the machine's own platform, every add-on. The add-ons are installed
# the way the dev-container CLI installs a feature: its folder copied in, its
# options as upper-case environment variables, install.sh run as root. CI runs
# the CLI's own `devcontainer features test` as well.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PLATFORM=""
if [ "${1:-}" = "--platform" ]; then PLATFORM="$2"; shift 2; fi
ADDONS=("$@")
[ ${#ADDONS[@]} -gt 0 ] || ADDONS=(php electron-display phone-tools browsers-extra)
TAG="${SDD_WORKBENCH_TEST_TAG:-sdd-workbench-test}"
PFLAG=(); [ -n "$PLATFORM" ] && PFLAG=(--platform "$PLATFORM")
fails=0

budget() { python3 -c "import json,sys; print(json.load(open('$ROOT/budgets.json'))[sys.argv[1]])" "$1"; }
size_mb() { docker image inspect -f '{{.Size}}' "$1" | awk '{printf "%d", $1/1048576}'; }
check_budget() { # check_budget <name> <image> [<base image>]
  local mb limit add
  mb="$(size_mb "$2")"
  if [ -n "${3:-}" ]; then add=$((mb - $(size_mb "$3"))); else add="$mb"; fi
  limit="$(budget "$1")"
  if [ "$add" -le "$limit" ]; then echo "ok    budget $1: ${add} MB (limit ${limit})"
  else echo "FAIL  budget $1: ${add} MB, over its limit of ${limit}"; fails=$((fails + 1)); fi
}

echo "== base ${PLATFORM:-native}"
if ! docker build ${PFLAG[@]+"${PFLAG[@]}"} -q -t "$TAG/base" "$ROOT/base" >/dev/null; then
  echo "FAIL  base did not build"; exit 1
fi
docker run --rm ${PFLAG[@]+"${PFLAG[@]}"} --entrypoint bash -v "$HERE:/tests:ro" "$TAG/base" /tests/base/test.sh \
  || fails=$((fails + 1))
check_budget base "$TAG/base"

for addon in "${ADDONS[@]}"; do
  echo "== $addon"
  dir="$ROOT/features/$addon"
  options="$(python3 - "$dir/devcontainer-feature.json" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
for name, opt in (spec.get("options") or {}).items():
    print(f"ENV {name.upper()}={opt.get('default', '')}")
PY
)"
  ctx="$(mktemp -d)"
  cp -R "$dir" "$ctx/feature"
  {
    echo "FROM $TAG/base"
    echo "USER root"
    printf '%s\n' "$options"
    echo "COPY feature /tmp/sdd-feature"
    echo "RUN cd /tmp/sdd-feature && bash install.sh && rm -rf /tmp/sdd-feature"
    echo "USER dev"
  } > "$ctx/Dockerfile"
  if ! docker build ${PFLAG[@]+"${PFLAG[@]}"} -q -t "$TAG/$addon" "$ctx" >/dev/null; then
    echo "FAIL  $addon did not install"; fails=$((fails + 1)); rm -rf "$ctx"; continue
  fi
  rm -rf "$ctx"
  docker run --rm ${PFLAG[@]+"${PFLAG[@]}"} --entrypoint bash -e SDD_WORKBENCH_SKIP_INIT=1 \
    -v "$HERE:/tests:ro" "$TAG/$addon" "/tests/$addon/test.sh" || fails=$((fails + 1))
  check_budget "$addon" "$TAG/$addon" "$TAG/base"
done
echo "T5: $fails failure(s)"
exit "$fails"
