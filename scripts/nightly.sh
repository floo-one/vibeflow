#!/bin/zsh
# Keep the "nightly" pre-release at the newest main, built, signed and notarized on this Mac,
# so a VibeFlow with Settings > General > Updates, Channel "Nightly", installs every new main.
# A LaunchAgent runs it every 30 minutes; it builds only when origin/main moved and CI passed
# on that commit, in its own worktree (main checkout and other worktrees stay as they are),
# with scripts/release.sh --nightly --publish. Keys stay in the login keychain: the Mac has
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
STATE="$HOME/Library/Caches/$LABEL"
SRC="$STATE/src"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/VibeFlow Nightly.log"
PUBLISHED="$STATE/published"
FAILED="$STATE/failed"
GH_REPO="floo-one/vibeflow"

# The repo it builds from: set by --install in the LaunchAgent, else the repo of this script.
# Its main checkout, also from a worktree, since the build worktree hangs off that one.
REPO="${VIBEFLOW_REPO:-$(cd "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)}"

say() { print "$(date '+%F %T') $1"; }

install() {
  mkdir -p "$STATE" "${PLIST:h}" "${LOG:h}"
  # A copy, so checking out a new main in $SRC never rewrites the script while it runs.
  cp "$0" "$STATE/nightly.sh"
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
    <key>VIBEFLOW_REPO</key><string>$REPO</string>
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
  print "Installed: checks origin/main every 30 minutes, builds from $REPO."
  print "Log: $LOG"
}

uninstall() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  print "Uninstalled. The build worktree stays at $SRC; remove it with:"
  print "  git -C '$REPO' worktree remove --force '$SRC'"
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
  # One build at a time; a lock left by a run that died is taken over.
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    if kill -0 "$(cat "$STATE/lock/pid" 2>/dev/null || print 0)" 2>/dev/null; then
      exit 0
    fi
  fi
  print $$ > "$STATE/lock/pid"
  trap 'rm -rf "$STATE/lock"' EXIT

  git -C "$REPO" fetch --quiet origin main
  local sha="$(git -C "$REPO" rev-parse origin/main)"
  [[ "$(cat "$PUBLISHED" 2>/dev/null)" != "$sha" ]] || exit 0
  # A failed build is not retried every 30 minutes; the next main is, or --retry.
  [[ "$(cat "$FAILED" 2>/dev/null)" != "$sha" ]] || exit 0

  # Every nightly installs itself on this Mac, so only commits CI built and tested.
  local ci="$(gh run list --repo "$GH_REPO" --workflow CI --commit "$sha" --json status,conclusion \
    -q '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
  case "$ci" in
    "completed success") ;;
    completed*) say "${sha:0:7}: CI did not pass ($ci); waiting for a newer main"; exit 0 ;;
    *) say "${sha:0:7}: waiting for CI (${ci:-no run yet})"; exit 0 ;;
  esac

  if [[ -e "$SRC/.git" ]]; then
    git -C "$SRC" checkout --quiet --detach --force "$sha"
  else
    git -C "$REPO" worktree add --quiet --detach "$SRC" "$sha"
  fi

  # Gitignored, so the worktree never has it; release.sh --publish needs it for Meetings.
  mkdir -p "$SRC/Config"
  cp "$REPO/Config/Google.xcconfig" "$SRC/Config/Google.xcconfig" 2>/dev/null \
    || say "${sha:0:7}: no $REPO/Config/Google.xcconfig; release.sh will refuse to publish"

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
