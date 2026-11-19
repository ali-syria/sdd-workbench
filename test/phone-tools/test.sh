#!/usr/bin/env bash
# T5: Java, adb (through its bridge wrapper) and Maestro answer. Reaching a
# real adb server is spike S3's, on a Mac with an emulator.
set -u
fail=0
check() { local l="$1"; shift; if out="$("$@" 2>&1)"; then echo "ok    $l $(echo "$out" | head -n1)"; else echo "FAIL  $l $(echo "$out" | head -n1)"; fail=1; fi; }
check java        java -version
check adb         /usr/bin/adb.real version
check adb-wrapper bash -c 'grep -q adb-bridge /usr/bin/adb && echo "adb goes through adb-bridge"'
check adb-bridge  bash -c 'command -v adb-bridge'
check maestro     bash -lc 'maestro --version 2>&1 | grep -v -i analytics'
check no-analytics bash -lc '[ -n "$MAESTRO_CLI_NO_ANALYTICS" ] && echo "Maestro analytics off"'
check server-ver  bash -c '/usr/bin/adb.real version | grep -q "Android Debug Bridge version 1.0.41" && echo "server protocol 41"'
exit $fail
