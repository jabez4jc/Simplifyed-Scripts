#!/bin/bash
# Set up a Simplifyed OpenAlgo server in one line:
#
#   curl -fsSL https://raw.githubusercontent.com/jabez4jc/Simplifyed-Scripts/main/install.sh | sudo bash
#
# Options are passed through to `oa install`, e.g.:
#   ... | sudo bash -s -- --no-branding --swap 8
#
# Clones (or updates) this repo at /root/Simplifyed-Scripts - the path the admin
# dashboard looks in first - links the `oa` command, then runs `oa install`.

set -e
REPO_URL="https://github.com/jabez4jc/Simplifyed-Scripts.git"
DIR="/root/Simplifyed-Scripts"

[ "$EUID" -eq 0 ] || { echo "Run as root: curl -fsSL <url>/install.sh | sudo bash"; exit 1; }

apt-get update -qq
apt-get install -y -qq git curl >/dev/null

if [ -d "$DIR/.git" ]; then
    git -C "$DIR" pull -q --ff-only
else
    [ -e "$DIR" ] && mv "$DIR" "$DIR.old.$(date +%s)"
    git clone -q "$REPO_URL" "$DIR"
fi
ln -sf "$DIR/oa.sh" /usr/local/bin/oa

# Existing server: just make the `oa` command available.
if compgen -G "/var/python/openalgo-flask/openalgo[0-9]*" >/dev/null; then
    echo "OpenAlgo instances already installed. The 'oa' command is ready - run: oa help"
    exit 0
fi

# Piped through bash, stdin is this script - the installer's questions must
# read from the terminal instead.
exec /usr/local/bin/oa install "$@" < /dev/tty
