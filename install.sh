#!/bin/bash
# Set up a Simplifyed OpenAlgo server in one line:
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jabez4jc/Simplifyed-Scripts/main/install.sh)"
#
# Options are passed through to `oa install`, e.g.:
#   sudo bash -c "$(curl -fsSL .../install.sh)" _ --no-branding --swap 8
#
# Not `curl ... | sudo bash`: sudo-rs (Ubuntu 25.10+) runs the script in its own
# pseudo-terminal and, with stdin piped, never forwards keystrokes to it, so the
# installer's first question waits forever.
#
# Clones (or updates) this repo at /root/Simplifyed-Scripts - the path the admin
# dashboard looks in first - links the `oa` command, then runs `oa install`.

set -e
REPO_URL="https://github.com/jabez4jc/Simplifyed-Scripts.git"
DIR="/root/Simplifyed-Scripts"

CMD='sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jabez4jc/Simplifyed-Scripts/main/install.sh)"'
[ "$EUID" -eq 0 ] || { echo "Run as root: $CMD"; exit 1; }
if [ ! -t 0 ] && [ -n "${SUDO_USER:-}" ] && sudo --version 2>/dev/null | grep -q sudo-rs; then
    echo "This server's sudo cannot pass your keyboard to a piped script. Run instead:"
    echo "  $CMD"
    exit 1
fi

apt-get update -qq
apt-get install -y -qq git curl >/dev/null

if [ -d "$DIR/.git" ]; then
    git -C "$DIR" pull -q --ff-only
else
    [ -e "$DIR" ] && mv "$DIR" "$DIR.old.$(date +%s)"
    git clone -q "$REPO_URL" "$DIR"
fi
# A wrapper, not a symlink: /root is 700, so a link into it is a dead end for
# non-root users ("oa: command not found").
rm -f /usr/local/bin/oa
printf '#!/bin/bash\n[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"\nexec bash \"%s/oa.sh\" "$@"\n' "$DIR" > /usr/local/bin/oa
chmod 755 /usr/local/bin/oa

# Existing server: just make the `oa` command available.
if compgen -G "/var/python/openalgo-flask/openalgo[0-9]*" >/dev/null; then
    echo "OpenAlgo instances already installed. The 'oa' command is ready - run: oa help"
    exit 0
fi

# Piped through bash, stdin is this script - the installer's questions must
# read from the terminal instead.
exec /usr/local/bin/oa install "$@" < /dev/tty
