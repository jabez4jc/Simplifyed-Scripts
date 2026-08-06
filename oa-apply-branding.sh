#!/bin/bash
# OpenAlgo Utility - Apply Simplifyed branding to an instance
#
# OpenAlgo serves a PRE-BUILT React app: blueprints/react_app.py serves every
# route out of frontend/dist, and frontend/dist is committed upstream. Editing
# frontend/src would need node + `npm run build` on every server on every
# update, so this patches frontend/dist directly instead.
#
# Installers and oa-update.sh call this after any git clone/pull, because a
# pull (or the reset --hard fallback) restores upstream's dist.
#
# Every replacement here MUST be:
#   - idempotent (safe to run repeatedly; once applied the patterns stop matching)
#   - pattern-matched, never line/offset-based (chunk hashes change every build)
#   - degrade to "less branding", never to a broken page, if a pattern stops matching
#
# Deliberately NOT renamed: docs.openalgo.in links, OPENALGO_* env vars, the
# lowercase `openalgo` Python SDK package name, service names, DB paths,
# API fields, browser storage keys.
#
# Usage:
#   oa-apply-branding.sh                    # all instances marked for branding
#   oa-apply-branding.sh /path/to/instance  # brand it, and mark it for future updates
#   oa-apply-branding.sh --self-test        # verify patch logic against a synthetic dist
#
# AGPL-3.0: OpenAlgo's licence, copyright and source-availability obligations
# survive rebranding. This changes presentation only.

set -uo pipefail

BASE_DIR="/var/python/openalgo-flask"
BRAND_URL="${BRAND_URL:-https://simplifyed.in}"
BRAND_NAME="Simplifyed"
MARKER_FILE=".simplifyed-branding"   # untracked, so git reset --hard keeps it

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ASSET_DIR="$SCRIPT_DIR/branding/assets"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

BRANDED=0; SKIPPED=0; FAILED=0

brand_instance() {
    local dir="$1" mark_it="$2"
    local dist="$dir/frontend/dist"

    if [ ! -f "$dist/index.html" ]; then
        echo -e "${YELLOW}⚠ $dir: no frontend/dist — nothing to brand${NC}"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    for a in favicon.ico apple-touch-icon.png mark-192.png home-logo.png; do
        if [ ! -f "$ASSET_DIR/$a" ]; then
            echo -e "${RED}✗ Missing branding asset: $ASSET_DIR/$a${NC}"
            FAILED=$((FAILED + 1))
            return 1
        fi
    done

    # Text pass first: it guards, and refuses to touch anything if upstream has
    # started using "OpenAlgo" as a value. Assets are only swapped once it passes.
    python3 - "$dir" "$BRAND_URL" "$BRAND_NAME" <<'PY'
import gzip, re, shutil, subprocess, sys
from pathlib import Path

root, brand_url, brand_name = Path(sys.argv[1]), sys.argv[2].rstrip("/"), sys.argv[3]
dist = root / "frontend" / "dist"

# Outbound destinations only. docs.openalgo.in is NOT in this map and does not
# match any key, so documentation links stay with upstream.
url_map = {
    "https://www.openalgo.in": brand_url,
    "https://openalgo.in": brand_url,
    "https://github.com/marketcalls/openalgo": brand_url,
    "https://x.com/openalgoHQ": brand_url,
    "https://www.youtube.com/@openalgo": brand_url,
}

# This overlay assumes capitalised "OpenAlgo" is ALWAYS display copy — true of
# every occurrence in upstream today. If upstream ever uses it as a VALUE (a
# compared constant, an object/JSON key, a storage key, a URL path), a blind
# replace would silently change behaviour rather than just wording. Refuse to
# brand at all in that case: an unbranded instance is a cosmetic problem, a
# subtly miswired one is not.
suspicious = [
    ("compared as a constant",
     re.compile(r"(?:===?|!==?)\s*[`\"']OpenAlgo")),
    ("compared as a constant",
     re.compile(r"[`\"']OpenAlgo[^`\"'\n]*[`\"']\s*(?:===?|!==?)")),
    ("used as an object or JSON key",
     re.compile(r"[{,]\s*[`\"']OpenAlgo[^`\"'\n]*[`\"']\s*:")),
    ("used as a switch/case constant",
     re.compile(r"\bcase\s+[`\"']OpenAlgo")),
    ("used as a browser storage key",
     re.compile(r"(?:getItem|setItem|removeItem)\(\s*[`\"'][^`\"'\n]*OpenAlgo")),
    ("used inside a URL or request path",
     re.compile(r"[`\"'](?:/|https?://)[^`\"'\n]*OpenAlgo")),
]

# Known-benign matches, reviewed one by one. Each is a comparison where BOTH
# operands are literals in the same chunk, so rewriting them together preserves
# the comparison exactly. Written loosely enough to survive minifier variable
# renaming, but tightly enough that a real change upstream stops matching and
# re-arms the guard.
benign = [
    # usePageTitle: document.title = t === 'OpenAlgo' ? 'OpenAlgo' : `${t} | OpenAlgo`
    re.compile(r"document\.title\s*=\s*\w+\s*===?\s*`OpenAlgo`\s*\?\s*`OpenAlgo`\s*:\s*`\$\{\w+\} \| OpenAlgo`"),
]

def guard(text, label):
    allowed = [m.span() for p in benign for m in p.finditer(text)]
    hits = []
    for reason, pattern in suspicious:
        for m in pattern.finditer(text):
            if any(lo <= m.start() and m.end() <= hi for lo, hi in allowed):
                continue
            start = max(0, m.start() - 40)
            hits.append(f"    {label}: {reason}\n      ...{text[start:m.end() + 40]}...")
    return hits

def rewrite(text):
    for old, new in url_map.items():
        text = text.replace(old, new)
    # Capitalised "OpenAlgo" is display copy everywhere in this app. Lowercase
    # `openalgo` is left alone: it is the SDK package name and env-var prefix.
    text = text.replace("OpenAlgo", brand_name)
    # ...except the lowercase visual wordmark in the Flow / Playground headers,
    # which is the only lowercase occurrence rendered as a brand name.
    text = re.sub(r"(className:.font-semibold text-sm.,children:.)openalgo(.)",
                  lambda m: m.group(1) + brand_name + m.group(2), text)
    # Chart watermark glyph. The label next to it is already rewritten above.
    text = text.replace("/images/openalgo-glyph.svg", "/images/simplifyed-glyph.png")
    return text

def recompress(path):
    """Refresh the .br/.gz siblings Flask negotiates in serve_assets().

    A stale sibling would ship the OLD bytes to every client that advertises
    the encoding, so they must be rebuilt or removed — never left behind.
    """
    gz = path.with_suffix(path.suffix + ".gz")
    br = path.with_suffix(path.suffix + ".br")
    if gz.exists():
        with path.open("rb") as fin, gzip.open(gz, "wb", compresslevel=9) as fout:
            shutil.copyfileobj(fin, fout)
    if br.exists():
        br.unlink()
        # brotli CLI is optional; without it Flask falls back to .gz, then raw.
        subprocess.run(["brotli", "-q", "11", "-o", str(br), str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

targets = sorted((dist / "assets").glob("*.js")) + [dist / "index.html"]
findings = []
for path in targets:
    findings += guard(path.read_text(encoding="utf-8"), path.name)
if findings:
    print("  REFUSING TO BRAND: upstream now uses \"OpenAlgo\" as a value, not just\n"
          "  display copy. Rebranding it would change behaviour, not just wording.\n"
          "  Review these and narrow the rewrite rules in oa-apply-branding.sh:\n"
          + "\n".join(findings[:10])
          + (f"\n    ...and {len(findings) - 10} more" if len(findings) > 10 else ""),
          file=sys.stderr)
    sys.exit(2)

changed = 0
for path in sorted((dist / "assets").glob("*.js")):
    before = path.read_text(encoding="utf-8")
    after = rewrite(before)
    if after != before:
        path.write_text(after, encoding="utf-8")
        recompress(path)
        changed += 1

# Public Home page header: swap the square mark + wordmark span for the
# horizontal lockup. Purely cosmetic — if a future build changes this shape the
# pattern stops matching and the header keeps the (already rebranded) square mark.
home_pat = re.compile(
    r"\(`img`,\{src:`/logo\.png`,alt:`" + re.escape(brand_name) + r"`,className:`h-8 w-8`\}\),"
    r"\(0,[A-Za-z_$][\w$]*\.jsx\)\(`span`,\{className:`text-xl [^`]*`,children:`"
    + re.escape(brand_name) + r"`\}\)"
)
lockup = ("(`img`,{src:`/images/simplifyed-home-logo.png`,alt:`" + brand_name
          + "`,className:`h-8 w-auto sfy-logo`})")
for path in sorted((dist / "assets").glob("Home-*.js")):
    before = path.read_text(encoding="utf-8")
    after, n = home_pat.subn(lockup, before)
    if n:
        path.write_text(after, encoding="utf-8")
        recompress(path)
        print(f"  home lockup applied ({n} header(s))")

index = dist / "index.html"
text = rewrite(index.read_text(encoding="utf-8"))
text = text.replace(
    f'content="{brand_name} - Open Source Algorithmic Trading Platform"',
    f'content="{brand_name} - Algorithmic Trading Platform"')
# Browsers cache /favicon.ico hard. A stable query string forces one refetch.
if "?v=sfy1" not in text:
    text = text.replace('href="/favicon.ico"', 'href="/favicon.ico?v=sfy1"')
    text = text.replace('href="/apple-touch-icon.png"', 'href="/apple-touch-icon.png?v=sfy1"')
# The grayscale lockup is dark ink; invert it on dark backgrounds. Tailwind's
# dark:invert utility is not in the built CSS, so ship the rule inline.
if "sfy-brand-style" not in text:
    text = text.replace("</head>",
        '  <style id="sfy-brand-style">.dark .sfy-logo{filter:invert(1)}</style>\n  </head>')
index.write_text(text, encoding="utf-8")
for stale in (dist / "index.html.gz", dist / "index.html.br"):
    if stale.exists():
        stale.unlink()

# Terminal banner only. Runtime identifiers (OPENALGO_*, DB paths) untouched.
app = root / "app.py"
if app.exists():
    text = app.read_text(encoding="utf-8")
    text = text.replace("Starting OpenAlgo...", f"Starting {brand_name}...")
    text = text.replace('f" OpenAlgo v{_ver} "', 'f" %s v{_ver} "' % brand_name)
    text = text.replace('"Your Personal Algo Trading Platform"',
                        f'"{brand_name} Algorithmic Trading Platform"')
    app.write_text(text, encoding="utf-8")

print(f"  {changed} asset chunk(s) rebranded")
if list(dist.rglob("*")) and "OpenAlgo" in index.read_text(encoding="utf-8"):
    print("  WARNING: index.html still mentions OpenAlgo", file=sys.stderr)
PY

    local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}✗ $dir: branding failed — instance left with upstream branding${NC}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Square mark fills every square logo slot the app serves.
    install -Dm0644 "$ASSET_DIR/favicon.ico"          "$dist/favicon.ico"
    install -Dm0644 "$ASSET_DIR/apple-touch-icon.png" "$dist/apple-touch-icon.png"
    install -Dm0644 "$ASSET_DIR/mark-192.png"         "$dist/logo.png"
    install -Dm0644 "$ASSET_DIR/mark-192.png"         "$dist/images/android-chrome-192x192.png"
    install -Dm0644 "$ASSET_DIR/mark-192.png"         "$dist/images/simplifyed-glyph.png"
    install -Dm0644 "$ASSET_DIR/home-logo.png"        "$dist/images/simplifyed-home-logo.png"

    [ "$mark_it" = "mark" ] && touch "$dir/$MARKER_FILE"
    chown -R www-data:www-data "$dist" 2>/dev/null
    echo -e "${GREEN}✓ $dir branded ($BRAND_NAME)${NC}"
    BRANDED=$((BRANDED + 1))
    return 0
}

self_test() {
    echo -e "${BLUE}Self-test: synthetic dist${NC}"
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/frontend/dist/assets" "$tmp/frontend/dist/images"

    cat > "$tmp/frontend/dist/index.html" <<'EOF'
<!doctype html><html><head>
<link rel="icon" href="/favicon.ico" />
<link rel="apple-touch-icon" href="/apple-touch-icon.png" />
<meta name="description" content="OpenAlgo - Open Source Algorithmic Trading Platform" />
<title>OpenAlgo</title>
</head><body></body></html>
EOF
    cat > "$tmp/frontend/dist/assets/Home-abc123.js" <<'EOF'
(0,M.jsx)(`img`,{src:`/logo.png`,alt:`OpenAlgo`,className:`h-8 w-8`}),(0,M.jsx)(`span`,{className:`text-xl font-semibold`,children:`OpenAlgo`})
EOF
    cat > "$tmp/frontend/dist/assets/Misc-def456.js" <<'EOF'
a=`https://openalgo.in/discord`;b=`https://docs.openalgo.in/getting-started`;
c=`OpenAlgo Charts`;d=`/images/openalgo-glyph.svg`;
e=(0,q.jsx)(`span`,{className:`font-semibold text-sm`,children:`openalgo`});
f=(0,k.jsx)(`code`,{className:`bg-muted px-1 rounded`,children:`openalgo`});
g=`OPENALGO_API_KEY`;h=localStorage.getItem(`openalgo_theme`);
EOF
    gzip -9 -k "$tmp/frontend/dist/assets/Misc-def456.js"
    printf 'print("Starting OpenAlgo...")\n_t = f" OpenAlgo v{_ver} "\n_sl = "Your Personal Algo Trading Platform"\n' > "$tmp/app.py"

    BRANDED=0; SKIPPED=0; FAILED=0
    brand_instance "$tmp" "nomark" >/dev/null 2>&1

    local fails=0
    check() { # description, expected-to-be-found, file
        if grep -qF "$2" "$3"; then echo -e "  ${GREEN}✓${NC} $1"; else echo -e "  ${RED}✗${NC} $1"; fails=$((fails+1)); fi
    }
    check_absent() {
        if grep -qF "$2" "$3"; then echo -e "  ${RED}✗${NC} $1"; fails=$((fails+1)); else echo -e "  ${GREEN}✓${NC} $1"; fi
    }
    local idx="$tmp/frontend/dist/index.html"
    local misc="$tmp/frontend/dist/assets/Misc-def456.js"
    local home="$tmp/frontend/dist/assets/Home-abc123.js"

    check        "title rebranded"                  "<title>Simplifyed</title>" "$idx"
    check        "description rebranded"            "Simplifyed - Algorithmic Trading Platform" "$idx"
    check        "favicon cache-buster added"       "/favicon.ico?v=sfy1" "$idx"
    check        "dark-mode logo style injected"    "sfy-brand-style" "$idx"
    check        "outbound link rebranded, path kept" "https://simplifyed.in/discord" "$misc"
    check        "docs.openalgo.in preserved"       "https://docs.openalgo.in/getting-started" "$misc"
    check        "display copy rebranded"           "Simplifyed Charts" "$misc"
    check        "chart glyph repointed"            "/images/simplifyed-glyph.png" "$misc"
    check        "lowercase wordmark rebranded"     "text-sm\`,children:\`Simplifyed\`" "$misc"
    check_absent "SDK package name preserved"       "rounded\`,children:\`Simplifyed\`" "$misc"
    check        "SDK package name still openalgo"  "rounded\`,children:\`openalgo\`" "$misc"
    check        "env var preserved"                "OPENALGO_API_KEY" "$misc"
    check        "storage key preserved"            "openalgo_theme" "$misc"
    check        "home lockup applied"              "/images/simplifyed-home-logo.png" "$home"
    check_absent "home square mark replaced"        "src=\`/logo.png\`" "$home"
    check        "app.py banner rebranded"          "Starting Simplifyed..." "$tmp/app.py"

    # A stale .gz would serve the pre-branding bytes to every gzip client.
    if [ -f "$misc.gz" ] && gzip -dc "$misc.gz" | grep -qF "Simplifyed Charts"; then
        echo -e "  ${GREEN}✓${NC} .gz sibling refreshed"
    else
        echo -e "  ${RED}✗${NC} .gz sibling refreshed"; fails=$((fails+1))
    fi

    # Idempotency: a second pass must change nothing.
    local before; before=$(cat "$idx" "$misc" "$home" "$tmp/app.py" | md5sum 2>/dev/null || cat "$idx" "$misc" "$home" "$tmp/app.py" | md5)
    brand_instance "$tmp" "nomark" >/dev/null 2>&1
    local after; after=$(cat "$idx" "$misc" "$home" "$tmp/app.py" | md5sum 2>/dev/null || cat "$idx" "$misc" "$home" "$tmp/app.py" | md5)
    if [ "$before" = "$after" ]; then
        echo -e "  ${GREEN}✓${NC} idempotent on re-run"
    else
        echo -e "  ${RED}✗${NC} idempotent on re-run"; fails=$((fails+1))
    fi

    # Guard: a future upstream that uses "OpenAlgo" as a value must abort the
    # whole overlay, leaving the instance untouched rather than half-rewritten.
    local guard_dir; guard_dir=$(mktemp -d)
    mkdir -p "$guard_dir/frontend/dist/assets" "$guard_dir/frontend/dist/images"
    cp "$idx" "$guard_dir/frontend/dist/index.html"
    printf 'if(x.platform===`OpenAlgo`){go()}\n' > "$guard_dir/frontend/dist/assets/Danger-000.js"
    local before_guard; before_guard=$(cat "$guard_dir/frontend/dist/assets/Danger-000.js")
    BRANDED=0; SKIPPED=0; FAILED=0
    if brand_instance "$guard_dir" "nomark" >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} guard aborts when OpenAlgo is used as a value"; fails=$((fails+1))
    elif [ "$(cat "$guard_dir/frontend/dist/assets/Danger-000.js")" = "$before_guard" ] \
         && [ ! -f "$guard_dir/frontend/dist/logo.png" ]; then
        echo -e "  ${GREEN}✓${NC} guard aborts and changes nothing when OpenAlgo is a value"
    else
        echo -e "  ${RED}✗${NC} guard aborted but left partial changes"; fails=$((fails+1))
    fi
    rm -rf "$guard_dir"

    if [ $fails -eq 0 ]; then
        echo -e "${GREEN}Self-test passed${NC}"; return 0
    fi
    echo -e "${RED}Self-test failed: $fails check(s)${NC}"; return 1
}

# --- main ---
case "${1:-}" in
    --self-test)
        self_test
        exit $?
        ;;
    "")
        # Update path: re-brand every instance already marked for branding.
        shopt -s nullglob
        for dir in "$BASE_DIR"/openalgo[0-9]*; do
            [ -d "$dir" ] || continue
            [ -f "$dir/$MARKER_FILE" ] || continue
            brand_instance "$dir" "nomark"
        done
        shopt -u nullglob
        if [ $((BRANDED + SKIPPED + FAILED)) -eq 0 ]; then
            echo -e "${BLUE}No instances marked for branding${NC}"
        fi
        ;;
    -h|--help)
        sed -n '2,26p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    *)
        if [ ! -d "$1" ]; then
            echo -e "${RED}Not a directory: $1${NC}" >&2
            exit 1
        fi
        brand_instance "$1" "mark"
        ;;
esac

[ $FAILED -gt 0 ] && exit 1
exit 0
