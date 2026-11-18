#!/usr/bin/env bash
# The `browsers-extra` add-on: Firefox's and WebKit's runtime libraries on
# Debian bookworm, through Playwright's own list (install-deps), at the
# Playwright version the base image names. Runs as root at build time.
set -euo pipefail
: "${SDD_PLAYWRIGHT_VERSION:=1.65.1}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
npx --yes "playwright@${SDD_PLAYWRIGHT_VERSION}" install-deps firefox webkit
rm -rf /var/lib/apt/lists/*
