#!/bin/zsh
set -eu
readonly PROJECT_DIR="${0:A:h:h}"
readonly OUTPUT_APP="$PROJECT_DIR/dist/Claude Login Router.app"
readonly IDENTITY_FILE="$HOME/Library/Application Support/Claude Chrome/signing-identity.txt"
readonly STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-login-router.XXXXXX")"
trap '/usr/bin/find "$STAGING_DIR" -depth -delete 2>/dev/null || true' EXIT
[[ -f "$IDENTITY_FILE" && ! -L "$IDENTITY_FILE" ]] || exit 65
readonly SIGNING_IDENTITY="$(<"$IDENTITY_FILE")"
(( ${#SIGNING_IDENTITY} == 40 )) && [[ "$SIGNING_IDENTITY" != *[^[:xdigit:]]* ]] || exit 65
readonly APP="$STAGING_DIR/Claude Login Router.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$PROJECT_DIR/dist"
/bin/cp "$PROJECT_DIR/Resources/LoginRouterInfo.plist" "$APP/Contents/Info.plist"
/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macos13.0 -framework AppKit \
  "$PROJECT_DIR/Sources/LoginRouter.swift" "$PROJECT_DIR/Sources/DesktopLoginURL.swift" "$PROJECT_DIR/Sources/ExternalURL.swift" \
  -o "$APP/Contents/MacOS/Claude Login Router"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if [[ -d "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]]; then
  /usr/bin/find "$OUTPUT_APP" -depth -delete
fi
/bin/mv "$APP" "$OUTPUT_APP"
print -r -- "$OUTPUT_APP"
