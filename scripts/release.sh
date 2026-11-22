#!/usr/bin/env bash
# Builds a signed (and optionally notarized) universal ClipShare-<version>.dmg in ./dist.
#
#   ./scripts/release.sh 1.0.0
#
# Environment:
#   SIGN_IDENTITY   codesigning identity (default: the first "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile; when set, the DMG is notarized and stapled.
#                   Create one with: xcrun notarytool store-credentials <name> --apple-id ... --team-id ...
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found; set SIGN_IDENTITY." >&2; exit 1; }

DIST="dist"
APP="$DIST/ClipShare.app"
DMG="$DIST/ClipShare-$VERSION-macos.dmg"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building universal binary"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClipShare"

cp "$BIN" "$APP/Contents/MacOS/ClipShare"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Swift's back-deployment libraries (e.g. libswiftCompatibilitySpan) live in /usr/lib/swift only on
# newer macOS. Bundle any the binary needs so it runs on macOS 14/15, and drop the rpath into Xcode.
EXE="$APP/Contents/MacOS/ClipShare"
TOOLCHAIN_RPATH="$(otool -l "$EXE" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep '\.xctoolchain/' | head -1 || true)"
for lib in $(otool -L "$EXE" | awk '/@rpath\/libswift/ {sub("@rpath/", "", $1); print $1}' | sort -u); do
  mkdir -p "$APP/Contents/Frameworks"
  cp "$TOOLCHAIN_RPATH/$lib" "$APP/Contents/Frameworks/"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/$lib"
done
if [[ -n "$TOOLCHAIN_RPATH" ]]; then
  install_name_tool -delete_rpath "$TOOLCHAIN_RPATH" "$EXE"
fi
install_name_tool -add_rpath @executable_path/../Frameworks "$EXE"

echo "==> Signing app as: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ClipShare $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing with profile $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo "==> NOTARY_PROFILE not set; skipping notarization"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"
echo "Done: $DMG"
