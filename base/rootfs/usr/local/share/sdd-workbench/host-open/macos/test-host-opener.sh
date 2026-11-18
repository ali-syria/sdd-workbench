#!/bin/bash
#
# test-host-opener.sh — tests for host-opener.sh, the Mac-side policy of host-open.
#
#   bash .devcontainer/host-open/macos/test-host-opener.sh        # on the Mac
#
# Runs a COPY of host-opener.sh with `/usr/bin/open` swapped for a stub that only records its
# arguments, in a scratch HOME, so nothing is opened, installed or logged for real. It needs zsh
# (the agent's interpreter) and nothing else.

set -uo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)/host-opener.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/host-opener-test.XXXXXX")
mkdir -p "$WORK/home/Library/Logs"
STUB="$WORK/open-stub"
OPENED="$WORK/opened"
cat >"$STUB" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$OPENED"
EOF
chmod +x "$STUB"
sed "s|/usr/bin/open|$STUB|" "$SRC" >"$WORK/host-opener.sh"
grep -q "$STUB" "$WORK/host-opener.sh" || { echo "could not stub /usr/bin/open in the copy"; exit 2; }

LOG="$WORK/home/Library/Logs/host-open.log"
PORT=19876
pass=0
fail=0

# send <request-line> <header>...   -> prints the status line the agent answers with
send() {
    local reqline=$1
    shift
    {
        printf '%s\r\n' "$reqline"
        local h
        for h in "$@"; do printf '%s\r\n' "$h"; done
        printf '\r\n'
    } | HOME="$WORK/home" HOST_OPEN_PORT=$PORT HOST_OPEN_MIN_INTERVAL=${INTERVAL:-0} zsh -f "$WORK/host-opener.sh" | head -1 | tr -d '\r'
}

# the whole answer (status line and headers), for the checks on what the agent says back
send_full() {
    {
        printf '%s\r\n' "$1"
        printf '%s\r\n' "$2" 'X-Open-Url: http://localhost:20001/' ''
    } | HOME="$WORK/home" HOST_OPEN_PORT=$PORT HOST_OPEN_MIN_INTERVAL=0 zsh -f "$WORK/host-opener.sh" | tr -d '\r'
}

# expect <label> <status> <request-line> <header>...
expect() {
    local label=$1 want=$2 got
    shift 2
    got=$(send "$@")
    if [[ $got == "HTTP/1.1 $want"* ]]; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n        wanted %s, got: %s\n' "$label" "$want" "$got"
    fi
}

GOOD_HOST="Host: host.docker.internal:$PORT"
GET='GET /open HTTP/1.1'

echo "== what it opens"
: >"$OPENED"
expect "plannotator-style localhost URL" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
expect "127.0.0.1, https, path" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: https://127.0.0.1:20002/a/b'
expect "header name is case-insensitive" '204' "$GET" "$GOOD_HOST" 'x-OPEN-url: http://localhost:20003/'
expect "Host 127.0.0.1" '204' "$GET" "Host: 127.0.0.1:$PORT" 'X-Open-Url: http://localhost:20004/'
expect "Host localhost" '204' "$GET" "Host: localhost:$PORT" 'X-Open-Url: http://localhost:20005/'
expect "first port of the default range" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20000/'
expect "last port of the default range" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:29999/x'
opened_ok=$(wc -l <"$OPENED" | tr -d ' ')
[[ $opened_ok == 7 ]] && { pass=$((pass + 1)); echo "  ok    open ran once per accepted request (7)"; } ||
    { fail=$((fail + 1)); echo "  FAIL  open ran $opened_ok times, wanted 7"; }

echo "== what it refuses (URL)"
: >"$OPENED"
for u in \
    'https://example.com/' \
    'http://example.com:20001/' \
    'http://localhost@evil.example/' \
    'http://localhost:20001@evil.example/' \
    'http://127.0.0.1.evil.example/' \
    'http://localhost.evil.example/' \
    'http://evil.example/localhost' \
    'ftp://localhost/' \
    'file:///Applications/Calculator.app' \
    'javascript:alert(1)' \
    'HTTP://LOCALHOST:20001/' \
    '-a Calculator' \
    'http://localhost:20001/a b' \
    $'http://localhost:20001/a\tb' \
    $'http://localhost:20001/a\x1b[2Jb' \
    'http://localhost:123456/' \
    'http://localhost/' \
    'http://localhost:19876/open' \
    'http://localhost:3306/' \
    'http://localhost:80/admin?do=delete' \
    'http://localhost:99999/' \
    'http://localhost:19999/' \
    'http://localhost:30000/' \
    'http://localhost:0/' \
    ''; do
    expect "refuses: $(printf '%q' "$u" | cut -c1-60)" '400' "$GET" "$GOOD_HOST" "X-Open-Url: $u"
done
long="http://localhost:20001/$(printf 'a%.0s' $(seq 1 4100))"
expect "refuses a URL over 4096 characters" '400' "$GET" "$GOOD_HOST" "X-Open-Url: $long"

echo "== what it refuses (the request)"
expect "no URL header" '400' "$GET" "$GOOD_HOST"
expect "a rebound Host (DNS rebinding)" '400' "$GET" "Host: attacker.example:$PORT" 'X-Open-Url: http://localhost:20001/'
expect "a Host with another port" '400' "$GET" 'Host: host.docker.internal:8080' 'X-Open-Url: http://localhost:20001/'
expect "no Host at all" '400' "$GET" 'X-Open-Url: http://localhost:20001/'
expect "an Origin header (a browser)" '400' "$GET" "$GOOD_HOST" 'Origin: http://attacker.example' 'X-Open-Url: http://localhost:20001/'
expect "a Referer header (a browser)" '400' "$GET" "$GOOD_HOST" 'Referer: http://attacker.example/' 'X-Open-Url: http://localhost:20001/'
expect "a Sec-Fetch-Site header (a browser)" '400' "$GET" "$GOOD_HOST" 'Sec-Fetch-Site: same-origin' 'X-Open-Url: http://localhost:20001/'
expect "a CORS preflight" '400' 'OPTIONS /open HTTP/1.1' "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
expect "POST" '400' 'POST /open HTTP/1.1' "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
expect "another path" '400' 'GET /other HTTP/1.1' "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
expect "two Host headers" '400' "$GET" 'Host: evil.example:19876' "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
expect "two X-Open-Url headers" '400' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/' 'X-Open-Url: http://localhost:20002/'
expect "a header name with a space (Origin : x)" '400' "$GET" "$GOOD_HOST" 'Origin : http://attacker.example' 'X-Open-Url: http://localhost:20001/'
expect "a header line with no colon" '400' "$GET" "$GOOD_HOST" 'not-a-header' 'X-Open-Url: http://localhost:20001/'
many=()
for i in $(seq 1 60); do many+=("X-Pad-$i: x"); done
expect "more than 50 headers" '400' "$GET" "$GOOD_HOST" "${many[@]}" 'X-Open-Url: http://localhost:20001/'
refused_opened=$(wc -l <"$OPENED" | tr -d ' ')
[[ $refused_opened == 0 ]] && { pass=$((pass + 1)); echo "  ok    open never ran for a refused request"; } ||
    { fail=$((fail + 1)); echo "  FAIL  open ran $refused_opened times for refused requests"; }

echo "== it says which policy it enforces"
for r in "$GET" 'POST /open HTTP/1.1'; do
    full=$(send_full "$r" "$GOOD_HOST")
    first=$(printf '%s' "$full" | head -1)
    printf '%s' "$full" | grep -q '^X-Host-Open-Policy: 3$' && { pass=$((pass + 1)); echo "  ok    X-Host-Open-Policy on: $first"; } ||
        { fail=$((fail + 1)); echo "  FAIL  no X-Host-Open-Policy on: $first"; }
done

echo "== at most one page per interval"
rm -f "$WORK/home/Library/Logs/host-open.last"
INTERVAL=2 expect "the first goes through" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
INTERVAL=2 expect "the next, straight after, is 429" '429' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
sleep 3
INTERVAL=2 expect "after the interval it goes through again" '204' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
: >"$OPENED"

echo "== a failing open is a 500"
printf '#!/bin/sh\nexit 1\n' >"$STUB"
expect "open exits non-zero" '500' "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/'
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$OPENED" >"$STUB"

echo "== the log"
: >"$LOG"
send "$GET" "$GOOD_HOST" 'X-Open-Url: http://localhost:20001/a?token=SECRETQUERY#frag=SECRETKEY' >/dev/null
send "$GET" "$GOOD_HOST" $'X-Open-Url: http://localhost:20001/\x1b]0;pwned\x07' >/dev/null
send $'GET /open\x1b[2J HTTP/1.1' "$GOOD_HOST" >/dev/null
if grep -q 'SECRETQUERY\|SECRETKEY' "$LOG"; then
    fail=$((fail + 1)); echo "  FAIL  the log holds a query or fragment"
else pass=$((pass + 1)); echo "  ok    no query or fragment in the log"; fi
if LC_ALL=C grep -q "$(printf '\033')" "$LOG"; then
    fail=$((fail + 1)); echo "  FAIL  the log holds a raw escape character"
else pass=$((pass + 1)); echo "  ok    no control characters in the log"; fi
grep -q 'opened http://localhost:20001/a$' "$LOG" && { pass=$((pass + 1)); echo "  ok    an opened URL is logged without query and fragment"; } ||
    { fail=$((fail + 1)); echo "  FAIL  opened URL not logged as expected:"; cat "$LOG"; }

echo "== the deadline"
FIFO="$WORK/fifo"
mkfifo "$FIFO"
(
    # One byte a second and never a newline: every read stays inside its own 5 s timeout, so only
    # the whole-request deadline can end this.
    for _ in $(seq 1 40); do printf 'a'; sleep 1; done
) >"$FIFO" &
FEEDER=$!
HOME="$WORK/home" HOST_OPEN_PORT=$PORT zsh -f "$WORK/host-opener.sh" <"$FIFO" >/dev/null 2>&1 &
AGENT=$!
# The watchdog is what ends it: the process must be gone well inside 15 s.
for _ in $(seq 1 15); do
    kill -0 "$AGENT" 2>/dev/null || break
    sleep 1
done
if kill -0 "$AGENT" 2>/dev/null; then
    fail=$((fail + 1)); echo "  FAIL  the agent was still running after 15 s"
    kill -KILL "$AGENT" 2>/dev/null
else pass=$((pass + 1)); echo "  ok    a client dribbling a byte a second is cut off within 15 s"; fi
kill "$FEEDER" 2>/dev/null
wait 2>/dev/null

echo
echo "passed $pass, failed $fail   (scratch: $WORK)"
[[ $fail -eq 0 ]]
