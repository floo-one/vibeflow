#!/bin/zsh
# Build a notarized VibeFlow release: Developer ID signed app, stapled, in a DMG, and with
# --publish also tagged and uploaded to GitHub Releases.
#
# One-time setup (see README "Build a release"):
#   xcrun notarytool store-credentials VibeFlowNotary --team-id X7UXDLS9F7
#
# Usage:  scripts/release.sh                 build build/release/VibeFlow-<version>.dmg
#         scripts/release.sh --publish       same, from a clean main that matches origin, then
#                                            tag v<version> and create the GitHub release
#         scripts/release.sh --no-notarize   stop after the signed export (no credentials)
#
# Before --publish: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml and
# give CHANGELOG.md a "## <version>" section; its text becomes the release notes.

set -euo pipefail

PROFILE="${VIBEFLOW_NOTARY_PROFILE:-VibeFlowNotary}"
NOTARIZE=1
PUBLISH=0
case "${1:-}" in
  --no-notarize) NOTARIZE=0 ;;
  --publish) PUBLISH=1 ;;
  "") ;;
  *) print -u2 "Unknown option: $1"; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="build/release"
ARCHIVE="$OUT/VibeFlow.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/VibeFlow.app"

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "error: $1"; exit 1; }

VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[[ -n "$VERSION" ]] || fail "no MARKETING_VERSION in project.yml"
TAG="v$VERSION"

# Changelog section "## <version>" up to the next "## " heading.
release_notes() {
  awk -v v="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; next } }
    found { print }
  ' CHANGELOG.md
}

# Checks that can fail fast, before ten minutes of building and notarizing.
if [[ $PUBLISH -eq 1 ]]; then
  step "Check that $TAG can be published"
  command -v gh >/dev/null || fail "gh is not installed"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
  [[ "$(git branch --show-current)" == "main" ]] || fail "releases are cut from main; this is $(git branch --show-current)"
  [[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
  git fetch --quiet origin main --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main does not match origin/main; pull or push first"
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists; bump MARKETING_VERSION in project.yml"
  [[ -n "$(release_notes | tr -d '[:space:]')" ]] || fail "CHANGELOG.md has no '## $VERSION' section"
fi

if [[ $NOTARIZE -eq 1 ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  print -u2 "No notarytool keychain profile '$PROFILE'. Create it once with:"
  print -u2 "  xcrun notarytool store-credentials $PROFILE --team-id X7UXDLS9F7"
  print -u2 "(Apple Account email of the developer team + an app-specific password from account.apple.com)"
  exit 1
fi

step "Clean $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Generate the Xcode project"
xcodegen generate >/dev/null

step "Archive (Release)"
xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -archivePath "$ARCHIVE" \
  archive -quiet

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" -quiet

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || fail "built version $BUILT does not match project.yml $VERSION"
print "VibeFlow $VERSION ($BUILD)"

step "Verify the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority=Developer ID Application|TeamIdentifier=|Timestamp=)'

if [[ $NOTARIZE -eq 0 ]]; then
  print "Signed app at $APP (not notarized: --no-notarize)."
  exit 0
fi

step "Notarize the app"
ZIP="$OUT/VibeFlow-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

step "Build the DMG"
DMG="$OUT/VibeFlow-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/VibeFlow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VibeFlow" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

step "Sign, notarize and staple the DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

step "Gatekeeper check"
spctl -a -vv -t exec "$APP" 2>&1
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1

print
print "Release ready: $DMG"

if [[ $PUBLISH -eq 1 ]]; then
  step "Publish $TAG to GitHub"
  NOTES="$OUT/notes.md"
  release_notes > "$NOTES"
  git tag -a "$TAG" -m "VibeFlow $VERSION"
  git push origin "$TAG"
  # Uploaded as VibeFlow.dmg so .../releases/latest/download/VibeFlow.dmg always works.
  cp "$DMG" "$OUT/VibeFlow.dmg"
  gh release create "$TAG" "$OUT/VibeFlow.dmg#VibeFlow $VERSION (DMG)" \
    --title "VibeFlow $VERSION" --notes-file "$NOTES" --verify-tag --latest
  print "Published: $(gh release view "$TAG" --json url -q .url)"
fi
