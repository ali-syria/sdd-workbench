#!/usr/bin/env bash
# The `php` add-on: PHP CLI (Sury), the Laravel scaffold's extensions,
# Composer, PCOV, and Xdebug off unless asked for. Runs as root at build time.
set -euo pipefail
VERSION="${VERSION:-8.5}"
XDEBUG="${XDEBUG:-off}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg2 lsb-release
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg
echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/sury-php.list
apt-get update
apt-get install -y --no-install-recommends \
  "php${VERSION}-cli" \
  "php${VERSION}-curl" "php${VERSION}-mbstring" "php${VERSION}-xml" "php${VERSION}-zip" \
  "php${VERSION}-mysql" "php${VERSION}-sqlite3" "php${VERSION}-gd" "php${VERSION}-intl" \
  "php${VERSION}-xsl" "php${VERSION}-soap" "php${VERSION}-bcmath" "php${VERSION}-redis" \
  "php${VERSION}-pcov" "php${VERSION}-xdebug" \
  unzip
rm -rf /var/lib/apt/lists/*

# Xdebug off by default: it slows every test, and PCOV gives coverage.
# XDEBUG_MODE=debug php artisan … turns it on for one command; when it is on,
# it connects back to the IDE on the host, and only there. Never
# discover_client_host (F72): with it a request names the address Xdebug
# connects to, so any page that reaches a served app could open a debug
# session to itself.
cat > "/etc/php/${VERSION}/mods-available/sdd-xdebug.ini" <<INI
xdebug.mode = ${XDEBUG}
xdebug.discover_client_host = 0
xdebug.client_host = host.docker.internal
xdebug.start_with_request = trigger
INI
ln -sf "/etc/php/${VERSION}/mods-available/sdd-xdebug.ini" "/etc/php/${VERSION}/cli/conf.d/99-sdd-xdebug.ini"

# Composer, checksum-verified against its own published signature.
expected="$(curl -fsSL https://composer.github.io/installer.sig)"
curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
if [ "$expected" != "$actual" ]; then
  echo "php add-on: Composer's installer failed its checksum" >&2
  exit 1
fi
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
rm /tmp/composer-setup.php

install -d -o dev -g dev /home/dev/.composer 2>/dev/null || install -d /home/dev/.composer
php --version | head -n 1
composer --version
