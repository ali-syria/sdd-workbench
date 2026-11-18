#!/usr/bin/env bash
# T5: the php add-on's tools answer, with the Laravel scaffold's extensions,
# and Xdebug is off unless asked for.
set -u
fail=0
check() { local l="$1"; shift; if out="$("$@" 2>&1)"; then echo "ok    $l $(echo "$out" | head -n1)"; else echo "FAIL  $l $(echo "$out" | head -n1)"; fail=1; fi; }
check php       php --version
check composer  composer --version
for ext in curl mbstring xml zip mysqli pdo_mysql pdo_sqlite gd intl xsl soap bcmath redis pcov xdebug; do
  check "ext:$ext" bash -c "php -m | grep -qix '$ext' && echo loaded"
done
check xdebug-off bash -c '[ "$(php -r "echo ini_get(\"xdebug.mode\");")" = off ] && echo off'
check xdebug-env bash -c '[ "$(XDEBUG_MODE=debug php -r "echo xdebug_info(\"mode\")[0] ?? \"\";")" = debug ] && echo "XDEBUG_MODE=debug turns it on"'
exit $fail
