#!/bin/zsh
# Build a notarized Maagical release: Developer ID signed app, stapled, in a DMG with its
# Sparkle update feed (appcast.xml), and with --publish also tagged and uploaded to GitHub
# Releases, where installed copies of Maagical find it.
#
# One-time setup (see docs/DEVELOPMENT.md "Release"):
#   xcrun notarytool store-credentials VibeFlowNotary --team-id X7UXDLS9F7
#   the Sparkle signing key in the login keychain, account "vibeflow" (generate_keys)
#   brew install getsentry/tools/sentry-cli, and a Sentry organization token for floo-one in
#   the login keychain: security add-generic-password -U -a vibeflow -s sentry-auth-token -w "$(pbpaste)"
#
# In GitHub Actions (.github/workflows/ship.yml) the same keys come from the environment
# instead: NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID (App Store Connect API key),
# SPARKLE_KEY_FILE (generate_keys -x), SENTRY_AUTH_TOKEN, and the Developer ID certificate in
# a keychain the workflow sets up.
#
# Usage:  scripts/release.sh                 build build/release/Maagical-<version>.dmg
#         scripts/release.sh --publish       same, from a clean main that matches origin, then
#                                            tag v<version> and create the GitHub release
#         scripts/release.sh --no-notarize   stop after the signed export (no credentials)
#         scripts/release.sh --nightly [--publish]
#                                            a build of origin/main for the Nightly update
#                                            channel, uploaded to the rolling
#                                            "nightly" pre-release (scripts/nightly.sh runs it)
#
# Before --publish: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml and
# give CHANGELOG.md a "## <version>" section; its text becomes the release notes.
#
# A nightly is version <MARKETING_VERSION>-nightly.<commits on main>, e.g. 1.4.0-nightly.52, and
# build <CURRENT_PROJECT_VERSION>.<commits on main>, e.g. 3.52: above
# release 3, which it follows, and below release 4, which replaces it. Sparkle compares the
# parts as numbers, so both channels only ever move up.

set -euo pipefail

PROFILE="${VIBEFLOW_NOTARY_PROFILE:-VibeFlowNotary}"
# notarytool credentials: an App Store Connect API key when one is set (CI), else the profile.
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  NOTARY_AUTH=(--key "${NOTARY_KEY_PATH:?}" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER_ID:?}")
else
  NOTARY_AUTH=(--keychain-profile "$PROFILE")
fi
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"
IN_CI="${GITHUB_ACTIONS:-}"
SENTRY_ORG=floo-one
SENTRY_PROJECT=vibeflow
NOTARIZE=1
PUBLISH=0
NIGHTLY=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --publish) PUBLISH=1 ;;
    --nightly) NIGHTLY=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="build/release"
ARCHIVE="$OUT/Maagical.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Maagical.app"

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "error: $1"; exit 1; }

VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[[ -n "$VERSION" ]] || fail "no MARKETING_VERSION in project.yml"
TAG="v$VERSION"
PROJECT_BUILD="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
UPDATE_KEY="$(sed -nE 's/^ *SUPublicEDKey: *"?([^" ]+)"?.*/\1/p' project.yml | head -1)"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ $NIGHTLY -eq 1 ]]; then
  COMMIT="$(git rev-parse --short HEAD)"
  COUNT="$(git rev-list --count HEAD)"
  NIGHTLY_BUILD="$PROJECT_BUILD.$COUNT"
  # What people see (menu, Sparkle's windows, Sentry): 1.4.0-nightly.71, never a bare 1.4.0
  # that reads like the release. The same count as the build number's second part.
  NIGHTLY_VERSION="$VERSION-nightly.$COUNT"
  LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
fi

# Changelog section "## <version>" up to the next "## " heading; for a nightly, the commits
# since the last release.
release_notes() {
  if [[ $NIGHTLY -eq 1 ]]; then
    print "Built from main at $COMMIT, not a release. Changes since ${LAST_TAG:-the start}:"
    print
    git log --no-merges --format='- %s' ${LAST_TAG:+$LAST_TAG..}HEAD | head -40
    return
  fi
  awk -v v="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; next } }
    found { print }
  ' CHANGELOG.md
}

# Checks that can fail fast, before ten minutes of building and notarizing.
if [[ $NIGHTLY -eq 1 ]]; then
  step "Check that $COMMIT is origin/main"
  [[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
  git fetch --quiet origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "HEAD is not origin/main; a nightly is always a build of main"
  if [[ $PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null || fail "gh is not installed"
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
  fi
elif [[ $PUBLISH -eq 1 ]]; then
  step "Check that $TAG can be published"
  command -v gh >/dev/null || fail "gh is not installed"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
  # Actions checks out the commit detached; the origin/main check below covers it there.
  [[ -n "$IN_CI" || "$(git branch --show-current)" == "main" ]] || fail "releases are cut from main; this is $(git branch --show-current)"
  [[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
  git fetch --quiet origin main --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main does not match origin/main; pull or push first"
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists; bump MARKETING_VERSION in project.yml"
  [[ -n "$(release_notes | tr -d '[:space:]')" ]] || fail "CHANGELOG.md has no '## $VERSION' section"
  # Sparkle offers an update only when its build number is higher than the installed one.
  LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  LAST_BUILD="$([[ -n "$LAST_TAG" ]] && git show "$LAST_TAG:project.yml" | sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' | head -1 || true)"
  if [[ -n "$LAST_BUILD" ]]; then
    (( PROJECT_BUILD > LAST_BUILD )) || fail "CURRENT_PROJECT_VERSION $PROJECT_BUILD is not above $LAST_BUILD ($LAST_TAG); installed copies would not update"
  fi
fi

# Meetings needs the Google client from the gitignored Config/Google.xcconfig (see
# docs/DEVELOPMENT.md "Google Calendar"); without it the release builds but cannot sign in.
if ! grep -qE '^GOOGLE_CLIENT_ID *= *[^ ]+' Config/Google.xcconfig 2>/dev/null \
   || ! grep -qE '^GOOGLE_CLIENT_SECRET *= *[^ ]+' Config/Google.xcconfig 2>/dev/null; then
  [[ $PUBLISH -eq 1 ]] && fail "Config/Google.xcconfig lacks the client ID or secret; Meetings would say 'Not configured in this build'"
  print -u2 "warning: no Google client in Config/Google.xcconfig; this build's Meetings tab will say 'Not configured in this build'"
fi

# Crash reports are readable only with the build's dSYMs, and the next run deletes this
# build's archive, so symbols go to Sentry in the same run (docs/designs/feedback.md, D10).
# A published build must have them; a local one only warns.
SENTRY_TOKEN="${SENTRY_AUTH_TOKEN:-$(security find-generic-password -a vibeflow -s sentry-auth-token -w 2>/dev/null || true)}"
if ! command -v sentry-cli >/dev/null || [[ -z "$SENTRY_TOKEN" ]]; then
  [[ $PUBLISH -eq 1 ]] && fail "no sentry-cli or no Sentry token (keychain: account vibeflow, service sentry-auth-token); crashes from this build would be unreadable"
  print -u2 "warning: no sentry-cli or Sentry token; this build's debug symbols will not be uploaded"
  SENTRY_TOKEN=""
fi

if [[ $NOTARIZE -eq 1 && -n "${NOTARY_KEY_ID:-}" ]] && ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
  fail "notarytool does not accept the App Store Connect API key (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID)"
fi
if [[ $NOTARIZE -eq 1 && -z "${NOTARY_KEY_ID:-}" ]] && ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
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

if [[ $NOTARIZE -eq 1 ]]; then
  # A release signed with another key would never install anywhere, so check before building.
  step "Check the Sparkle signing key"
  xcodebuild -resolvePackageDependencies -project Maagical.xcodeproj -scheme Maagical \
    -derivedDataPath build/DerivedData -quiet
  if [[ -n "$SPARKLE_KEY_FILE" ]]; then
    [[ "$(swift scripts/sparkle-public-key.swift "$SPARKLE_KEY_FILE")" == "$UPDATE_KEY" ]] \
      || fail "SPARKLE_KEY_FILE does not match SUPublicEDKey in project.yml"
  else
    [[ "$("$SPARKLE_BIN/generate_keys" --account vibeflow -p 2>/dev/null)" == "$UPDATE_KEY" ]] \
      || fail "the login keychain has no Sparkle key (account vibeflow) matching SUPublicEDKey in project.yml; see docs/DEVELOPMENT.md, Release"
  fi
fi

# A nightly carries its build number and, like Maagical Dev, the commit it came from
# (BuildStamp), which the menu shows next to the version.
OVERRIDES=()
if [[ $NIGHTLY -eq 1 ]]; then
  OVERRIDES=(MARKETING_VERSION="$NIGHTLY_VERSION" CURRENT_PROJECT_VERSION="$NIGHTLY_BUILD" VF_GIT_BRANCH=main VF_GIT_COMMIT="$COMMIT"
    VF_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)")
fi

step "Archive (Release)"
xcodebuild -project Maagical.xcodeproj -scheme Maagical -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -archivePath "$ARCHIVE" \
  archive -quiet "${OVERRIDES[@]}"

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" -quiet

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EXPECTED="$VERSION"; [[ $NIGHTLY -eq 1 ]] && EXPECTED="$NIGHTLY_VERSION"
[[ "$BUILT" == "$EXPECTED" ]] || fail "built version $BUILT is not $EXPECTED"
if [[ $NIGHTLY -eq 1 ]]; then
  [[ "$BUILD" == "$NIGHTLY_BUILD" ]] || fail "built build number $BUILD is not $NIGHTLY_BUILD"
fi
print "Maagical $VERSION ($BUILD)"

step "Verify the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority=Developer ID Application|TeamIdentifier=|Timestamp=)'

if [[ -n "$SENTRY_TOKEN" ]]; then
  step "Upload debug symbols to Sentry"
  SENTRY_AUTH_TOKEN="$SENTRY_TOKEN" sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    "$ARCHIVE/dSYMs"
fi

if [[ $NOTARIZE -eq 0 ]]; then
  print "Signed app at $APP (not notarized: --no-notarize)."
  exit 0
fi

step "Notarize the app"
ZIP="$OUT/Maagical-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

step "Build the DMG"
if [[ $NIGHTLY -eq 1 ]]; then DMG="$OUT/Maagical-$NIGHTLY_BUILD.dmg"; else DMG="$OUT/Maagical-$VERSION.dmg"; fi
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Maagical.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Maagical" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

step "Sign, notarize and staple the DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"

step "Gatekeeper check"
spctl -a -vv -t exec "$APP" 2>&1
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1

step "Sign the DMG for Sparkle and write the update feed"
NOTES="$OUT/notes.md"
release_notes > "$NOTES"
APPCAST="$OUT/appcast.xml"
if [[ $NIGHTLY -eq 1 ]]; then
  # Each nightly DMG keeps its own name, so the feed never points at a file that was
  # replaced under it.
  scripts/write-appcast.sh --url "https://github.com/floo-one/vibeflow/releases/download/nightly/${DMG:t}" \
    "$DMG" "$NIGHTLY_VERSION" "$BUILD" "$NOTES" ${SPARKLE_KEY_FILE:+"$SPARKLE_KEY_FILE"} > "$APPCAST"
else
  scripts/write-appcast.sh "$DMG" "$VERSION" "$BUILD" "$NOTES" ${SPARKLE_KEY_FILE:+"$SPARKLE_KEY_FILE"} > "$APPCAST"
fi
xmllint --noout "$APPCAST"

print
print "Release ready: $DMG"

if [[ $NIGHTLY -eq 1 && $PUBLISH -eq 1 ]]; then
  step "Publish the nightly $NIGHTLY_VERSION ($COMMIT) to GitHub"
  # One pre-release, created once and never --latest, so .../releases/latest stays the last
  # release. Its tag is not moved (a moved tag breaks everyone's git fetch --tags); the title
  # and notes name the commit. DMG first, then the feed that points at it, then old DMGs.
  # The Ship workflow reads the commit back from the end of this title.
  TITLE="Maagical $NIGHTLY_VERSION ($COMMIT)"
  if ! gh release view nightly >/dev/null 2>&1; then
    gh release create nightly --target main --prerelease --latest=false \
      --title "$TITLE" --notes-file "$NOTES"
  fi
  gh release upload nightly "$DMG#$TITLE (DMG)" --clobber
  gh release upload nightly "$APPCAST#Update feed (Sparkle, nightly)" --clobber
  gh release edit nightly --title "$TITLE" --notes-file "$NOTES" --prerelease
  for old in $(gh release view nightly --json assets -q '.assets[].name' | grep -E '^(VibeFlow|Maagical)-.*\.dmg$'); do
    [[ "$old" == "${DMG:t}" ]] || gh release delete-asset nightly "$old" --yes
  done
  print "Published: $(gh release view nightly --json url -q .url)"
elif [[ $PUBLISH -eq 1 ]]; then
  step "Publish $TAG to GitHub"
  git tag -a "$TAG" -m "Maagical $VERSION"
  git push origin "$TAG"
  # Uploaded as Maagical.dmg and appcast.xml so .../releases/latest/download/<name> always
  # serves the newest: the README links the DMG, installed copies read the feed (SUFeedURL).
  cp "$DMG" "$OUT/Maagical.dmg"
  # Back to Stable in the 1.5 nightlies (StableInstaller) still fetches VibeFlow.dmg from
  # .../latest/download, so the same DMG goes up under the old name once more. Drop this
  # with the first release after 1.6.
  cp "$DMG" "$OUT/VibeFlow.dmg"
  gh release create "$TAG" "$OUT/Maagical.dmg#Maagical $VERSION (DMG)" "$OUT/VibeFlow.dmg#Maagical $VERSION (DMG, old name)" \
    "$APPCAST#Update feed (Sparkle)" \
    --title "Maagical $VERSION" --notes-file "$NOTES" --verify-tag --latest
  print "Published: $(gh release view "$TAG" --json url -q .url)"
fi

# The DMG is the release. A launchable Maagical left in build/ could answer to
# one.floo.vibeflow instead of /Applications/Maagical.app; the archive stays for its dSYMs.
step "Drop the exported app"
rm -rf "$APP"
[[ -n "$IN_CI" ]] || "$ROOT/scripts/dev.sh" --clean || print -u2 "warning: scripts/dev.sh --clean failed"
