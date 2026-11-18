#!/usr/bin/env bash
# The `electron-display` add-on: what Electron needs to start without a screen.
# The set spike S6 proved on Debian bookworm, arm64. Runs as root at build time.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xvfb xauth \
  libgtk-3-0 libnss3 libasound2 libgbm1 libxss1 libdrm2 libxshmfence1 \
  libatk-bridge2.0-0 libatspi2.0-0 libcups2 libxkbcommon0 libxcomposite1 \
  libxdamage1 libxfixes3 libxrandr2 libnspr4 \
  dbus dbus-x11 fonts-liberation
rm -rf /var/lib/apt/lists/*
install -d -o dev -g dev /home/dev/.cache /home/dev/.cache/electron 2>/dev/null || true
command -v xvfb-run
