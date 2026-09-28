#!/bin/zsh
set -eu

readonly PROJECT_DIR="${0:A:h:h}"
readonly SOURCE_DIR="$PROJECT_DIR/Sources"
readonly RESOURCE_DIR="$PROJECT_DIR/Resources"
readonly DIST_DIR="$PROJECT_DIR/dist"
readonly OUTPUT_APP="$DIST_DIR/Claude Chrome.app"
readonly BACKUP_APP="$DIST_DIR/Claude Chrome.app.latest-backup"
readonly LOGO_PATH="$RESOURCE_DIR/Logo.png"
readonly STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build.XXXXXX")"
readonly STAGING_APP="$STAGING_DIR/Claude Chrome.app"
readonly ICONSET_DIR="$STAGING_DIR/AppIcon.iconset"

cleanup() {
  /usr/bin/find "$STAGING_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "$LOGO_PATH" || -L "$LOGO_PATH" ]]; then
  print -u2 '缺少已核准的 Resources/Logo.png。'
  exit 66
fi

/bin/mkdir -p "$DIST_DIR" "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$ICONSET_DIR"
/bin/cp "$RESOURCE_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"

/usr/bin/swiftc -O -target arm64-apple-macos13.0 -framework AppKit \
  "$SOURCE_DIR/Launcher.swift" \
  -o "$STAGING_APP/Contents/MacOS/Claude Chrome"

/usr/bin/swiftc -O -target arm64-apple-macos13.0 -framework AppKit \
  "$SOURCE_DIR/GenerateIcon.swift" \
  -o "$STAGING_DIR/generate-icon"
"$STAGING_DIR/generate-icon" "$LOGO_PATH" "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"

if [[ -e "$BACKUP_APP" ]]; then
  /usr/bin/find "$BACKUP_APP" -depth -delete
fi
if [[ -e "$OUTPUT_APP" ]]; then
  /bin/mv "$OUTPUT_APP" "$BACKUP_APP"
fi
/bin/mv "$STAGING_APP" "$OUTPUT_APP"
/usr/bin/xattr -cr "$OUTPUT_APP"
/usr/bin/codesign --force --deep --sign - "$OUTPUT_APP"
/usr/bin/xattr -cr "$OUTPUT_APP"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_APP"
/usr/bin/plutil -lint "$OUTPUT_APP/Contents/Info.plist"
