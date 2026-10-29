#!/bin/zsh
# One VibeFlow Dev to open, quit and grant permissions to, whichever worktree built it: this
# script installs the Debug build of this checkout to ~/Applications/VibeFlow Dev.app and runs
# it from there. The release, VibeFlow, lives in /Applications and is never touched here.
# Plan: docs/designs/dev-prod-channels.md (P2).
#
# Usage:  scripts/dev.sh            build Debug, quit the running VibeFlow Dev (from any path),
#                                   install it to ~/Applications and open it
#         scripts/dev.sh --doctor   list every VibeFlow app: the two homes, what is running,
#                                   stray copies and stale Launch Services entries
#         scripts/dev.sh --clean    delete leftover builds with the release bundle id from this
#                                   repo's build folders and make Launch Services forget every
#                                   VibeFlow outside the two homes

set -euo pipefail

PROD_ID="one.floo.vibeflow"
DEV_ID="one.floo.vibeflow.dev"
PROD_APP="/Applications/VibeFlow.app"
DEV_APP="$HOME/Applications/VibeFlow Dev.app"
RELEASE_DMG="https://github.com/floo-one/vibeflow/releases/latest/download/VibeFlow.dmg"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

MODE=run
case "${1:-}" in
  --doctor) MODE=doctor ;;
  --clean) MODE=clean ;;
  "") ;;
  *) print -u2 "Unknown option: $1"; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "error: $1"; exit 1; }
info() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
version() { print -r -- "$(info "$1" CFBundleShortVersionString) ($(info "$1" CFBundleVersion))"; }
short() { print -r -- "${1/#$HOME/~}"; }
plural() { if (( $1 == 1 )); then print -r -- "$1 $2"; else print -r -- "$1 $3"; fi; }

# The process name of every VibeFlow Dev, wherever it was launched from.
dev_pids() { pgrep -x "VibeFlow Dev" || true; }

# SIGTERM quits VibeFlow like its Quit menu item (AppDelegate); a copy that hangs is killed.
quit_dev() {
  local pids=(${(f)"$(dev_pids)"})
  (( ${#pids} )) || return 0
  kill -TERM $pids 2>/dev/null || true
  local i
  for i in {1..50}; do
    [[ -z "$(dev_pids)" ]] && return 0
    sleep 0.1
  done
  print -u2 "VibeFlow Dev did not quit within 5 s; killing it"
  kill -KILL ${(f)"$(dev_pids)"} 2>/dev/null || true
}

# Every VibeFlow Launch Services knows, gone or not, plus every one on disk where they collect:
# /Applications, ~/Applications and the build folders of this repo's checkouts (main and every
# worktree). Sets APPS, WORKTREES and REGISTERED (path -> number of Launch Services records;
# one path can have several, and lsregister -u drops one per call).
collect() {
  typeset -ga APPS WORKTREES
  typeset -gA REGISTERED
  WORKTREES=(${(f)"$(git worktree list --porcelain | sed -n 's/^worktree //p')"})
  local registered p wt
  registered="$($LSREGISTER -dump 2>/dev/null \
    | sed -nE 's#^path: +(.*/VibeFlow[^/]*\.app) \(0x[0-9a-f]+\)$#\1#p')"
  for p in ${(f)registered}; do REGISTERED[$p]=$(( ${REGISTERED[$p]:-0} + 1 )); done
  APPS=(${(f)"$({
    print -r -- "$registered"
    print -rl -- /Applications/VibeFlow*.app(N) "$HOME"/Applications/VibeFlow*.app(N)
    for wt in $WORKTREES; do
      if [[ -d "$wt/build" ]]; then find "$wt/build" -type d -name 'VibeFlow*.app' -prune -print 2>/dev/null; fi
    done
  } | sed '/^$/d' | sort -u)"})
}

# What a VibeFlow outside the two homes is:
#   archive     the release archive, kept for its dSYMs
#   dev-build   a Debug build in some checkout (scripts/dev.sh installs it)
#   stray       release bundle id, in a checkout that now builds VibeFlow Dev, so nothing
#               rebuilds it: --clean deletes it (in the Trash it would stay registered)
#   old-branch  release bundle id: the Debug build of a branch from before VibeFlow Dev
#   elsewhere   release bundle id, outside this repo
#   other       something else named VibeFlow
kind() {
  local wt
  if [[ $1 == *.xcarchive/* ]]; then print archive; return; fi
  if [[ $2 == "$DEV_ID" ]]; then print dev-build; return; fi
  if [[ $2 != "$PROD_ID" ]]; then print other; return; fi
  for wt in $WORKTREES; do
    if [[ $1 == "$wt"/build/* ]]; then
      if grep -qF "$DEV_ID" "$wt/project.yml" 2>/dev/null; then print stray; else print old-branch; fi
      return
    fi
  done
  print elsewhere
}

is_home() { [[ -d $1 ]] && [[ $1 == "$PROD_APP" || $1 == "$DEV_APP" ]]; }

home_line() {  # name path bundle-id
  local note="not installed"
  if [[ -d $2 ]]; then
    note="$(version "$2")"
    if [[ "$(info "$2" CFBundleIdentifier)" != "$3" ]]; then note="$note, wrong bundle id"; fi
  fi
  printf "  %-13s %-34s %s\n" "$1" "$(short "$2")" "$note"
}

run() {
  local branch=${$(git branch --show-current):-detached}
  local commit=$(git rev-parse --short HEAD)
  local built="$ROOT/build/DerivedData/Build/Products/Debug/VibeFlow Dev.app"
  local buildlog="$ROOT/build/dev-build.log"

  step "Build VibeFlow Dev from $branch ($commit)"
  xcodegen generate >/dev/null
  mkdir -p "${buildlog:h}"
  if ! xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug \
      -derivedDataPath build/DerivedData build -quiet >"$buildlog" 2>&1; then
    grep -E "error:" "$buildlog" | sort -u >&2 || true
    fail "build failed, full log in build/dev-build.log. errSecInternalComponent at CodeSign means a locked keychain: security unlock-keychain ~/Library/Keychains/login.keychain-db"
  fi
  [[ "$(info "$built" CFBundleIdentifier)" == "$DEV_ID" ]] || fail "$built is not $DEV_ID"

  step "Quit the running VibeFlow Dev"
  quit_dev

  step "Install to $(short "$DEV_APP")"
  mkdir -p "${DEV_APP:h}"
  rm -rf "$DEV_APP.new"
  ditto "$built" "$DEV_APP.new"
  rm -rf "$DEV_APP"
  mv "$DEV_APP.new" "$DEV_APP"
  # Only the installed copy answers to one.floo.vibeflow.dev: the build output leaves Launch
  # Services, so nothing opens it by accident.
  $LSREGISTER -u "$built" 2>/dev/null || true
  $LSREGISTER -f "$DEV_APP"

  open "$DEV_APP"
  print "VibeFlow Dev $(version "$DEV_APP") from $branch ($commit) is running."
  # VibeFlow reads the shared API keys at launch; a Keychain dialog holds it until answered.
  sleep 2
  if pgrep -x SecurityAgent >/dev/null; then
    print "A Keychain dialog may be waiting: VibeFlow Dev shows no menu bar icon until it is answered."
    print "Enter your login password and click Always Allow, so later builds do not ask again."
  fi
}

doctor() {
  collect
  local p id k reg line pid exe running=0 listed=0 gone=0 strays=0 elsewhere=0
  local -a old_branches

  print -P "%BHomes%b"
  home_line "VibeFlow" "$PROD_APP" "$PROD_ID"
  home_line "VibeFlow Dev" "$DEV_APP" "$DEV_ID"

  print -P "\n%BRunning%b"
  for line in ${(f)"$(ps -axo pid=,comm= | grep -E '/VibeFlow[^/]*\.app/Contents/MacOS/' || true)"}; do
    read -r pid exe <<< "$line"
    printf "  pid %-8s %s\n" "$pid" "$(short "${exe%%/Contents/MacOS/*}")"
    (( ++running ))
  done
  (( running )) || print "  none"

  print -P "\n%BOther copies%b"
  for p in $APPS; do
    if is_home "$p"; then continue; fi
    if (( ${+REGISTERED[$p]} )); then reg="registered"; else reg=""; fi
    if [[ ! -d $p ]]; then (( ++gone )); continue; fi
    id="$(info "$p" CFBundleIdentifier)"
    k="$(kind "$p" "$id")"
    case $k in
      stray) (( ++strays )) ;;
      old-branch) old_branches+=("${${p%%/build/*}:t}") ;;
      elsewhere) (( ++elsewhere )) ;;
    esac
    printf "  %-10s %-9s %-22s %s %s\n" "$k" "$(version "$p")" "$id" "$(short "$p")" "$reg"
    (( ++listed ))
  done
  if (( gone )); then
    print "  gone       $(plural $gone "Launch Services entry points" "Launch Services entries point") at deleted apps"
  fi
  (( listed + gone )) || print "  none"

  print -P "\n%BNext%b"
  local todo=0
  if [[ ! -d $PROD_APP ]]; then
    print "  Install the release: download $RELEASE_DMG and drag VibeFlow to Applications."
    todo=1
  fi
  if [[ ! -d $DEV_APP ]]; then
    print "  Install VibeFlow Dev: scripts/dev.sh"
    todo=1
  fi
  if (( strays + gone )); then
    print "  scripts/dev.sh --clean: $(plural $strays "stray copy" "stray copies") to delete, $(plural $gone "dead Launch Services entry" "dead Launch Services entries") to forget."
    todo=1
  fi
  if (( ${#old_branches} )); then
    print "  Branches from before VibeFlow Dev build their Debug app with the release bundle id; merge main into: ${(j:, :)${(@u)old_branches}}"
    todo=1
  fi
  if (( elsewhere )); then
    print "  $(plural $elsewhere "copy with the release bundle id is" "copies with the release bundle id are") outside this repo; remove by hand."
    todo=1
  fi
  if (( strays + ${#old_branches} + elsewhere )); then
    print "  A copy with the release bundle id can own its Accessibility entry: if VibeFlow says Accessibility"
    print "  is off while System Settings shows it on, remove VibeFlow there with the minus button and grant it again."
  fi
  (( todo )) || print "  Nothing to do."
}

clean() {
  collect
  local p k i n deleted=0 forgot=0
  for p in $APPS; do
    if is_home "$p"; then continue; fi
    # Spotlight keeps an app that still exists registered, so this sticks for deleted apps
    # and build outputs Spotlight has not seen yet.
    if (( ${+REGISTERED[$p]} )); then
      n=0
      for i in {1..${REGISTERED[$p]}}; do
        if $LSREGISTER -u "$p" 2>/dev/null; then (( ++n )); fi
      done
      if (( n )); then (( ++forgot )); fi
    fi
    [[ -d $p ]] || continue
    k="$(kind "$p" "$(info "$p" CFBundleIdentifier)")"
    case $k in
      stray) rm -rf "$p"; print "Deleted $(short "$p")"; (( ++deleted )) ;;
      old-branch|elsewhere) print "Left alone ($k): $(short "$p")" ;;
    esac
  done
  print "$(plural $deleted "stray copy" "stray copies") deleted, $(plural $forgot "Launch Services entry" "Launch Services entries") forgotten."
}

$MODE
