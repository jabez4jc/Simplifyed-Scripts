#!/bin/bash
# OpenAlgo Utility - Apply mitigations for known upstream bugs
#
# Upstream OpenAlgo ships bugs that break instances under this deployment's
# gunicorn/eventlet configuration. Installers and oa-update.sh call this after
# any git clone/pull, because a pull silently reverts these patches.
#
# Every patch here MUST be:
#   - idempotent (safe to run repeatedly)
#   - pattern-matched, never line-numbered (upstream shifts lines constantly)
#   - self-skipping once upstream fixes the bug (pattern stops matching)
#   - reverted automatically if the result doesn't compile
#
# Usage:
#   oa-patch-known-issues.sh                    # all instances under BASE_DIR
#   oa-patch-known-issues.sh /path/to/instance  # one instance
#   oa-patch-known-issues.sh --self-test        # verify patch logic, touch nothing

set -uo pipefail

BASE_DIR="/var/python/openalgo-flask"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

PATCHED=0; SKIPPED=0; FAILED=0

# Patch 1: WhatsApp bot auto-start wedges the eventlet worker.
#
# app.py auto-starts the WhatsApp bot on a raw threading.Thread. That thread
# acquires an eventlet semaphore; the hub, on a different OS thread, then hits
# "greenlet.error: Cannot switch to a different thread" inside fire_timers and
# its timer/accept loop dies. The worker keeps running and systemd keeps
# reporting active while every request hangs until nginx 504s.
#
# Mitigation: force the is_paired gate false so auto-start returns early. The
# bot still starts manually from the UI; pairing and session blob are untouched.
# Real fix belongs upstream: eventlet.spawn() instead of threading.Thread().
WHATSAPP_MARKER="OA-PATCH: whatsapp-autostart-disabled"

patch_whatsapp_autostart() {
    local app_py="$1"

    python3 - "$app_py" "$WHATSAPP_MARKER" <<'PYEOF'
import pathlib, re, sys, py_compile, tempfile, os

path, marker = pathlib.Path(sys.argv[1]), sys.argv[2]
src = path.read_text()

if marker in src:
    print("SKIP already patched"); sys.exit(0)

# The gate guarding the auto-start. Matched with its indentation so the
# replacement keeps the block structure (logger.debug + return stay under it).
pattern = re.compile(r'^(?P<indent>[ \t]+)if not get_bot_config\(\)\.get\("is_paired"\):[ \t]*$',
                     re.MULTILINE)
m = pattern.search(src)
if not m:
    # Upstream changed or fixed it - do not guess, leave the file alone.
    print("SKIP pattern absent (upstream changed or already fixed)"); sys.exit(0)

# Only patch if the auto-start really is on a raw OS thread. If upstream moved
# to eventlet.spawn, the bug is gone and patching would be wrong.
tail = src[m.end():m.end() + 2000]
if "threading.Thread" not in tail and "_threading.Thread" not in tail:
    print("SKIP auto-start no longer uses a raw thread"); sys.exit(0)

patched = pattern.sub(lambda mm: f'{mm.group("indent")}if True:  # {marker}', src, count=1)

# Never leave a non-compiling app.py behind - verify before writing in place.
with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False) as tmp:
    tmp.write(patched); tmp_path = tmp.name
try:
    py_compile.compile(tmp_path, doraise=True)
except py_compile.PyCompileError as e:
    os.unlink(tmp_path); print(f"FAIL patched file does not compile: {e}"); sys.exit(1)
os.unlink(tmp_path)

path.write_text(patched)
print("PATCHED whatsapp auto-start disabled")
PYEOF
}

apply_to_instance() {
    local instance_dir="$1"
    local name; name="$(basename "$instance_dir")"
    local app_py="$instance_dir/app.py"

    if [ ! -f "$app_py" ]; then
        echo -e "${YELLOW}⚠ $name: app.py not found, skipping${NC}"; return 0
    fi

    local backup="$app_py.oa-patch.bak"
    sudo cp "$app_py" "$backup"

    local out rc
    out=$(sudo -E bash -c "$(declare -f patch_whatsapp_autostart); WHATSAPP_MARKER='$WHATSAPP_MARKER'; patch_whatsapp_autostart '$app_py'" 2>&1)
    rc=$?

    case "$out" in
        PATCHED*)
            echo -e "${GREEN}✓ $name: ${out#PATCHED }${NC}"
            sudo chown www-data:www-data "$app_py" 2>/dev/null || true
            PATCHED=$((PATCHED + 1))
            ;;
        SKIP*)
            echo -e "${BLUE}· $name: ${out#SKIP }${NC}"
            sudo rm -f "$backup"
            SKIPPED=$((SKIPPED + 1))
            ;;
        *)
            echo -e "${RED}✗ $name: $out${NC}"
            sudo cp "$backup" "$app_py"   # restore, never leave it broken
            FAILED=$((FAILED + 1))
            return 1
            ;;
    esac
    return 0
}

self_test() {
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local fails=0

    # Vulnerable sample: raw thread auto-start, mirrors upstream app.py
    cat > "$tmp/app.py" <<'EOF'
def outer():
            def _autostart_whatsapp_bot():
                try:
                    from database.whatsapp_db import get_bot_config

                    if not get_bot_config().get("is_paired"):
                        logger.debug("skipping")
                        return
                    ok, msg = whatsapp_bot_service.start_bot()
                except Exception:
                    logger.exception("crashed")

            import threading as _threading
            _threading.Thread(target=_autostart_whatsapp_bot, daemon=True).start()
EOF
    local out
    out=$(patch_whatsapp_autostart "$tmp/app.py")
    [[ "$out" == PATCHED* ]] || { echo "FAIL: vulnerable file not patched ($out)"; fails=1; }
    grep -q "if True:  # $WHATSAPP_MARKER" "$tmp/app.py" || { echo "FAIL: marker missing"; fails=1; }
    python3 -m py_compile "$tmp/app.py" || { echo "FAIL: result does not compile"; fails=1; }

    # Idempotence: second run must not double-patch
    out=$(patch_whatsapp_autostart "$tmp/app.py")
    [[ "$out" == SKIP\ already* ]] || { echo "FAIL: not idempotent ($out)"; fails=1; }

    # Upstream-fixed sample: eventlet.spawn instead of a raw thread - leave alone
    cat > "$tmp/fixed.py" <<'EOF'
def outer():
            def _autostart_whatsapp_bot():
                    if not get_bot_config().get("is_paired"):
                        return
            eventlet.spawn(_autostart_whatsapp_bot)
EOF
    out=$(patch_whatsapp_autostart "$tmp/fixed.py")
    [[ "$out" == SKIP\ auto-start* ]] || { echo "FAIL: patched an already-fixed file ($out)"; fails=1; }

    # Unrelated file: no gate present
    echo "print('hello')" > "$tmp/other.py"
    out=$(patch_whatsapp_autostart "$tmp/other.py")
    [[ "$out" == SKIP\ pattern* ]] || { echo "FAIL: matched an unrelated file ($out)"; fails=1; }

    [ "$fails" -eq 0 ] && echo -e "${GREEN}✓ self-test passed${NC}" || echo -e "${RED}✗ self-test failed${NC}"
    return "$fails"
}

main() {
    if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

    echo -e "${BLUE}Applying known-issue mitigations...${NC}"

    if [ -n "${1:-}" ]; then
        apply_to_instance "$1"
    else
        local found=0
        for dir in "$BASE_DIR"/openalgo*/; do
            [ -d "$dir" ] || continue
            apply_to_instance "${dir%/}"; found=1
        done
        [ "$found" -eq 0 ] && echo -e "${YELLOW}⚠ No instances found under $BASE_DIR${NC}"
    fi

    echo -e "${BLUE}Patched: $PATCHED  Skipped: $SKIPPED  Failed: $FAILED${NC}"
    [ "$FAILED" -gt 0 ] && exit 1
    exit 0
}

main "$@"
