#!/bin/zsh
set -eu

readonly PROJECT_DIR="${0:A:h:h}"
readonly DEFAULT_SOURCE_APP="$PROJECT_DIR/dist/Claude Chrome.app"
readonly TARGET_APP="/Applications/Claude Chrome.app"
readonly SUPPORT_DIR="$HOME/Library/Application Support/Claude Chrome"
readonly BACKUP_APP="$SUPPORT_DIR/Previous Claude Chrome.app"
readonly IDENTITY_FILE="$SUPPORT_DIR/signing-identity.txt"
readonly LOCK_DIR="$SUPPORT_DIR/install.lock"
readonly STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-chrome-install.XXXXXX")"
readonly STAGING_APP="$STAGING_DIR/Claude Chrome.app"
readonly FAILED_APP="$STAGING_DIR/Rejected Claude Chrome.app"
readonly INSTALLED_CORE="$TARGET_APP/Contents/MacOS/Google Chrome"
lock_acquired=0

cleanup() {
  if (( lock_acquired )); then
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  /usr/bin/find "$STAGING_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  print -u2 -- "$1"
  exit "${2:-65}"
}

designated_requirement() {
  local output requirement
  output="$(/usr/bin/codesign -d -r- "$1" 2>&1)" || return 1
  requirement="$(print -r -- "$output" | /usr/bin/sed -n -e 's/^designated => //p' -e 's/^# designated => //p' | /usr/bin/head -n 1)"
  [[ -n "$requirement" ]] || return 1
  print -r -- "$requirement"
}

uses_certificate_requirement() {
  local requirement="${1:l}"
  [[ "$requirement" == *certificate* && "$requirement" != *cdhash* ]]
}

installed_process_running() {
  local pid executable
  while read -r pid executable; do
    case "$executable" in
      "$TARGET_APP/Contents/"*) return 0 ;;
    esac
  done < <(/bin/ps -ww -axo pid=,comm=)
  return 1
}

verify_structure() {
  local app="$1"
  local info="$app/Contents/Info.plist"
  local guard_app="$app/Contents/Helpers/Claude Chrome Guard.app"
  local guard_info="$guard_app/Contents/Info.plist"
  [[ -x "$app/Contents/MacOS/Claude Chrome" &&
     -x "$app/Contents/MacOS/Google Chrome" &&
     -x "$guard_app/Contents/MacOS/Claude Chrome Guard" &&
     "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null)" == 'local.claudechrome.launcher' &&
     "$(/usr/bin/plutil -extract CFBundleExecutable raw "$info" 2>/dev/null)" == 'Claude Chrome' &&
     "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$guard_info" 2>/dev/null)" == 'local.claudechrome.guard' &&
     "$(/usr/bin/plutil -extract CFBundleExecutable raw "$guard_info" 2>/dev/null)" == 'Claude Chrome Guard' ]]
}

verify_configured_identity() {
  local app="$1"
  local requirement="=certificate leaf = H\"$SIGNING_FINGERPRINT\""
  local artifact designated
  for artifact in \
    "$app/Contents/MacOS/Google Chrome" \
    "$app/Contents/Helpers/Claude Chrome Guard.app" \
    "$app"; do
    designated="$(designated_requirement "$artifact")" || return 1
    uses_certificate_requirement "$designated" || return 1
    /usr/bin/codesign --verify --strict -R "$requirement" "$artifact" >/dev/null 2>&1 || return 1
  done
}

verify_app() {
  local app="$1"
  verify_structure "$app" || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  if [[ -n "$SIGNING_FINGERPRINT" ]]; then
    verify_configured_identity "$app" || return 1
  fi
}

if (( $# > 1 )); then
  fail '用法：scripts/install.sh [Claude Chrome.app]' 64
fi
readonly SOURCE_APP="${1:-$DEFAULT_SOURCE_APP}"
if [[ ! -d "$SOURCE_APP" || -L "$SOURCE_APP" ]]; then
  fail '找不到可安裝的Claude Chrome.app。' 66
fi
if [[ -L "$SUPPORT_DIR" || ( -e "$SUPPORT_DIR" && ! -d "$SUPPORT_DIR" ) ]]; then
  fail 'Claude Chrome本機資料夾格式不正確。'
fi
/bin/mkdir -p -m 700 "$SUPPORT_DIR"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  fail '另一個Claude Chrome安裝程序正在執行。' 75
fi
lock_acquired=1
if [[ -L "$TARGET_APP" || ( -e "$TARGET_APP" && ! -d "$TARGET_APP" ) ]]; then
  fail '已安裝的Claude Chrome路徑格式不正確。'
fi
if [[ -L "$BACKUP_APP" || ( -e "$BACKUP_APP" && ! -d "$BACKUP_APP" ) ]]; then
  fail 'Claude Chrome備份路徑格式不正確。'
fi

SIGNING_FINGERPRINT=''
if [[ -L "$IDENTITY_FILE" ]]; then
  fail '本機簽章identity檔案不可為符號連結。'
elif [[ -e "$IDENTITY_FILE" ]]; then
  if [[ ! -f "$IDENTITY_FILE" || ! -r "$IDENTITY_FILE" ]]; then
    fail '本機簽章identity檔案無法讀取。'
  fi
  SIGNING_FINGERPRINT="$(<"$IDENTITY_FILE")"
  if (( ${#SIGNING_FINGERPRINT} != 40 )) || [[ "$SIGNING_FINGERPRINT" == *[^[:xdigit:]]* ]]; then
    fail '本機簽章identity檔案必須只包含40位SHA fingerprint。'
  fi
  SIGNING_FINGERPRINT="${SIGNING_FINGERPRINT:u}"
fi
readonly SIGNING_FINGERPRINT

if installed_process_running; then
  fail 'Claude Chrome仍在執行，請完全結束後再安裝。' 75
fi

installed_core_requirement=''
if [[ -z "$SIGNING_FINGERPRINT" && -x "$INSTALLED_CORE" ]]; then
  installed_core_requirement="$(designated_requirement "$INSTALLED_CORE")" ||
    fail '無法確認已安裝Chrome核心的簽章要求。'
  if ! uses_certificate_requirement "$installed_core_requirement"; then
    installed_core_requirement=''
  fi
fi
readonly installed_core_requirement

if ! /bin/cp -cRp "$SOURCE_APP" "$STAGING_APP"; then
  fail '無法以APFS clone暫存待安裝App。' 74
fi
/usr/bin/xattr -cr "$STAGING_APP"
verify_app "$STAGING_APP" || fail '待安裝App的結構或簽章驗證失敗。'

if [[ -n "$installed_core_requirement" ]]; then
  candidate_core_requirement="$(designated_requirement "$STAGING_APP/Contents/MacOS/Google Chrome")" ||
    fail '無法確認待安裝Chrome核心的簽章要求。'
  if [[ "$candidate_core_requirement" != "$installed_core_requirement" ]]; then
    fail '待安裝Chrome核心會改變現有穩定簽章要求；請先設定本機簽章identity。'
  fi
fi

if installed_process_running; then
  fail 'Claude Chrome在驗證期間已啟動，安裝已停止。' 75
fi

had_installed=0
if [[ -d "$TARGET_APP" ]]; then
  if [[ -d "$BACKUP_APP" ]]; then
    /usr/bin/find "$BACKUP_APP" -depth -delete
  fi
  /bin/mv "$TARGET_APP" "$BACKUP_APP" || fail '無法建立安裝前備份。' 74
  had_installed=1
fi

if ! /bin/mv "$STAGING_APP" "$TARGET_APP"; then
  if (( had_installed )) && [[ ! -e "$TARGET_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null ||
      fail "安裝失敗；原App保留於：$BACKUP_APP" 74
    fail '安裝失敗，已還原原App。' 74
  fi
  fail '安裝失敗；請檢查目標及備份路徑。' 74
fi

if ! verify_app "$TARGET_APP"; then
  if ! /bin/mv "$TARGET_APP" "$FAILED_APP" 2>/dev/null; then
    if (( had_installed )); then
      fail "安裝後驗證失敗；原App保留於：$BACKUP_APP" 74
    fi
    fail '安裝後驗證失敗，且無法移走未通過驗證的App。' 74
  fi
  if (( had_installed )); then
    /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null ||
      fail "安裝後驗證失敗；原App保留於：$BACKUP_APP" 74
    fail '安裝後簽章驗證失敗，已還原原App。' 74
  fi
  fail '安裝後簽章驗證失敗，未保留未通過驗證的App。' 74
fi

print 'Claude Chrome已安裝；上一版本最多保留一份。'
