#!/bin/zsh
set -eu

readonly PROJECT_DIR="${0:A:h:h}"
readonly SOURCE_DIR="$PROJECT_DIR/Sources"
readonly RESOURCE_DIR="$PROJECT_DIR/Resources"
readonly DIST_DIR="$PROJECT_DIR/dist"
readonly OUTPUT_APP="$DIST_DIR/Claude Chrome.app"
readonly BACKUP_APP="$DIST_DIR/Claude Chrome.app.latest-backup"
readonly LOGO_PATH="$RESOURCE_DIR/Logo.png"
readonly GUARD_INFO_SOURCE="$RESOURCE_DIR/GuardInfo.plist"
readonly CHROME_APP="/Applications/Google Chrome.app"
readonly CHROME_CORE="$CHROME_APP/Contents/MacOS/Google Chrome"
readonly STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-chrome-build.XXXXXX")"
readonly STAGING_APP="$STAGING_DIR/Claude Chrome.app"
readonly STAGING_INFO="$STAGING_APP/Contents/Info.plist"
readonly STAGING_CORE="$STAGING_APP/Contents/MacOS/Google Chrome"
readonly GUARD_APP="$STAGING_APP/Contents/Helpers/Claude Chrome Guard.app"
readonly GUARD_INFO="$GUARD_APP/Contents/Info.plist"
readonly GUARD_EXECUTABLE="$GUARD_APP/Contents/MacOS/Claude Chrome Guard"
readonly ICONSET_DIR="$STAGING_DIR/AppIcon.iconset"
readonly SOURCE_ENTITLEMENTS="$STAGING_DIR/GoogleChrome.entitlements.plist"
readonly LOCAL_CORE_ENTITLEMENTS="$STAGING_DIR/GoogleChrome.local-entitlements.plist"
readonly BUILT_ENTITLEMENTS="$STAGING_DIR/GoogleChrome.built-entitlements.plist"
readonly PLIST_TOOL_SOURCE="$STAGING_DIR/PlistTool.swift"
readonly PLIST_TOOL="$STAGING_DIR/plist-tool"

cleanup() {
  /usr/bin/find "$STAGING_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "$LOGO_PATH" || -L "$LOGO_PATH" ]]; then
  print -u2 '缺少已核准的 Resources/Logo.png。'
  exit 66
fi
if [[ ! -f "$SOURCE_DIR/AppEntry.swift" || ! -f "$GUARD_INFO_SOURCE" ]]; then
  print -u2 '缺少AppEntry.swift或GuardInfo.plist。'
  exit 66
fi
if [[ ! -d "$CHROME_APP" || -L "$CHROME_APP" || ! -x "$CHROME_CORE" ]]; then
  print -u2 '找不到可用的 /Applications/Google Chrome.app。'
  exit 66
fi
source_team_identifier="$(/usr/bin/codesign -dvvv "$CHROME_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$CHROME_APP/Contents/Info.plist" 2>/dev/null)" != 'com.google.Chrome' ]] ||
   [[ "$source_team_identifier" != 'EQHXZ8M8AV' ]] ||
   ! /usr/bin/codesign --verify --deep --strict=symlinks "$CHROME_APP"; then
  print -u2 '已安裝的 Google Chrome 無法驗證。'
  exit 65
fi

/bin/mkdir -p "$DIST_DIR" "$ICONSET_DIR"
source_size_kb="$(/usr/bin/du -sk "$CHROME_APP" | /usr/bin/awk '{print $1}')"
available_kb="$(/bin/df -Pk "$STAGING_DIR" | /usr/bin/awk 'NR == 2 {print $4}')"
minimum_free_kb="$((source_size_kb + 524288))"
if (( available_kb < minimum_free_kb )); then
  print -u2 '可用空間不足以在APFS clone不可用時安全複製Google Chrome。'
  exit 69
fi
if ! /bin/cp -cRp "$CHROME_APP" "$STAGING_APP"; then
  /usr/bin/find "$STAGING_APP" -depth -delete 2>/dev/null || true
  /bin/cp -Rp "$CHROME_APP" "$STAGING_APP"
fi
/usr/bin/xattr -cr "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

/usr/bin/codesign --display --entitlements - --xml "$CHROME_CORE" > "$SOURCE_ENTITLEMENTS" 2>/dev/null
cat > "$PLIST_TOOL_SOURCE" <<'SWIFT'
import Foundation

@main
enum PlistTool {
    static func read(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "PlistTool", code: 1)
        }
        return value
    }

    static func write(_ value: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { throw NSError(domain: "PlistTool", code: 2) }
        switch arguments[1] {
        case "merge-info":
            guard arguments.count == 5 else { throw NSError(domain: "PlistTool", code: 2) }
            var merged = try read(arguments[2])
            for (key, value) in try read(arguments[3]) { merged[key] = value }
            merged.removeValue(forKey: "CFBundleIconName")
            merged.removeValue(forKey: "CFBundleURLTypes")
            merged.removeValue(forKey: "CFBundleDocumentTypes")
            for key in merged.keys.filter({ $0.hasPrefix("KS") }) { merged.removeValue(forKey: key) }
            try write(merged, to: arguments[4])
        case "filter-entitlements":
            guard arguments.count == 4 else { throw NSError(domain: "PlistTool", code: 2) }
            let original = try read(arguments[2])
            let allowedKeys = [
                "com.apple.security.device.audio-input",
                "com.apple.security.device.bluetooth",
                "com.apple.security.device.camera",
                "com.apple.security.device.print",
                "com.apple.security.device.usb",
                "com.apple.security.personal-information.location",
                "com.apple.security.personal-information.photos-library",
            ]
            var filtered = allowedKeys.reduce(into: [String: Any]()) { values, key in
                if let value = original[key] { values[key] = value }
            }
            filtered["com.apple.security.cs.disable-library-validation"] = true
            try write(filtered, to: arguments[3])
        case "compare":
            guard arguments.count == 4 else { throw NSError(domain: "PlistTool", code: 2) }
            let expected = try read(arguments[2])
            let actual = try read(arguments[3])
            guard NSDictionary(dictionary: expected).isEqual(to: actual) else {
                throw NSError(domain: "PlistTool", code: 3)
            }
        default:
            throw NSError(domain: "PlistTool", code: 4)
        }
    }
}
SWIFT
/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  "$PLIST_TOOL_SOURCE" -o "$PLIST_TOOL"
"$PLIST_TOOL" merge-info "$STAGING_INFO" "$RESOURCE_DIR/Info.plist" "$STAGING_INFO"
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$STAGING_INFO")" != 'local.claudechrome.launcher' ]] ||
   [[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$STAGING_INFO")" != 'Claude Chrome' ]] ||
   [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "$STAGING_INFO")" != 'AppIcon' ]] ||
   [[ "$(/usr/bin/plutil -extract LSUIElement raw "$STAGING_INFO")" != 'false' ]]; then
  print -u2 'Resources/Info.plist 不符合Claude Chrome flat bundle設定。'
  exit 65
fi

/bin/cp "$RESOURCE_DIR/Start.html" "$RESOURCE_DIR/Start.css" "$RESOURCE_DIR/Start.js" \
  "$RESOURCE_DIR/SupportedRegions.js" "$LOGO_PATH" "$STAGING_APP/Contents/Resources/"

/bin/mkdir -p "$GUARD_APP/Contents/MacOS" "$GUARD_APP/Contents/Resources"
/bin/cp "$GUARD_INFO_SOURCE" "$GUARD_INFO"

/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macos13.0 -framework AppKit \
  "$SOURCE_DIR/AppEntry.swift" \
  -o "$STAGING_APP/Contents/MacOS/Claude Chrome"

/usr/bin/swiftc -O -target arm64-apple-macos13.0 -framework AppKit \
  "$SOURCE_DIR/Launcher.swift" "$SOURCE_DIR/ExitAssessment.swift" \
  -o "$GUARD_EXECUTABLE"

/usr/bin/swiftc -O -target arm64-apple-macos13.0 -framework AppKit \
  "$SOURCE_DIR/GenerateIcon.swift" \
  -o "$STAGING_DIR/generate-icon"
"$STAGING_DIR/generate-icon" "$LOGO_PATH" "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"
/bin/cp "$STAGING_APP/Contents/Resources/AppIcon.icns" "$GUARD_APP/Contents/Resources/AppIcon.icns"

if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$GUARD_INFO")" != 'local.claudechrome.guard' ]] ||
   [[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$GUARD_INFO")" != 'Claude Chrome Guard' ]] ||
   [[ "$(/usr/bin/plutil -extract LSUIElement raw "$GUARD_INFO")" != 'true' ]]; then
  print -u2 'Resources/GuardInfo.plist 不符合隱藏Guard設定。'
  exit 65
fi

/usr/bin/find "$STAGING_APP/Contents/Resources" -path '*/InfoPlist.strings' -type f -print0 |
  while IFS= read -r -d $'\0' strings_file; do
    for name_key in CFBundleName CFBundleDisplayName; do
      if /usr/bin/plutil -extract "$name_key" raw "$strings_file" >/dev/null 2>&1; then
        /usr/bin/plutil -replace "$name_key" -string 'Claude Chrome' "$strings_file"
      fi
    done
  done
"$PLIST_TOOL" filter-entitlements "$SOURCE_ENTITLEMENTS" "$LOCAL_CORE_ENTITLEMENTS"
/usr/bin/plutil -lint "$LOCAL_CORE_ENTITLEMENTS"
source_core_identifier="$(/usr/bin/codesign -dvv "$CHROME_CORE" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)"
source_core_flags="$(/usr/bin/codesign -dvv "$CHROME_CORE" 2>&1 | /usr/bin/sed -n 's/.*flags=\(0x[0-9a-fA-F]*\).*/\1/p' | /usr/bin/head -n 1)"
source_framework_hash="$(/usr/bin/codesign -dvvv "$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -n 1)"
if [[ -z "$source_core_identifier" || -z "$source_core_flags" || -z "$source_framework_hash" ]]; then
  print -u2 '無法讀取Google Chrome簽章資料。'
  exit 65
fi

/usr/bin/xattr -cr "$STAGING_APP"
/usr/bin/codesign --force --sign - \
  --options "$((source_core_flags & ~0x2000))" \
  --entitlements "$LOCAL_CORE_ENTITLEMENTS" \
  --preserve-metadata=identifier,runtime "$STAGING_CORE"
/usr/bin/codesign --force --sign - "$GUARD_APP"
/usr/bin/codesign --force --sign - "$STAGING_APP"

/usr/bin/codesign --display --entitlements - --xml "$STAGING_CORE" > "$BUILT_ENTITLEMENTS" 2>/dev/null
built_core_identifier="$(/usr/bin/codesign -dvv "$STAGING_CORE" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)"
built_core_flags="$(/usr/bin/codesign -dvv "$STAGING_CORE" 2>&1 | /usr/bin/sed -n 's/.*flags=\(0x[0-9a-fA-F]*\).*/\1/p' | /usr/bin/head -n 1)"
built_framework_hash="$(/usr/bin/codesign -dvvv "$STAGING_APP/Contents/Frameworks/Google Chrome Framework.framework" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -n 1)"
if [[ "$built_core_identifier" != "$source_core_identifier" ]] ||
   (( (built_core_flags & ~0x2) != (source_core_flags & ~0x2000) )) ||
   [[ "$built_framework_hash" != "$source_framework_hash" ]] ||
   ! "$PLIST_TOOL" compare "$LOCAL_CORE_ENTITLEMENTS" "$BUILT_ENTITLEMENTS"; then
  print -u2 'Google Chrome核心的簽章資料未能完整保留。'
  exit 65
fi

/usr/bin/plutil -lint "$STAGING_INFO" "$GUARD_INFO"
/usr/bin/codesign --verify --strict "$GUARD_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$BACKUP_APP" ]]; then
  /usr/bin/find "$BACKUP_APP" -depth -delete
fi
if [[ -e "$OUTPUT_APP" ]]; then
  /bin/mv "$OUTPUT_APP" "$BACKUP_APP"
fi
/bin/mv "$STAGING_APP" "$OUTPUT_APP"
/usr/bin/xattr -cr "$OUTPUT_APP"
/usr/bin/xattr -c "$OUTPUT_APP"
