#!/usr/bin/env bash
# Sign a release DMG with the Sparkle key (login keychain) and prepend its
# <item> to docs/appcast.xml. Run AFTER gh release create, then commit + push
# docs/appcast.xml — GitHub Pages serves the feed installed apps poll.
#
# Usage: ./scripts/update_appcast.sh <version> <build> [dmg-path]
#   e.g. ./scripts/update_appcast.sh 1.8.0 14
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: update_appcast.sh <version> <build> [dmg-path]}"
BUILD="${2:?usage: update_appcast.sh <version> <build> [dmg-path]}"
DMG="${3:-$ROOT/build/Omelette.dmg}"
APPCAST="$ROOT/docs/appcast.xml"
REPO_URL="https://github.com/adxd-og/usage-checker"

SIGN_UPDATE="$(find "$ROOT/build/DerivedData/SourcePackages/artifacts" -type f -name sign_update -not -path "*old_dsa*" | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "ERROR: sign_update not found — build the project once first."; exit 1; }
[ -f "$DMG" ] || { echo "ERROR: DMG not found: $DMG"; exit 1; }
[ -f "$APPCAST" ] || { echo "ERROR: appcast not found: $APPCAST"; exit 1; }

SIG_LINE="$("$SIGN_UPDATE" "$DMG")"   # sparkle:edSignature="..." length="..."
PUB_DATE="$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")"

CHANGELOG="$ROOT/CHANGELOG.md"

export VERSION BUILD SIG_LINE PUB_DATE REPO_URL CHANGELOG
python3 - "$APPCAST" <<'PY'
import html, os, re, sys

path = sys.argv[1]
sig = os.environ["SIG_LINE"]
ed = re.search(r'sparkle:edSignature="([^"]+)"', sig).group(1)
length = re.search(r'length="(\d+)"', sig).group(1)
v, b = os.environ["VERSION"], os.environ["BUILD"]
repo = os.environ["REPO_URL"]

# --- release notes: CHANGELOG section for this version -> embedded HTML.
# Sparkle renders <description> right in the update window; a
# releaseNotesLink would embed the whole GitHub page instead.
def md_inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s

def md_to_html(md):
    out, in_list = [], False
    for line in md.splitlines():
        if line.startswith("### "):
            if in_list: out.append("</ul>"); in_list = False
            out.append(f"<h3>{md_inline(line[4:])}</h3>")
        elif line.startswith("- "):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{md_inline(line[2:])}</li>")
        elif line.strip() and in_list:
            out[-1] = out[-1][:-5] + " " + md_inline(line.strip()) + "</li>"
        elif line.strip():
            out.append(f"<p>{md_inline(line.strip())}</p>")
    if in_list: out.append("</ul>")
    return "\n".join(out)

cl = open(os.environ["CHANGELOG"]).read()
m = re.search(rf"^## \[{re.escape(v)}\][^\n]*\n(.*?)(?=^## \[|\Z)", cl, re.S | re.M)
notes = md_to_html(m.group(1).strip()) if m else ""
notes += f'\n<p><a href="{repo}/releases/tag/v{v}">Full release on GitHub</a></p>'

item = f"""    <item>
      <title>Omelette v{v}</title>
      <pubDate>{os.environ["PUB_DATE"]}</pubDate>
      <sparkle:version>{b}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure
        url="{repo}/releases/download/v{v}/Omelette.dmg"
        type="application/octet-stream"
        sparkle:edSignature="{ed}"
        length="{length}"/>
    </item>
"""

text = open(path).read()
marker = "<language>en</language>\n"
assert marker in text, "appcast structure changed — update this script"
assert f"<sparkle:shortVersionString>{v}<" not in text, f"v{v} is already in the appcast"
open(path, "w").write(text.replace(marker, marker + item, 1))
print(f"prepended v{v} (build {b}) to {path}")
PY

echo "Now: git add docs/appcast.xml && git commit && git push"
