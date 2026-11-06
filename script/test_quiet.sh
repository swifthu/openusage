#!/usr/bin/env bash
# Runs the test suite without letting it take the keyboard. The tests host real windows in the
# xctest process on this Mac while its owner works in another app; this script watches the frontmost
# app throughout the run and fails when a test process ever came to the front. It also notes when the
# frontmost app at the end is not the one at the start, which is the owner switching apps as often as
# not, so that alone fails nothing. It is the only way to run tests on a Mac someone is using.
# Arguments go to `swift test` (for example --filter DashboardSectionTests).
#
# Usage: script/test_quiet.sh [swift test arguments]
set -uo pipefail

front_app() {
  # macOS 27 returns a full app record even for -only name.
  lsappinfo info -only name "$(lsappinfo front)" | sed -nE \
    -e 's/^"LSDisplayName"="(.*)"$/\1/p' \
    -e 's/^"(.*)" ASN:[^ ]+: \(in front\).*$/\1/p'
}

before="$(front_app)"
[ -n "$before" ] || { echo "test_quiet: could not read the front app" >&2; exit 1; }
seen="$(mktemp -t test_quiet)"
is_test_process() {
  case "$1" in
    xctest|swift-*) return 0 ;;
    *) return 1 ;;
  esac
}
(
  trap 'kill $! 2>/dev/null; exit 0' TERM
  while true; do
    app="$(front_app)"
    is_test_process "$app" && echo "$app" >> "$seen"
    sleep 0.2 & wait $!
  done
) 2>/dev/null &
watcher=$!
disown "$watcher"
trap 'kill "$watcher" 2>/dev/null; rm -f "$seen"' EXIT

# SwiftPM's scratch directory — the build database, the index store, the module cache and the
# checked-out dependencies. On a checkout that lives on a network volume those files get corrupted
# (stale NFS handles, module maps truncated mid-write) and the build fails at random, so the
# scratch directory stays on the local disk. The other scripts (build_and_run.sh, release.sh,
# embed_sparkle.sh) use the same default.
BUILD_SCRATCH="${SWIFT_SCRATCH_PATH:-$HOME/build}"

# An explicit --scratch-path among the arguments wins over the default.
scratch_given=no
for arg in "$@"; do
  case "$arg" in
    --scratch-path|--scratch-path=*) scratch_given=yes ;;
  esac
done
if [ "$scratch_given" = no ]; then
  set -- --scratch-path "$BUILD_SCRATCH" "$@"
fi

# The Swift Build layout links the test bundle against PackageFrameworks/ but builds Sparkle one level up.
frameworks="$BUILD_SCRATCH/out/Products/Debug/PackageFrameworks"
mkdir -p "$frameworks"
[ -L "$frameworks/Sparkle.framework" ] || ln -s ../Sparkle.framework "$frameworks/Sparkle.framework"

nice -n 19 swift test -j 2 "$@"
status=$?

after="$(front_app)"
if [ -s "$seen" ] || is_test_process "$after"; then
  echo "test_quiet: the suite took the keyboard: $(sort -u "$seen" | tr '\n' ' ')came to the front during the run" >&2
  exit 2
fi
if [ "$before" != "$after" ]; then
  echo "test_quiet: the frontmost app changed from '$before' to '$after' during the run, with no test process in front"
else
  echo "test_quiet: the frontmost app stayed '$before'"
fi
exit $status
