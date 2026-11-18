#!/usr/bin/env bash
# T5 for the base image: every tool the agents rely on answers, as the dev
# user, with the expected versions and paths. Run inside the image:
#   docker run --rm -v <repo>/tests:/tests:ro <image> bash /test/base/test.sh
set -u
fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    printf 'ok    %-22s %s\n' "$label" "$(printf '%s' "$out" | head -n 1)"
  else
    printf 'FAIL  %-22s %s\n' "$label" "$(printf '%s' "$out" | head -n 1)"
    fail=1
  fi
}
check user          bash -c '[ "$(id -un)" = dev ] && id'
check node          node --version
check npm           npm --version
check npm-prefix    bash -c '[ "$(npm config get prefix)" = /usr/local/share/npm-global ] && npm config get prefix'
check python3       python3 --version
check python-stdlib python3 -c 'import json, sqlite3, ssl, venv; print("stdlib ok")'
check gh            gh --version
check git           git --version
check zsh           zsh --version
check jq            jq --version
check rg            rg --version
check socat         socat -V
check host-open     bash -c 'command -v host-open'
check plannotator   bash -c 'grep -q plannotator-wrapper:per-worktree-port "$HOME/.local/bin/plannotator" && echo wrapper over "$(ls "$HOME/.local/bin/plannotator.real")"'
check claude-share  bash -c '[ "$(readlink "$HOME/.local/share/claude")" = /claude-code ] && echo "~/.local/share/claude -> /claude-code"'
check config-dir    bash -c '[ "$CLAUDE_CONFIG_DIR" = /claude-config ] && [ -w /claude-config ] && echo /claude-config'
check volumes-owned bash -c 'for d in /workspace /claude-code /commandhistory /playwright-browsers; do [ -w "$d" ] || { echo "$d not writable"; exit 1; }; done; echo writable'
check chromium-libs bash -c 'for l in libnss3.so libgbm.so.1 libatk-bridge-2.0.so.0 libxkbcommon.so.0; do ldconfig -p | grep -q "$l" || { echo "missing $l"; exit 1; }; done; echo present'
check sudo          sudo -n true
check one-node      bash -c '[ "$(type -a node | wc -l)" = 1 ] && type -a node'
check provides      python3 - <<'PY'
import json, re, subprocess
want = json.load(open("/usr/local/share/sdd-workbench/provides.json"))
have = {
    "node": subprocess.run(["node", "--version"], capture_output=True, text=True).stdout.strip().lstrip("v"),
    "python": "%d.%d" % __import__("sys").version_info[:2],
    "gh": re.search(r"(\d+\.\d+\.\d+)", subprocess.run(["gh", "--version"], capture_output=True, text=True).stdout).group(1),
}
for tool, version in want.items():
    parts = version.split(".")
    if have[tool].split(".")[:len(parts)] != parts:
        raise SystemExit(f"provides.json says {tool} {version}, the image has {have[tool]}")
print("provides.json matches: " + ", ".join(f"{t} {have[t]}" for t in want))
PY
exit $fail
