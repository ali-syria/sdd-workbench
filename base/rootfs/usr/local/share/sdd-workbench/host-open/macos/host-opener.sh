#!/bin/zsh -f
#
# host-opener.sh — the Mac side of host-open. launchd runs one copy per connection
# (inetdCompatibility), with the socket on stdin and stdout.
#
# It reads one HTTP request, `GET /open` carrying the URL in an `X-Open-Url` header, and opens that
# URL in the default browser with `open`. Answers 204 when opened, 400 for anything it refuses, 429
# when asked again too soon, 500 when `open` failed. Every answer carries `X-Host-Open-Policy: 3`,
# so the container side can tell this agent from an older one that enforces less.
#
# What it will open — the policy lives HERE, on the trusted side, because the caller is a dev
# container (or anything else that can reach 127.0.0.1:$port) and so is the less trusted party:
#   * only http(s)://localhost or http(s)://127.0.0.1 WITH a port, and that port within
#     HOST_OPEN_PORTS (default 20000-29999, where the dev containers publish theirs; never the
#     agent's own). That is all Plannotator asks for. Nothing else can make the Mac's browser
#     navigate: not a phishing page, not another local service (a database port, an admin page), not
#     an app, a file or a custom URL scheme. Cookies are not isolated by port, so a page the
#     container serves inside the range still shares them with your other localhost apps: that is the
#     residual risk, see README.md.
#   * only a request whose Host is host.docker.internal, 127.0.0.1 or localhost on this port, sent
#     once, and with no Origin, Referer or Sec-Fetch-* header. A browser always sends Origin or
#     Sec-Fetch-*, and a DNS-rebinding page arrives with its own Host, so a web page cannot trigger
#     it. (The custom header alone is not enough: after rebinding the request is same-origin and
#     needs no preflight.)
# At most one page per HOST_OPEN_MIN_INTERVAL seconds (default 2), a 10 s deadline for the whole
# exchange, and a log that keeps no query, fragment or control character.
#
# Installed by install.sh, which COPIES this file out of the repository: the repository is mounted
# read-write into the devcontainer, so launchd must never run it in place. After changing this
# file, run install.sh again — it shows you what changed and asks first.
#
# Test: macos/test-host-opener.sh

PATH=/usr/bin:/bin
zmodload zsh/datetime
port=${HOST_OPEN_PORT:-19876}
ports=${HOST_OPEN_PORTS:-20000-29999}
interval=${HOST_OPEN_MIN_INTERVAL:-2}
log=$HOME/Library/Logs/host-open.log
stamp=$HOME/Library/Logs/host-open.last

# Deadline for the whole request. A per-read timeout (`read -t`) is not one: a client sending a
# byte a second, or one endless line, would otherwise hold this process (and its memory) forever.
# The watchdog is cut loose from the socket so it cannot keep the connection open after we answer,
# and it only fires at a process that is still this one: when we are killed by a signal the EXIT
# trap does not run, and the pid could in principle have been handed on.
me=$$
(sleep 10; [[ $(ps -p $me -o command= 2>/dev/null) == *host-opener* ]] && kill -KILL $me) </dev/null >/dev/null 2>&1 &!
watchdog=$!
trap 'exit 0' PIPE TERM HUP INT
trap 'kill $watchdog 2>/dev/null' EXIT

respond() {
    printf 'HTTP/1.1 %s\r\nX-Host-Open-Policy: 3\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$1"
    exit 0
}

# One log line, with anything a terminal could act on replaced. The file is kept small by moving it
# aside (one generation) rather than truncating it, so a flood of refusals cannot erase the history.
note() {
    local msg=${*//[[:cntrl:]]/?}
    if [[ -f $log ]] && (($(stat -f %z "$log" 2>/dev/null || echo 0) > 1048576)); then
        mv -f "$log" "$log.1" 2>/dev/null
    fi
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $msg" >>"$log" 2>/dev/null
}

# A URL for the log: no fragment (Plannotator share links carry a decryption key there) and no query.
loggable() {
    local u=${1%%\#*}
    print -r -- "${${u%%\?*}[1,200]}"
}

IFS= read -r -t 5 request || respond '400 Bad Request'
request=${request%$'\r'}

url=''
host=''
browser=''
odd=''
seen_url=0
seen_host=0
count=0
while IFS= read -r -t 5 line; do
    line=${line%$'\r'}
    [[ -z $line ]] && break
    ((++count > 50)) && respond '400 Bad Request'
    # A header is `name: value`; a name with a space or tab in it (`Origin : x`) is not one a
    # careful parser would recognise, so it is not one we guess at either.
    [[ $line == *:* ]] || { odd=1; continue; }
    name=${line%%:*}
    [[ $name == *[[:space:]]* ]] && odd=1
    name=${(L)name}
    value=${line#*:}
    while [[ $value == ' '* ]]; do value=${value# }; done
    case $name in
        x-open-url) ((seen_url++)); url=$value ;;
        host) ((seen_host++)); host=$value ;;
        origin | referer | sec-fetch-*) browser=1 ;;
    esac
done

[[ $request == 'GET /open '* ]] || { note "refused request: ${request[1,120]}"; respond '400 Bad Request'; }

if [[ -n $browser || -n $odd ]] || ((seen_host != 1 || seen_url > 1)) || [[ $host != (host.docker.internal|127.0.0.1|localhost):$port ]]; then
    note "refused: not a direct request (host '${host[1,80]}'${browser:+, browser headers}${odd:+, malformed header}, ${seen_host} Host, ${seen_url} URL headers)"
    respond '400 Bad Request'
fi

allowed='^https?://(localhost|127\.0\.0\.1):([0-9]{1,5})(/[^[:space:][:cntrl:]]*)?$'
lo=${ports%-*}
hi=${ports#*-}
if [[ ! $url =~ $allowed ]] || ((${#url} > 4096)) || ((10#$match[2] < 10#$lo || 10#$match[2] > 10#$hi || 10#$match[2] == 10#$port)); then
    note "refused url: $(loggable "$url")"
    respond '400 Bad Request'
fi

# One page per interval. Best effort (two connections at the same instant can both pass), but it
# stops a loop from opening tabs by the hundred.
now=$EPOCHSECONDS
last=0
[[ -r $stamp ]] && last=$(<"$stamp")
[[ $last == <-> ]] || last=0
if ((interval > 0 && now - last < interval)); then
    note "rate limited: $(loggable "$url")"
    respond '429 Too Many Requests'
fi
print -r -- "$now" >|"$stamp" 2>/dev/null

if /usr/bin/open "$url" >/dev/null 2>&1; then
    note "opened $(loggable "$url")"
    respond '204 No Content'
fi
note "open failed for $(loggable "$url")"
respond '500 Internal Server Error'
