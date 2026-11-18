#!/usr/bin/env bash
# T5: Firefox's and WebKit's runtime libraries resolve.
set -u
fail=0
check() { local l="$1"; shift; if out="$("$@" 2>&1)"; then echo "ok    $l $(echo "$out" | head -n1)"; else echo "FAIL  $l $(echo "$out" | head -n1)"; fail=1; fi; }
for lib in libdbus-glib-1.so.2 libwoff2dec.so libharfbuzz-icu.so.0 libenchant-2.so.2 libsecret-1.so.0 libhyphen.so.0; do
  check "lib:$lib" bash -c "ldconfig -p | grep -q '$lib' && echo present"
done
exit $fail
