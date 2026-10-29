#!/bin/zsh
# Print the Sparkle update feed for one release. scripts/release.sh writes it to
# build/release/appcast.xml and uploads it next to VibeFlow.dmg, and the release reads it from
# https://github.com/floo-one/vibeflow/releases/latest/download/appcast.xml (SUFeedURL).
# One item is enough: Sparkle offers it to every older version.
#
# Usage:  scripts/write-appcast.sh <dmg> <version> <build> <notes.md> [<ed-key-file>]
#
# The DMG is signed with Sparkle's sign_update, by default with the key of account "vibeflow"
# in the login keychain; an ed-key-file signs with a throwaway key instead, for testing.

set -euo pipefail

(( $# >= 4 )) || { print -u2 "Usage: $0 <dmg> <version> <build> <notes.md> [<ed-key-file>]"; exit 2 }
DMG=$1 VERSION=$2 BUILD=$3 NOTES=$4 KEY_FILE=${5:-}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x $SIGN_UPDATE ]] || { print -u2 "error: no $SIGN_UPDATE (xcodebuild -resolvePackageDependencies fetches it)"; exit 1 }

# sparkle:edSignature="…" length="…", the attributes the enclosure needs.
if [[ -n $KEY_FILE ]]; then
  SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$DMG")"
else
  SIGNATURE="$("$SIGN_UPDATE" --account vibeflow "$DMG")"
fi
[[ $SIGNATURE == sparkle:edSignature=*length=* ]] || { print -u2 "error: unexpected sign_update output: $SIGNATURE"; exit 1 }

# The CHANGELOG section as simple HTML for Sparkle's "new version" window: ### headings,
# "- " items with their indented continuation lines, other lines as paragraphs.
notes_html() {
  awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function end_item() { if (item != "") { print "<li>" item "</li>"; item = "" } }
    function end_list() { end_item(); if (list) { print "</ul>"; list = 0 } }
    /^### / { end_list(); print "<h3>" esc(substr($0, 5)) "</h3>"; next }
    /^- / { if (!list) { print "<ul>"; list = 1 } end_item(); item = esc(substr($0, 3)); next }
    /^  +[^ ]/ && item != "" { sub(/^ +/, ""); item = item " " esc($0); next }
    /^[[:space:]]*$/ { end_list(); next }
    { end_list(); print "<p>" esc($0) "</p>" }
    END { end_list() }
  ' "$NOTES"
}

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VibeFlow</title>
    <item>
      <title>VibeFlow $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$(notes_html)
      ]]></description>
      <enclosure url="https://github.com/floo-one/vibeflow/releases/download/v$VERSION/VibeFlow.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
