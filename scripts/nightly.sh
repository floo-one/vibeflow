#!/bin/zsh
# Fallback only: GitHub Actions (.github/workflows/ship.yml) publishes the nightlies since #34.
# Install this only while Actions cannot; never both at once, they would race on the release.
#
# Keep the "nightly" pre-release at the newest main, built, signed and notarized on this Mac,
# so a Maagical with Settings > General > Updates, Channel "Nightly", installs every new main.
# A LaunchAgent runs it every 30 minutes; it builds only when origin/main moved and CI passed
# on that commit, in its own clone under ~/Library/Application Support (never ~/Documents, which
# macOS keeps from background jobs, nor ~/Library/Caches, which macOS and cleaner apps empty), with scripts/release.sh --nightly --publish. Keys stay in the login keychain: the Mac has
# to be on, logged in and awake (it catches up after sleep).
#
# Usage:  scripts/nightly.sh              check once, build and publish if main moved
#         scripts/nightly.sh --install    run every 30 minutes (LaunchAgent), from this repo
#         scripts/nightly.sh --uninstall  stop running it
#         scripts/nightly.sh --status     LaunchAgent, last published commit, recent log
#         scripts/nightly.sh --retry      check once, also when this main failed before
#
# Plan: docs/designs/dev-prod-channels.md (P5).

set -euo pipefail

LABEL="one.floo.vibeflow.nightly"
STATE="$HOME/Library/Application Support/$LABEL"
# Where it lived until 2026-11-04: emptied there, the job lost its own script and stopped.
OLD_STATE="$HOME/Library/Caches/$LABEL"
SRC="$STATE/src"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/VibeFlow Nightly.log"
PUBLISHED="$STATE/published"
FAILED="$STATE/failed"
GH_REPO="floo-one/vibeflow"
# This script, absolute. Inside a zsh function $0 is the function name, so read it here.
SELF="${0:A}"

say() { print "$(date '+%F %T') $1"; }

install() {
  # Bring the clone and the published/failed marks over from ~/Library/Caches, unless a build
  # is running there right now.
  if [[ -d $OLD_STATE && ! -e $STATE ]]; then
    if kill -0 "$(cat "$OLD_STATE/lock/pid" 2>/dev/null || print 0)" 2>/dev/null; then
      print -u2 "A nightly build is running in $OLD_STATE; --install again once it is done."
      exit 1
    fi
    rm -rf "$OLD_STATE/lock"
    mkdir -p "${STATE:h}"
    mv "$OLD_STATE" "$STATE"
    print "Moved $OLD_STATE to $STATE."
  fi
  mkdir -p "$STATE" "${PLIST:h}" "${LOG:h}"
  # A copy, so checking out a new main in $SRC never rewrites the script while it runs.
  cp "$SELF" "$STATE/nightly.sh"
  # The main checkout of the repo --install runs from (also from a worktree), only for the
  # gitignored Google.xcconfig. The job itself never reads it: a LaunchAgent gets "Operation
  # not permitted" anywhere in ~/Documents.
  local REPO="$(cd "$(git -C "${SELF:h}" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
  # release.sh --publish needs it for Meetings; copied now, while Terminal can read it.
  if cp "$REPO/Config/Google.xcconfig" "$STATE/Google.xcconfig" 2>/dev/null; then :; else
    print "No $REPO/Config/Google.xcconfig: nightlies will refuse to publish until you add it and --install again."
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$STATE/nightly.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  print "Installed: checks origin/main every 30 minutes, builds in $SRC."
  print "Log: $LOG"
}

uninstall() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  print "Uninstalled. The build clone stays in $STATE; remove it with: rm -rf '$STATE'"
}

check_status() {
  if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    print "LaunchAgent: loaded ($PLIST)"
  else
    print "LaunchAgent: not installed (scripts/nightly.sh --install)"
  fi
  print "Last published: $(cat "$PUBLISHED" 2>/dev/null || print none)"
  [[ -f $FAILED ]] && print "Failed, not retried until main moves: $(cat "$FAILED") (scripts/nightly.sh --retry)"
  [[ -f $LOG ]] && { print "\nLog ($LOG):"; tail -15 "$LOG"; }
  return 0
}

run() {
  mkdir -p "$STATE"
  cd "$STATE"
  # One build at a time; a lock left by a run that died is taken over.
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    if kill -0 "$(cat "$STATE/lock/pid" 2>/dev/null || print 0)" 2>/dev/null; then
      exit 0
    fi
  fi
  print $$ > "$STATE/lock/pid"
  trap 'rm -rf "$STATE/lock"' EXIT

  [[ -e "$SRC/.git" ]] || git clone --quiet "https://github.com/$GH_REPO.git" "$SRC"
  git -C "$SRC" fetch --quiet origin main
  local sha="$(git -C "$SRC" rev-parse origin/main)"
  [[ "$(cat "$PUBLISHED" 2>/dev/null)" != "$sha" ]] || exit 0
  # A failed build is not retried every 30 minutes; the next main is, or --retry.
  [[ "$(cat "$FAILED" 2>/dev/null)" != "$sha" ]] || exit 0

  # Website-only commits change nothing in the app: mark them done without a build.
  local last="$(cat "$PUBLISHED" 2>/dev/null || true)"
  if [[ -n $last ]] && git -C "$SRC" cat-file -e "$last" 2>/dev/null; then
    local app_changes="$(git -C "$SRC" diff --name-only "$last" "$sha" -- . \
      ':(exclude)website' ':(exclude).github/workflows/website.yml')"
    if [[ -z $app_changes ]]; then
      print "$sha" > "$PUBLISHED"
      say "${sha:0:7}: website only, no nightly needed"
      exit 0
    fi
  fi

  # Every nightly installs itself on this Mac, so only commits CI built and tested.
  local ci="$(gh run list --repo "$GH_REPO" --workflow CI --commit "$sha" --json status,conclusion \
    -q '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
  case "$ci" in
    "completed success") ;;
    completed*) say "${sha:0:7}: CI did not pass ($ci); waiting for a newer main"; exit 0 ;;
    *) say "${sha:0:7}: waiting for CI (${ci:-no run yet})"; exit 0 ;;
  esac

  git -C "$SRC" checkout --quiet --detach --force "$sha"

  # Gitignored, so the clone never has it; --install keeps a copy next to this script.
  mkdir -p "$SRC/Config"
  cp "$STATE/Google.xcconfig" "$SRC/Config/Google.xcconfig" 2>/dev/null \
    || say "${sha:0:7}: no Google.xcconfig (run --install from a checkout that has one); release.sh will refuse to publish"

  say "${sha:0:7}: building the nightly"
  if ! "$SRC/scripts/release.sh" --nightly --publish; then
    print "$sha" > "$FAILED"
    say "${sha:0:7}: FAILED (see above); scripts/nightly.sh --retry tries again"
    exit 1
  fi
  rm -f "$FAILED"
  print "$sha" > "$PUBLISHED"
  say "${sha:0:7}: published"
}

case "${1:-}" in
  --install) install ;;
  --uninstall) uninstall ;;
  --status) check_status ;;
  --retry) rm -f "$FAILED"; run ;;
  "") run ;;
  *) print -u2 "Unknown option: $1"; exit 2 ;;
esac
