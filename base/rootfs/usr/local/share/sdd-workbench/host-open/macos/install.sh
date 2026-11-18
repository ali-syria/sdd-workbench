#!/bin/bash
#
# install.sh — install (or remove) the Mac side of host-open: a launchd agent listening on
# 127.0.0.1:$HOST_OPEN_PORT (default 19876) that opens the localhost pages the devcontainer asks for.
#
# Run it ON THE MAC, not in the container, from the project's checkout on the Mac:
#
#   bash .devcontainer/host-open/macos/install.sh              # install or update
#   bash .devcontainer/host-open/macos/install.sh --uninstall  # remove
#   bash .devcontainer/host-open/macos/install.sh --yes        # install without the confirmation
#
# One agent serves every project's dev container (the script is the same in all of them), so a Mac
# needs this once, not once per project. HOST_OPEN_LABEL and HOST_OPEN_PORT name a second one;
# HOST_OPEN_PORTS (default 20000-29999) is the range of localhost ports it is willing to open.
#
# Trust: this file and host-opener.sh come from a tree the dev container can WRITE, and the agent
# runs as you, from login, for good. So nothing is installed before you have seen what will run:
# the file is copied once to a private temp directory, and its sha256 (plus a diff against the
# installed copy, and the git state of the checkout) is shown and confirmed FROM THAT COPY, which is
# also what gets installed, so it cannot change between your look and the install. What this cannot
# vouch for is this script itself, or anything else in the tree: read `git diff -- .devcontainer/`
# first (README.md, "Trust").
#
# The agent runs a copy of host-opener.sh from ~/Library/Application Support/host-open/<label>/,
# which the container cannot reach. Run this again after host-opener.sh changes. Everything it
# installs is under <label>, so removing one agent never touches another's files.

main() {
    set -euo pipefail

    [[ $(uname -s) == Darwin ]] || {
        echo "install.sh: run this on the Mac, not in the devcontainer." >&2
        exit 1
    }

    # mode, domain, plist, was_loaded, replaced and tmp are global on purpose: the EXIT trap
    # (cleanup) reads them after main has returned, when locals are gone.
    mode=install
    local assume_yes=0 arg
    for arg in "$@"; do
        case $arg in
            --uninstall) mode=uninstall ;;
            --yes | -y) assume_yes=1 ;;
            *)
                echo "install.sh: unknown argument '$arg' (use --uninstall or --yes)." >&2
                exit 2
                ;;
        esac
    done

    local label=${HOST_OPEN_LABEL:-local.host-open}
    local port=${HOST_OPEN_PORT:-19876}
    local ports=${HOST_OPEN_PORTS:-20000-29999}
    [[ $label =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $label != *..* ]] || {
        echo "install.sh: HOST_OPEN_LABEL must start with a letter or digit and hold only letters, digits, '.', '_' and '-', got '$label'." >&2
        exit 1
    }
    [[ $port =~ ^[0-9]{1,5}$ ]] || {
        echo "install.sh: HOST_OPEN_PORT must be a number, got '$port'." >&2
        exit 1
    }
    [[ $ports =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] && ((10#${BASH_REMATCH[1]} >= 1024 && 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]} && 10#${BASH_REMATCH[2]} <= 65535)) || {
        echo "install.sh: HOST_OPEN_PORTS must be <first>-<last> within 1024-65535, got '$ports'." >&2
        exit 1
    }

    domain="gui/$(id -u)"
    local src_dir
    src_dir=$(cd "$(dirname "$0")" && pwd)
    local dest_dir="$HOME/Library/Application Support/host-open/$label"
    plist="$HOME/Library/LaunchAgents/$label.plist"
    local log="$HOME/Library/Logs/host-open.log"

    xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

    # If we stop the running agent to look at the port and then decline, or find the port held, put
    # it back: a refusal must not leave your working agent stopped until next login.
    was_loaded=0
    replaced=0
    tmp=''
    launchctl print "$domain/$label" >/dev/null 2>&1 && was_loaded=1
    cleanup() {
        [[ -n $tmp ]] && rm -rf "$tmp"
        if [[ $mode == install && $was_loaded == 1 && $replaced == 0 && -f $plist ]]; then
            launchctl bootstrap "$domain" "$plist" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT

    launchctl bootout "$domain/$label" 2>/dev/null || true

    if [[ $mode == uninstall ]]; then
        rm -f "$plist"
        rm -rf "$dest_dir"
        echo "host-open: removed the $label agent."
        exit 0
    fi

    # Our own agent is out of the way now, so anything still listening is someone else's. launchd
    # holds an inetd agent's socket itself, so a second agent for the same port either fails to
    # load or loads and never receives a connection while the self-test below is answered by the
    # first.
    local holder
    if holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null) && [[ -n $holder ]]; then
        {
            echo "install.sh: 127.0.0.1:$port is already in use:"
            echo "$holder" | sed 's/^/    /'
            echo "  Often an agent installed earlier under another label (e.g. com.blu.host-open). An older"
            echo "  agent lacks this version's checks (localhost pages only, a port range, the Host and"
            echo "  browser-header checks), so REPLACE it rather than keep it:"
            echo "      launchctl bootout $domain/<its label>   and delete its plist in ~/Library/LaunchAgents,"
            echo "  then run this again. Or pick another port, here and in .devcontainer/.env:"
            echo "      HOST_OPEN_PORT=19877 bash $0"
        } >&2
        exit 1
    fi

    # Look at ONE copy, and install that copy. Reading the repository file again after the prompt
    # would let a process in the container swap it in between.
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/host-open-install.XXXXXX")
    install -m 0600 "$src_dir/host-opener.sh" "$tmp/host-opener.sh"
    local new_sha
    new_sha=$(shasum -a 256 "$tmp/host-opener.sh" | cut -d' ' -f1)

    local needs_confirm=1
    if [[ -f $dest_dir/host-opener.sh ]]; then
        if cmp -s "$tmp/host-opener.sh" "$dest_dir/host-opener.sh"; then
            needs_confirm=0
        else
            echo "host-open: host-opener.sh differs from the installed copy (control characters shown as ^X):"
            diff -u "$dest_dir/host-opener.sh" "$tmp/host-opener.sh" | cat -v | sed 's/^/    /' || true
        fi
    fi

    if ((needs_confirm)); then
        echo "host-open: launchd will run this file as you, on every connection to 127.0.0.1:$port:"
        echo "    $src_dir/host-opener.sh"
        echo "    sha256 $new_sha"
        # A reference from outside the files the container can rewrite: what git says about them.
        if git -C "$src_dir" rev-parse --git-dir >/dev/null 2>&1; then
            local dirty
            dirty=$(git -C "$src_dir" status --porcelain -- . 2>/dev/null || true)
            if [[ -n $dirty ]]; then
                echo "  WARNING: these files have uncommitted changes in git:"
                echo "$dirty" | cat -v | sed 's/^/      /'
            else
                echo "  git: no uncommitted changes here. Last commit touching it:"
                git -C "$src_dir" log -1 --format='      %h %s (%an, %ad)' --date=short -- . 2>/dev/null || true
            fi
        fi
        echo "  It came from a tree the dev container can write to. Have you read it?"
        if ((!assume_yes)); then
            [[ -t 0 ]] || {
                echo "install.sh: not a terminal, so there is nobody to ask; review the file and pass --yes." >&2
                exit 1
            }
            local reply
            read -r -p "  Install it? [y/N] " reply
            [[ $reply == [yY] || $reply == [yY][eE][sS] ]] || {
                echo "host-open: not installed."
                exit 1
            }
        fi
    fi

    mkdir -p "$dest_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    replaced=1
    install -m 0755 "$tmp/host-opener.sh" "$dest_dir/host-opener.sh"

    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-f</string>
        <string>$(printf '%s' "$dest_dir/host-opener.sh" | xml)</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOST_OPEN_PORT</key>
        <string>$port</string>
        <key>HOST_OPEN_PORTS</key>
        <string>$ports</string>
    </dict>
    <key>SoftResourceLimits</key>
    <dict>
        <key>CPU</key>
        <integer>10</integer>
        <key>Data</key>
        <integer>134217728</integer>
    </dict>
    <key>inetdCompatibility</key>
    <dict>
        <key>Wait</key>
        <false/>
    </dict>
    <key>Sockets</key>
    <dict>
        <key>Listener</key>
        <dict>
            <key>SockNodeName</key>
            <string>127.0.0.1</string>
            <key>SockServiceName</key>
            <string>$port</string>
            <key>SockType</key>
            <string>stream</string>
            <key>SockFamily</key>
            <string>IPv4</string>
        </dict>
    </dict>
    <key>StandardErrorPath</key>
    <string>$(printf '%s' "$log" | xml)</string>
</dict>
</plist>
EOF
    plutil -lint -s "$plist"

    launchctl bootstrap "$domain" "$plist"

    # Self-test without opening anything: a request with no URL must be refused with 400.
    sleep 0.5
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/open" || true)
    if [[ $status == 400 ]]; then
        echo "host-open: agent $label is listening on 127.0.0.1:$port, opening localhost ports $ports (log: $log)."
    else
        echo "host-open: agent loaded, but the self-test got HTTP '$status' instead of 400." >&2
        echo "  Check: launchctl print $domain/$label" >&2
        exit 1
    fi
}

# The whole script is read before it runs: bash otherwise reads a script as it goes, so a rewrite of
# this file while it waits at the prompt would take effect.
main "$@"
exit
