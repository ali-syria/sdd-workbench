# sdd-workbench

The dev container the agents work in, for every project built with the
[Spec-Driven Development framework](https://github.com/ali-syria/sdd-framework),
whatever its stacks. A **base image** with what the agents need in every
project, and **add-ons** (dev-container features) for each toolchain, which
`python3 tools/sdd compose` layers on in whatever mix a project's codebases
ask for.

| Image | Holds | Used by |
|---|---|---|
| `ghcr.io/ali-syria/sdd-workbench/base:1` | Debian 12; a `dev` user with sudo; git, zsh, jq, ripgrep, fzf, socat; Python 3 (stdlib only, the framework's gates); `gh`; Node.js 26 (the active LTS, one copy, no nvm); Chromium's runtime libraries, with the browser on the `/playwright-browsers` volume; Claude Code's installer, with the CLI on its own `/claude-code` volume; `host-open` (opens the Mac's browser from the container); the Plannotator wrapper | every project |
| `ghcr.io/ali-syria/sdd-workbench/php:1` | PHP 8.5 CLI (Sury) with the Laravel scaffold's extensions, Composer, PCOV, Xdebug installed and off | `laravel` |
| `ghcr.io/ali-syria/sdd-workbench/electron-display:1` | Xvfb and the libraries Electron needs without a screen | `electron` |
| `ghcr.io/ali-syria/sdd-workbench/phone-tools:1` | Java 17, adb, Maestro, and `adb-bridge`, which reaches your Mac's own adb server (the emulator and every plugged-in Android phone) | `react-native` |
| `ghcr.io/ali-syria/sdd-workbench/browsers-extra:1` | Firefox's and WebKit's runtime libraries | a website tested in three browsers |

It holds tools only: never a secret, never a product's code.

## How a project gets it

Nobody writes a `devcontainer.json` by hand. Each codebase's scaffold names
the add-ons it needs in its manifest (`.sdd-scaffold.json`):

```json
"dev_environment": { "workbench": ["php"], "requires": {"node": ">=22.22"} }
```

and `python3 tools/sdd compose` writes `.devcontainer/devcontainer.json` and
`.devcontainer/compose.yaml`: the base image as the `workspace` service (its
volumes, the environment it passes through, the port range it publishes on
your Mac's loopback), each add-on as a feature, and each codebase's dev
services beside it. It checks every codebase's `requires` against what the
base provides (`base/provides.json`) and fails, naming both versions, when one
cannot be met. The dev-container CLI pins each image to a digest in
`.devcontainer/devcontainer-lock.json`, which the project commits.

## Claude Code is not in the image

The image carries Claude Code's installer. The CLI lives on the `claude-code`
volume, mounted at `/claude-code` (`~/.local/share/claude` links there):

- on a container's first start, `sdd-workbench-init` installs it (bounded by
  `SDD_CLAUDE_INSTALL_TIMEOUT`, 900 s by default);
- it updates itself in the background, as it always has, onto the volume;
- on every start, `claude-code-ensure` points `claude` at the newest version
  the volume holds, so a rebuild or a newer base never moves it backwards.

A new Claude Code release needs no rebuild and no workbench release. When one
breaks something the SDD loop relies on, until the fix lands:

```bash
claude-hold 2.1.325     # install that version, keep it, switch updates off
claude-release          # switch updates back on, and update now
```

The loop records which version every session ran on, so a release that
changes its behaviour is traced at once.

## Developing it

```bash
test/run.sh                          # T5 on this machine's platform: build, check, budgets
test/run.sh --platform linux/amd64   # the other architecture, through emulation
test/claude-code/run.sh              # Claude Code on its volume (needs the network)
python3 tools/sdd compose --workbench ../sdd-workbench   # in a project: build from this checkout
```

`budgets.json` holds each image's size budget, which `test/run.sh` checks.

## Releasing

Semver for the set (`VERSION`). A tag `v<x.y.z>` runs `publish.yml`: the base
image for `linux/amd64` and `linux/arm64` as `base:<x.y.z>` and `base:<x>`, and
each add-on with `devcontainers/action` as `<add-on>:<x>`. A major moves Debian,
the Node LTS or PHP's minor version. A release never carries Claude Code.
Projects pick a new release up through `sdd sync`, then a lock refresh and a
rebuild.
