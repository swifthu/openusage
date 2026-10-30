#!/usr/bin/env bash
set -euo pipefail

# Builds OpenUsage, stages a signed .app bundle under dist/, and launches it in place — no install
# to /Applications. The dev build:
#   - is signed with a stable Apple Development identity, so keychain/permission grants stick across
#     rebuilds (macOS keys those to the signing identity + bundle id, not the install location);
#   - uses its own bundle id (com.robinebers.openusage.dev), so it never touches the real installed
#     app's settings or keychain. To run against the real app's data instead, set BUNDLE_ID to
#     com.robinebers.openusage below;
#   - ships no Sparkle feed, so it never checks for or installs updates (test updates with a real
#     signed + notarized release build — that's the only honest way).
#
# Usage: script/build_and_run.sh [run|build|logs|verify]
# Env:   CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        CONFIG             "release" (default) or "debug"
#        SWIFT_BUILD_FLAGS  extra flags for `swift build`, e.g. a module-cache path.
#                           Word-split on purpose so several flags can be passed at once.
#        SWIFT_SCRATCH_PATH SwiftPM's scratch directory. Defaults to a folder on the local disk.

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"

# SwiftPM's scratch directory — the build database, the index store, the module cache and the
# checked-out dependencies. This checkout lives on a network volume, where those get corrupted
# (stale NFS handles, module maps truncated mid-write), which breaks the build at random. Keeping
# the scratch directory on the local disk avoids that. `embed_sparkle.sh` and `release.sh` have to
# agree on it, so they take it as an argument or use the same default.
BUILD_SCRATCH="${SWIFT_SCRATCH_PATH:-$HOME/build}"

TARGET_NAME="OpenUsage"                 # SwiftPM target / binary name
APP_DISPLAY="OpenUsage"                 # user-facing app name
BUNDLE_ID="${BUNDLE_ID:-com.robinebers.openusage.dev}"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The dev build is labelled by its commit ("dev (abc1234)" in the footer and About panel), so it never
# carries a stale release number. Releases take their version from the tag; see script/release.sh.
APP_VERSION="dev ($(git -C "$ROOT_DIR" rev-parse --short HEAD))"
APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
DIST_DIR="$ROOT_DIR/dist"
# Where the app ends up.
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
# Where it is assembled. The bundle is staged on the local disk and only then copied into place.
# Staging it where it will live means deleting the executable the running app may still hold open,
# and on a network volume that leaves the old binary behind as an NFS silly-rename file — inside
# the freshly signed bundle, which invalidates its signature.
STAGED_BUNDLE="$BUILD_SCRATCH/staging/$APP_DISPLAY.app"
APP_CONTENTS="$STAGED_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
CLI_BINARY="$APP_HELPERS/openusage"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="${TARGET_NAME}_${TARGET_NAME}.bundle"
SIGN_ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.local.entitlements.plist"

# Stop only the dev build staged here, never an installed OpenUsage with the same executable name.
RUNNING_BINARY="$APP_BUNDLE/Contents/MacOS/$TARGET_NAME"
pkill -f "^$RUNNING_BINARY" >/dev/null 2>&1 || true
# Wait for it to actually exit, so the copy below never races a running app.
for _ in $(seq 1 40); do
  pgrep -f "^$RUNNING_BINARY" >/dev/null 2>&1 || break
  sleep 0.25
done

echo "==> swift build ($CONFIG)"
# shellcheck disable=SC2086  # SWIFT_BUILD_FLAGS is intentionally word-split into several flags.
swift build -c "$CONFIG" --scratch-path "$BUILD_SCRATCH" ${SWIFT_BUILD_FLAGS:-}
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path --scratch-path "$BUILD_SCRATCH" ${SWIFT_BUILD_FLAGS:-})"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/openusage-cli"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi
if [ ! -x "$BUILD_CLI_BINARY" ]; then
  echo "missing built CLI: $BUILD_CLI_BINARY" >&2
  exit 1
fi

echo "==> staging $STAGED_BUNDLE"
# The staging directory is on the local disk and is rebuilt from scratch every time, so it never
# inherits leftovers. A stale NFS silly-rename file — one deleted while still open — can leave a
# bundle undeletable on a network volume, so the removal must not abort the build.
rm -rf "$STAGED_BUNDLE" || true
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$CLI_BINARY"
# The shared module links Sparkle even though the one-shot CLI never initializes the updater. Helpers
# sit one directory below Contents, so give dyld the same embedded-framework location as the app binary.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance (pop-up buttons,
# pickers, etc.) on the linked SDK — a "15.0" stamp makes AppKit fall back to legacy Aqua controls.
# Restamp the sdk to 26.0 (Tahoe, where Liquid Glass landed) while keeping minos at MIN_SYSTEM_VERSION
# so the app still runs on macOS 15 but gets the modern controls. Re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Stage every SwiftPM resource bundle produced by the build (the app's own
# OpenUsage_OpenUsage.bundle, which carries the provider SVGs + model manifest)
# into Contents/Resources, the standard app layout. Bundle.openUsageResources
# (see Support/ResourceBundle.swift) loads it from there.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Install the prebuilt app icon, like the release build: actool crashes on the Icon Composer source
# (assets/AppIcon.icon) on current toolchains, so script/compile_icon.sh regenerates
# assets/AppIcon.prebuilt whenever the source changes. CFBundleIconName below must match the .icon
# stem ("AppIcon").
echo "==> installing app icon (assets/AppIcon.prebuilt)"
cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Pick a stable Apple Development identity so ad-hoc cdhash churn doesn't re-trigger
# permission prompts on every rebuild. Fall back to ad-hoc only if none is found.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi

# The hardened runtime enables library validation: every non-platform library the app loads must
# carry the same team id as the app itself. An ad-hoc signature has no team id, so a runtime-signed
# ad-hoc build dies at launch — dyld refuses the bundled Sparkle.framework with "mapping process
# and mapped file (non-platform) have different Team IDs". Ad-hoc builds therefore sign without the
# runtime flag; a real identity keeps it (notarization requires it).
# No identity at all is the same situation as an unusable one: sign ad-hoc.
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY="-"
fi
SIGN_FLAGS="--options runtime"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  SIGN_FLAGS=""
fi

# A listed identity is not always a usable one: with a locked login keychain the private key
# cannot be fetched and codesign fails with errSecInternalComponent. Probe the identity on the CLI
# helper before committing the whole bundle to it, and fall back to ad-hoc when it cannot sign.
if [ -n "$CODESIGN_IDENTITY" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
  if ! /usr/bin/codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$CLI_BINARY" >/dev/null 2>&1; then
    echo "WARNING: cannot sign with '$CODESIGN_IDENTITY' (is the login keychain unlocked?); using an ad-hoc signature." >&2
    CODESIGN_IDENTITY="-"
    SIGN_FLAGS=""
  fi
fi

# Embed + sign Sparkle.framework before sealing the app. The executable links Sparkle, so without the
# embedded framework the build would fail to launch — even though the updater stays dormant here (no
# SUFeedURL in the Info.plist above; see UpdaterController).
"$ROOT_DIR/script/embed_sparkle.sh" "$STAGED_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "$SIGN_FLAGS" "$BUILD_SCRATCH"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  # Not --deep: the Sparkle framework is already signed above and must keep that signature.
  /usr/bin/codesign --force $SIGN_FLAGS \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$SIGN_ENTITLEMENTS" \
    "$STAGED_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$SIGN_ENTITLEMENTS" "$STAGED_BUNDLE" >/dev/null
  echo "WARNING: ad-hoc signed (no usable signing identity)." >&2
fi

# The bundle has to verify: a file that appears inside it after it was signed breaks the
# signature, and macOS then refuses to launch the bundle. Catch it here instead of at launch.
if ! /usr/bin/codesign --verify --strict "$STAGED_BUNDLE" >/dev/null 2>&1; then
  echo "ERROR: the signed bundle does not verify — something changed inside it after signing." >&2
  /usr/bin/codesign --verify --strict "$STAGED_BUNDLE" >&2 || true
  exit 1
fi

# Put the signed bundle where it belongs. The old one is renamed out of the way rather than
# deleted: on a network volume, deleting an executable the app was just running from leaves it
# behind as an NFS silly-rename file, and that file would land inside the new bundle.
mkdir -p "$DIST_DIR"
PREVIOUS_BUNDLE="$DIST_DIR/.previous-$APP_DISPLAY.app"
rm -rf "$PREVIOUS_BUNDLE" 2>/dev/null || true
if [ -e "$PREVIOUS_BUNDLE" ]; then
  # It could not be deleted — the server still holds a file in it — so use a fresh name and let the
  # move below not nest one bundle inside another.
  PREVIOUS_BUNDLE="$DIST_DIR/.previous-$APP_DISPLAY-$(date +%s).app"
fi
if [ -e "$APP_BUNDLE" ]; then
  mv "$APP_BUNDLE" "$PREVIOUS_BUNDLE" 2>/dev/null || rm -rf "$APP_BUNDLE" 2>/dev/null || true
fi
if [ -e "$APP_BUNDLE" ]; then
  echo "ERROR: could not replace $APP_BUNDLE" >&2
  exit 1
fi
ditto "$STAGED_BUNDLE" "$APP_BUNDLE"
# The previous bundle is only junk now; it may not delete while the server still holds a file in
# it, so leftovers are swept once they can be removed.
find "$DIST_DIR" -maxdepth 1 -name ".previous-$APP_DISPLAY*.app" -mtime +1 -exec rm -rf {} \; 2>/dev/null || true
if ! /usr/bin/codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "ERROR: the bundle at $APP_BUNDLE does not verify after being copied into place." >&2
  /usr/bin/codesign --verify --strict "$APP_BUNDLE" >&2 || true
  exit 1
fi

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    launch_app
    echo "==> launched $APP_DISPLAY (dist/$APP_DISPLAY.app)"
    ;;
  build)
    : # build + stage + sign only
    ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -f "^$RUNNING_BINARY" >/dev/null && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
