#!/bin/bash
#
# test-host-open.sh — tests for host-open, the container-side client, against the real
# macos/host-opener.sh.
#
#   bash .devcontainer/host-open/test-host-open.sh        # anywhere with bash and zsh
#
# `curl` is replaced by a stub that hands the request host-open builds to a COPY of host-opener.sh
# (with `/usr/bin/open` swapped for a recorder), and prints what the opener answers, as the real
# one would with `-D -`. So the Host header, the URL policy, the policy header and the exit codes are
# checked end to end, with no network, no launchd and nothing opened.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/host-open-test.XXXXXX")
mkdir -p "$WORK/bin" "$WORK/home/Library/Logs"
OPENED="$WORK/opened"

# The opener under test, with open stubbed.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$OPENED" >"$WORK/open-stub"
chmod +x "$WORK/open-stub"
sed "s|/usr/bin/open|$WORK/open-stub|" "$HERE/macos/host-opener.sh" >"$WORK/host-opener.sh"

# The curl stub: collect -H headers and the URL, send them to the opener, print its answer.
# $AGENT_VARIANT: current (default) | old (204 without the policy header) | none (unreachable).
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/bash
headers=(); url=''
while [ $# -gt 0 ]; do
  case $1 in
    -H) headers+=("$2"); shift 2 ;;
    -sS | -s | -S) shift ;;
    -o | -w | --max-time) shift 2 ;;
    -D) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ "${AGENT_VARIANT:-current}" = none ] && exit 7
path=/${url#*://*/}
req=$(printf 'GET %s HTTP/1.1\r\n' "$path")
for h in "${headers[@]}"; do req+=$(printf '\r\n%s' "$h"); done
req+=$(printf '\r\n\r\n')
out=$(printf '%s' "$req" | HOME="$WORK_HOME" HOST_OPEN_PORT="${HOST_OPEN_PORT:-19876}" HOST_OPEN_MIN_INTERVAL="${OPENER_INTERVAL:-0}" zsh -f "$WORK_OPENER")
[ "${AGENT_VARIANT:-current}" = old ] && out=$(printf '%s' "$out" | grep -v '^X-Host-Open-Policy')
printf '%s' "$out"
STUB
chmod +x "$WORK/bin/curl"

pass=0
fail=0
# run <label> <expected-exit> <stderr-must-contain|-> <url> [ENV=VAL...]
run() {
    local label=$1 want=$2 needle=$3 url=$4 code err
    shift 4
    err=$(env "$@" PATH="$WORK/bin:$PATH" WORK_HOME="$WORK/home" WORK_OPENER="$WORK/host-opener.sh" \
        BROWSER= HOME="$WORK/home" PLANNOTATOR_DATA_DIR="$WORK/none" "$HERE/host-open" "$url" 2>&1 >/dev/null)
    code=$?
    if [[ $code == "$want" ]] && { [[ $needle == - ]] || [[ $err == *"$needle"* ]]; }; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n        wanted exit %s%s, got exit %s: %s\n' "$label" "$want" "${needle:+ with “$needle”}" "$code" "$err"
    fi
}
opened() { wc -l <"$OPENED" 2>/dev/null | tr -d ' '; }
: >"$OPENED"

echo "== a page the agent opens"
run "localhost page in the range: exit 0, nothing to complain about" 0 - 'http://localhost:20001/plan'
[[ $(opened) == 1 ]] && { pass=$((pass + 1)); echo "  ok    and the opener really ran open once"; } || { fail=$((fail + 1)); echo "  FAIL  open ran $(opened) times"; }
run "the URL's fragment never appears in the output" 0 - 'http://localhost:20002/#key=SECRET'
err=$(env PATH="$WORK/bin:$PATH" WORK_HOME="$WORK/home" WORK_OPENER="$WORK/host-opener.sh" BROWSER= HOME="$WORK/home" PLANNOTATOR_DATA_DIR="$WORK/none" "$HERE/host-open" 'http://localhost:20003/#key=SECRET' 2>&1 >/dev/null)
[[ $err != *SECRET* ]] && { pass=$((pass + 1)); echo "  ok    nothing printed carries the fragment"; } || { fail=$((fail + 1)); echo "  FAIL  fragment leaked: $err"; }

echo "== a page it will not send"
: >"$OPENED"
run "no port" 1 'only opens localhost pages on a port in' 'http://localhost/'
run "a port outside the range" 1 'only opens localhost pages on a port in' 'http://localhost:3306/'
run "the bridge's own port" 1 'only opens localhost pages on a port in' 'http://localhost:19876/open' HOST_OPEN_PORTS=19000-29999
run "not localhost" 1 'only opens localhost pages' 'https://example.com/'
run "the range is configurable" 0 - 'http://localhost:30500/' HOST_OPEN_PORTS=30000-31000
run "not http(s) at all" 2 'only http(s) URLs' 'file:///etc/passwd'
run "whitespace in the URL" 2 'whitespace' 'http://localhost:20001/a b'
[[ $(opened) == 1 ]] && { pass=$((pass + 1)); echo "  ok    the refusals never reached open (only the one configurable-range page did)"; } ||
    { fail=$((fail + 1)); echo "  FAIL  open ran $(opened) times, wanted 1"; }

echo "== the agent"
run "unreachable agent: exit 1 and says how to install it" 1 'install the Mac bridge' 'http://localhost:20001/' AGENT_VARIANT=none
run "an older agent without the policy header: still opens, but warns to replace it" 0 'older agent' 'http://localhost:20001/' AGENT_VARIANT=old
run "rate limited: exit 1 and says so" 1 'one page every few seconds' 'http://localhost:20001/' OPENER_INTERVAL=60
run "...and again straight after: still limited" 1 'one page every few seconds' 'http://localhost:20001/' OPENER_INTERVAL=60

echo "== the Host header is the agent's own name, whatever address is dialled"
run "HOST_OPEN_HOST changes where it connects, not who it says it is" 0 - 'http://localhost:20001/' HOST_OPEN_HOST=192.0.2.9

echo
echo "passed $pass, failed $fail   (scratch: $WORK)"
[[ $fail -eq 0 ]]
