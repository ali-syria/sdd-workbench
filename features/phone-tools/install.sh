#!/usr/bin/env bash
# The `phone-tools` add-on: Java, adb, Maestro, and the adb bridge. Runs as root
# at build time.
#
# Why a bridge: on a Mac, the Android emulator and every plugged-in phone sit
# behind the Mac's own adb server, on 127.0.0.1:5037. The container reaches the
# Mac's loopback as host.docker.internal (Docker Desktop), so `adb-bridge`
# forwards the container's own 127.0.0.1:5037 there with socat. Every adb
# client in the container (adb itself, and Maestro's dadb, which talks to
# localhost:5037) then sees the Mac's devices, and the container never starts
# an adb server of its own, which would see no device at all.
set -euo pipefail
MAESTRO="${MAESTRO:-2.12.1}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends openjdk-17-jre-headless adb socat unzip curl ca-certificates
rm -rf /var/lib/apt/lists/*

# Maestro, from its GitHub release, at a pinned version.
curl -fsSL -o /tmp/maestro.zip \
  "https://github.com/mobile-dev-inc/Maestro/releases/download/cli-${MAESTRO}/maestro.zip"
rm -rf /opt/maestro && mkdir -p /opt
unzip -q /tmp/maestro.zip -d /opt
rm /tmp/maestro.zip
test -x /opt/maestro/bin/maestro

# The bridge, and an adb that makes sure of it before it runs.
mv /usr/bin/adb /usr/bin/adb.real
install -m 0755 "$(dirname "$0")/adb-bridge" /usr/local/bin/adb-bridge
cat > /usr/bin/adb <<'SH'
#!/usr/bin/env bash
# adb, through the bridge to the host's adb server (see adb-bridge).
/usr/local/bin/adb-bridge ensure >/dev/null 2>&1 || true
exec /usr/bin/adb.real "$@"
SH
chmod 0755 /usr/bin/adb
/usr/bin/adb.real version | head -n 1
