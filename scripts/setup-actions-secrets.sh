#!/bin/zsh
# Put the release keys into the GitHub environment "release", which .github/workflows/ship.yml
# uses to sign, notarize and publish. Run it yourself in a terminal: it reads from your login
# keychain and asks for what only you can make, and the values go straight from here to gh.
# Exported files live in a temporary folder that is deleted at the end.
#
# Usage:  scripts/setup-actions-secrets.sh            all secrets
#         scripts/setup-actions-secrets.sh sentry     only some: google sentry sparkle cert notary
#
# docs/DEVELOPMENT.md "Publishing from GitHub Actions" explains each one.

set -euo pipefail

REPO_SLUG="floo-one/vibeflow"
ENV_NAME="release"
SELF_DIR="${0:A:h}"
# The main checkout (also when this runs from a worktree): it has Config/Google.xcconfig and
# the Sparkle tools from earlier builds.
MAIN="$(cd "$(git -C "$SELF_DIR" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step() { print -P "\n%B==> $1%b"; }
put() { gh secret set "$1" --repo "$REPO_SLUG" --env "$ENV_NAME"; print "   $1 set."; }
ask() { local v; read -r "v?   $1: "; print -r -- "$v"; }

google() {
  step "GOOGLE_XCCONFIG (Meetings sign-in)"
  local f="$MAIN/Config/Google.xcconfig"
  [[ -f $f ]] || { print "   No $f; skipped."; return; }
  put GOOGLE_XCCONFIG < "$f"
}

sentry() {
  step "SENTRY_AUTH_TOKEN (debug symbols)"
  security find-generic-password -a vibeflow -s sentry-auth-token -w | put SENTRY_AUTH_TOKEN
}

sparkle() {
  step "SPARKLE_PRIVATE_KEY (update signatures; macOS may ask for Keychain access: Allow)"
  local bin="$MAIN/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
  if [[ ! -x $bin/generate_keys ]]; then
    print "   Fetching Sparkle's tools…"
    (cd "$MAIN" && xcodegen generate >/dev/null && xcodebuild -resolvePackageDependencies \
      -project VibeFlow.xcodeproj -scheme VibeFlow -derivedDataPath build/DerivedData -quiet)
  fi
  "$bin/generate_keys" --account vibeflow -x "$TMP/sparkle.key" >/dev/null
  local want="$(sed -nE 's/^ *SUPublicEDKey: *"?([^" ]+)"?.*/\1/p' "$MAIN/project.yml" | head -1)"
  local got="$(swift "$SELF_DIR/sparkle-public-key.swift" "$TMP/sparkle.key")"
  [[ $got == "$want" ]] || { print -u2 "   The exported key does not match SUPublicEDKey; not uploaded."; exit 1; }
  put SPARKLE_PRIVATE_KEY < "$TMP/sparkle.key"
}

cert() {
  step "DEVELOPER_ID_P12 + DEVELOPER_ID_P12_PASSWORD (code signing)"
  print "   Keychain Access opens. Under login > My Certificates, right-click"
  print "   \"Developer ID Application: …\" > Export…, format .p12, save it anywhere, and pick a"
  print "   new password for the file (not your Mac password)."
  open -a "Keychain Access"
  local p12="$(ask "Drag the .p12 here and press Return")"
  p12="${${p12## }%% }"; p12="${(Q)p12}"
  [[ -f $p12 ]] || { print -u2 "   No file at $p12"; exit 1; }
  local pw; read -rs "pw?   The password you gave the .p12: "; print
  # Open it in a throwaway keychain first: Keychain Access exports the row that was selected,
  # not the one right-clicked, so an "Apple Development" certificate slips in easily.
  local kc="$TMP/check.keychain-db"
  security create-keychain -p check "$kc" >/dev/null
  security import "$p12" -k "$kc" -P "$pw" -f pkcs12 >/dev/null 2>&1 \
    || { security delete-keychain "$kc"; print -u2 "   Could not open the .p12 (wrong password?)."; exit 1; }
  local found="$(security find-identity -p codesigning "$kc" | grep -oE '"[^"]+"' | sort -u)"
  security delete-keychain "$kc"
  if ! print -r -- "$found" | grep -q '"Developer ID Application'; then
    print -u2 "   This .p12 holds ${found:-no signing identity}, not \"Developer ID Application: …\"."
    print -u2 "   In Keychain Access, first click the Developer ID row once so it alone is selected,"
    print -u2 "   then right-click it > Export. Nothing was uploaded."
    rm -f "$p12"; exit 1
  fi
  print "   Holds: ${(j:, :)${(f)found}}"
  base64 -i "$p12" | put DEVELOPER_ID_P12
  print -rn -- "$pw" | put DEVELOPER_ID_P12_PASSWORD
  rm -f "$p12"; print "   Deleted $p12."
}

notary() {
  step "ASC_KEY_P8 + ASC_KEY_ID + ASC_ISSUER_ID (notarization)"
  print "   App Store Connect opens at Users and Access > Integrations > App Store Connect API."
  print "   Team Keys > + : name \"VibeFlow notarize\", access Developer, Generate, then Download"
  print "   the .p8 (Apple lets you download it only once). The Issuer ID is above the table."
  open "https://appstoreconnect.apple.com/access/integrations/api"
  local p8="$(ask "Drag AuthKey_….p8 here and press Return")"
  p8="${${p8## }%% }"; p8="${(Q)p8}"
  [[ -f $p8 ]] || { print -u2 "   No file at $p8"; exit 1; }
  local id="${${p8:t:r}#AuthKey_}"
  [[ $id =~ '^[A-Z0-9]{10}$' ]] || id="$(ask "Key ID")"
  local issuer="$(ask "Issuer ID")"
  print "   Checking the key with Apple…"
  xcrun notarytool history --key "$p8" --key-id "$id" --issuer "$issuer" >/dev/null \
    || { print -u2 "   notarytool rejected that key, key id or issuer id."; exit 1; }
  put ASC_KEY_P8 < "$p8"
  print -rn -- "$id" | put ASC_KEY_ID
  print -rn -- "$issuer" | put ASC_ISSUER_ID
  print "   Keep $p8 in your password manager, then delete it."
}

command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { print -u2 "gh is not logged in (gh auth login)"; exit 1; }
parts=("$@"); (( ${#parts} )) || parts=(google sentry sparkle cert notary)
for p in $parts; do
  case $p in
    google|sentry|sparkle|cert|notary) $p ;;
    *) print -u2 "Unknown: $p (google sentry sparkle cert notary)"; exit 2 ;;
  esac
done

step "Secrets in the \"$ENV_NAME\" environment"
gh secret list --repo "$REPO_SLUG" --env "$ENV_NAME"
