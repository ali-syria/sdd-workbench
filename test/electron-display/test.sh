#!/usr/bin/env bash
# T5: a virtual display starts, and Electron's shared libraries resolve.
# (Electron itself is launched and driven in spike S6 and each desktop
# template's T1; it is not part of the image.)
set -u
fail=0
check() { local l="$1"; shift; if out="$("$@" 2>&1)"; then echo "ok    $l $(echo "$out" | head -n1)"; else echo "FAIL  $l $(echo "$out" | head -n1)"; fail=1; fi; }
check xvfb-run  bash -c 'xvfb-run -a sh -c "echo display \$DISPLAY"'
for lib in libgtk-3.so.0 libnss3.so libasound.so.2 libgbm.so.1 libXss.so.1 libdbus-1.so.3; do
  check "lib:$lib" bash -c "ldconfig -p | grep -q '$lib' && echo present"
done
exit $fail
