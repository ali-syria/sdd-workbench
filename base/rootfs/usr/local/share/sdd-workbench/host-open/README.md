# host-open: let Plannotator open the Mac browser from the dev container

Plannotator runs inside the dev container, but your browser runs on the Mac. In a VS Code dev container
Plannotator opens the review page on the Mac by itself. From a plain terminal (Ghostty, iTerm) attached with
`docker exec` or `.devcontainer/scripts/up.sh`, it only prints the URL — and for a plan review, which runs as a
hook, you never even see that URL.

**host-open** is a small bridge that lets the container open a page in the Mac's default browser from any
terminal. VS Code sessions keep working as before.

## How it works

The container sets `PLANNOTATOR_REMOTE=1`, so Plannotator does not try an in-container `xdg-open`; in that mode
it reaches a host browser only through VS Code. The `plannotator` wrapper
(`.devcontainer/scripts/plannotator-wrapper.sh`) therefore also sets
`PLANNOTATOR_BROWSER=/home/dev/.local/bin/host-open` — unless a browser was chosen already, and only once
`host-open` is installed — and Plannotator runs that program for every URL. It tries three routes, and the
first that succeeds wins:

1. **VS Code's `$BROWSER` helper**, when one is set — so VS Code sessions keep their old route.
2. **The Mac agent**, for `localhost` pages in the allowed port range: `GET http://host.docker.internal:19876/open`
   with the URL in an `X-Open-Url` header. On the Mac, a launchd agent listening on `127.0.0.1:19876` runs
   `open <url>`.
3. **The Plannotator VS Code extension's IPC** (`~/.plannotator/vscode-ipc.json`), as Plannotator itself would.

| File | Runs on | Role |
|---|---|---|
| `host-open` | container | The browser Plannotator calls. Copied to `~/.local/bin/host-open` by `scripts/install-plannotator-wrapper.sh`. |
| `macos/host-opener.sh` | Mac, started by launchd once per connection | Reads the request, applies the policy below, opens the URL. |
| `macos/install.sh` | Mac, run once by hand | Installs, updates or removes the launchd agent `local.host-open`. Shows you what it will run first. |
| `macos/test-host-opener.sh` | Mac | Tests of the agent's policy, with `open` stubbed. |
| `test-host-open.sh` | anywhere with bash and zsh | Tests of the container-side client against the real agent script, with `curl` and `open` stubbed. |

## Requirements

- **A Mac running Docker Desktop.** It routes `host.docker.internal` to the Mac's loopback, so the agent listens
  on `127.0.0.1` only.
- **`bash`, `curl` and `jq` in the container** (the image has them). `/bin/zsh`, `launchctl`, `plutil`, `lsof`,
  `shasum` and `curl` on the Mac ship with macOS.
- **A Plannotator port the Mac can reach.** The page itself must load at `http://localhost:<port>`: the
  container publishes `DEVCONTAINER_PORT_RANGE` (`20000-20099` by default, on the host's loopback) and the
  plannotator wrapper picks from it. Port 19876 needs no publishing, but keep it outside that range.

## Setup

1. **In the container**, nothing: `host-open` is installed by the same script that installs the plannotator
   wrapper (the dev container's create step, or `BOOTSTRAP=1 .devcontainer/scripts/up.sh` to run it again).
   Start a new Claude session after (re)creating the container.
2. **On the Mac**, once, in a terminal that is **not** the container's, from this project's checkout:

   ```bash
   bash .devcontainer/host-open/macos/install.sh
   ```

   Read what it shows first (see *Trust* below). It ends with a self-test that opens nothing and should print
   `host-open: agent local.host-open is listening on 127.0.0.1:19876 (log: …/host-open.log).`
3. **Verify, in the container:**

   ```bash
   # The agent is reachable: a request that is not a proper one is refused with 400.
   curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://host.docker.internal:19876/open   # → 400

   # A page opens on the Mac: exit code 0 and a new browser tab.
   host-open http://localhost:20001/ ; echo "exit $?"
   ```

   Then run `/plannotator-annotate <some file>`: the review page should open on the Mac by itself.

One agent serves every project's dev container, so a Mac needs step 2 once, not once per project. If you
already have one installed from an earlier version — the BLU setup's `com.blu.host-open`, say — **replace it,
do not keep it**: an older agent lacks this version's checks (localhost pages only, a port range, the Host and
browser-header checks), and the container can talk to it directly whatever `host-open` filters. Run
`launchctl bootout gui/$(id -u)/<its label>`, delete its plist in `~/Library/LaunchAgents`, and install this one
(`install.sh` refuses to start while the port is held, and says so). `host-open` warns when the agent that
opened a page does not report this version's policy.

## Trust: what you are installing

The agent runs as you, on every connection, from login onwards — and its source comes from a tree the dev
container can **write**. A container (or an agent inside it) that edits `macos/host-opener.sh` would be running
code on your Mac the next time you install. So `install.sh` never installs blind. It copies `host-opener.sh`
once to a private temp directory, and from **that copy** prints the path and sha256, shows a `diff -u` against
the installed copy when there is one (control characters shown as `^X`, so nothing can hide a line), shows what
git says about the files (uncommitted changes, or the last commit), and asks `Install it? [y/N]`. The same copy
is what gets installed, so it cannot change between your look and the install. Without a terminal it refuses
unless you pass `--yes`. An unchanged re-run asks nothing. If you decline, or the port turns out to be held, the
agent you already had is started again.

**What the prompt does not cover.** It vouches for `host-opener.sh`, not for `install.sh` itself, nor for
anything else in the tree. A container that rewrites `install.sh` can skip the prompt, and the whole checkout is
mounted read-write into the container, which already makes the same thing possible without this bridge: edit
`.git/hooks/*` or `.git/config` (run by your next host-side git command), `docker-compose.yml`, `up.sh` or
`devcontainer.json` (run by your next `up`/rebuild). host-open adds a *persistent* form of that exposure, not a
new kind. So before running `install.sh`, `up.sh`, or a rebuild after a container has been working on the tree,
**read `git diff -- .devcontainer/` and `git status`**. The one hardening that costs nothing in normal use is a
read-only overlay of just this folder's `macos/` directory in `docker-compose.yml`
(`../.devcontainer/host-open/macos:/workspace/.devcontainer/host-open/macos:ro`); it is not applied by default
because a `git checkout` that touches those files inside the container would then fail.

## Safety: what the agent will and will not do

The policy is enforced **on the Mac** (the container is the less trusted side) and mirrored in `host-open`:

- **Only `http(s)://localhost` and `http(s)://127.0.0.1`, with an explicit port inside `HOST_OPEN_PORTS`**
  (default `20000-29999`, where the dev containers publish theirs; never the agent's own port), an optional
  path, no whitespace or control characters, at most 4096 characters. That is all Plannotator asks for. A
  phishing page, another local service (a database port, an admin page on `localhost:80`), an app, a file or a
  custom URL scheme cannot be opened through it.
- **A web page cannot trigger it.** The request must carry exactly one `Host: host.docker.internal:<port>` (or
  `127.0.0.1`/`localhost` with that port), at most one `X-Open-Url`, well-formed header names, and **no**
  `Origin`, `Referer` or `Sec-Fetch-*` header. A browser always sends `Origin` or `Sec-Fetch-*`, and a
  DNS-rebinding page arrives with its own `Host`. (The custom header alone would not be enough: after rebinding
  the request is same-origin and needs no preflight.)
- **At most one page every `HOST_OPEN_MIN_INTERVAL` seconds** (default 2; answered `429` otherwise), so a loop
  cannot open tabs by the hundred.
- **The agent listens on `127.0.0.1` only**, launchd runs a **copy** of `host-opener.sh` from
  `~/Library/Application Support/host-open/<label>/` (which the container cannot reach), and the plist caps its
  CPU time and memory.
- **The whole request has a 10 s deadline**, so a client that dribbles bytes cannot hold a process open.
- **The log** (`~/Library/Logs/host-open.log`) keeps no query, no fragment (Plannotator share links carry a
  decryption key there) and no control characters. Past 1 MB it is moved to `host-open.log.1`, one generation, so
  a flood of refusals cannot erase the history.
- **Every answer carries `X-Host-Open-Policy: 3`**, which `host-open` checks, so an older, weaker agent is noticed.

What it does **not** protect against: the agent has no authentication, so **any container on this Mac, and any
local process, can ask it** to open a `localhost` page in the allowed range. A container can run a server on a
port the dev container publishes, so a compromised container can get your browser to open a page *it* serves.
Cookies are not isolated by port, so that page shares them with your other `localhost` apps: it can read the
ones that are not `HttpOnly`, set or fixate cookies, and send credentialed `SameSite=Lax` requests to them. That
is a prompt-injected agent steering your browser at its own page, not code execution on the Mac, but it is
real: treat what runs in the container accordingly, and do not keep sessions for sensitive `localhost` apps in
the browser you open it with. Narrowing `HOST_OPEN_PORTS` (for example to this project's `DEVCONTAINER_PORT_RANGE`)
narrows it further.

## Settings

| Variable | Default | Used by |
|---|---|---|
| `HOST_OPEN_PORT` | `19876` | Both ends. Set it for `install.sh` (it goes into the agent's plist) and in `.devcontainer/.env` (compose passes it on). Keep it outside the published port range, or Docker already holds it on the Mac. |
| `HOST_OPEN_PORTS` | `20000-29999` | `install.sh` (written into the agent's plist) and `host-open`: the localhost ports a page may be on. Set the same value for both. |
| `HOST_OPEN_HOST` | `host.docker.internal` | `host-open`: where it sends the request. The `Host` header it sends stays `host.docker.internal:<port>`. |
| `HOST_OPEN_LABEL` | `local.host-open` | `install.sh`: the launchd agent's name (starts with a letter or digit; letters, digits, `.`, `_`, `-`). Everything it installs lives under that label. |
| `HOST_OPEN_MIN_INTERVAL` | `2` | The agent: seconds between pages. Set in the plist (edit it and re-run `install.sh`), not in the container. |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `curl … :19876/open` prints `000` | The agent is not installed, or listens on another port. On the Mac, run `launchctl print gui/$(id -u)/local.host-open` and re-run `install.sh`. |
| `host-open` exits 1 with *bridge … answered 000* | Same as above. The message names the host and port it tried. |
| `host-open` exits 1 with *the Mac bridge only opens localhost pages on a port in …* | The URL was not `http(s)://localhost` or `127.0.0.1` with a port in `HOST_OPEN_PORTS`. By design: open it by hand, or widen `HOST_OPEN_PORTS` (both ends). |
| `host-open` exits 1 with *the Mac bridge allows one page every few seconds* | Two pages were asked for within `HOST_OPEN_MIN_INTERVAL`. Try again. |
| `host-open` opens the page but warns about an *older agent* | The agent on the Mac does not report this version's policy. Replace it (see *Setup*). |
| `install.sh` says the port is already in use | Another agent holds it, often one installed earlier under another label (`com.blu.host-open`). Replace it (see *Setup*), or choose another port: `HOST_OPEN_PORT=19877 bash …/install.sh`, and set the same value in `.devcontainer/.env`. |
| A tab opens, but the page does not load | The Plannotator port is not published to the Mac: see *Requirements*, and check that the port the wrapper picked is inside `DEVCONTAINER_PORT_RANGE`. |
| Nothing happens and there is no error | The Claude session started before the container had `host-open`, or the container predates the wrapper change. Recreate the container (or `BOOTSTRAP=1 .devcontainer/scripts/up.sh`), start a new session, and check `echo $PLANNOTATOR_BROWSER` in a Bash call. |
| Something else | The Mac log is `~/Library/Logs/host-open.log`: one line per URL opened or refused. |

## Uninstall

```bash
bash .devcontainer/host-open/macos/install.sh --uninstall   # on the Mac
```

It removes only this label's agent and files. Then delete this folder and the `host-open` lines in
`scripts/install-plannotator-wrapper.sh` and `scripts/plannotator-wrapper.sh`.

## Tests

```bash
bash .devcontainer/host-open/macos/test-host-opener.sh   # the agent's policy (zsh; nothing is opened)
bash .devcontainer/host-open/test-host-open.sh           # the container-side client against the real agent script
```

Run both after changing either side.
