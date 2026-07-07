#!/usr/bin/env bash
set -euo pipefail

# macOS privacy grants, including Bluetooth, are tied to an app's code identity
# and installed path. Keep both stable across local dev updates so replacing the
# app does not require approving Bluetooth again.

MODE="${1:-run}"
APP_NAME="DoorUnlockerAdmin"
CLI_NAME="door-unlocker"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlockerAdmin"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/mac/DoorUnlockerAdmin"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="${TMPDIR:-/tmp}/door-unlocker-admin-build/staging"
LEGACY_TMP_DIST="${TMPDIR:-/tmp}/door-unlocker-admin-dist"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$DIST_DIR/$CLI_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/mac/DoorUnlockerAdmin/Resources/AppIcon.icns"
ICON_FILE_NAME="AppIcon.icns"
INSTALL_DIR="$HOME/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
INSTALL_BINARY="$INSTALL_PATH/Contents/MacOS/$APP_NAME"
SIGNING_IDENTITY="${DOOR_UNLOCKER_ADMIN_SIGNING_IDENTITY:-Door Unlocker Admin Local Signing}"
SIGNING_DIR="${DOOR_UNLOCKER_ADMIN_SIGNING_DIR:-$HOME/Library/Application Support/Door Unlocker Admin/CodeSigning}"
SIGNING_KEYCHAIN="$SIGNING_DIR/door-unlocker-admin-signing.keychain-db"
SIGNING_KEYCHAIN_PASSWORD="${DOOR_UNLOCKER_ADMIN_SIGNING_KEYCHAIN_PASSWORD:-door-unlocker-admin-local-signing}"
SIGNING_P12_PASSWORD="${DOOR_UNLOCKER_ADMIN_SIGNING_P12_PASSWORD:-door-unlocker-admin-local-signing-p12}"
DESIGNATED_REQUIREMENT_FILE="${DOOR_UNLOCKER_ADMIN_DESIGNATED_REQUIREMENT_FILE:-$SIGNING_DIR/door-unlocker-admin-designated-requirement.txt}"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install]" >&2
  exit 2
}

kill_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

cleanup_duplicate_build_artifacts() {
  rm -rf \
    "$LEGACY_TMP_DIST" \
    "$DIST_DIR/$APP_NAME.app" \
    "$DIST_DIR/macos/$APP_NAME.app" \
    "$STAGING_DIR"
}

ensure_local_signing_identity() {
  mkdir -p "$SIGNING_DIR"

  if [[ -f "$SIGNING_KEYCHAIN" ]]; then
    security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null

    if security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
      return
    fi

    security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || rm -f "$SIGNING_KEYCHAIN"
  fi

  security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
  security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN" >/dev/null
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null

  local openssl_config="$SIGNING_DIR/door-unlocker-admin-signing.openssl.cnf"
  local private_key="$SIGNING_DIR/door-unlocker-admin-signing.key.pem"
  local certificate="$SIGNING_DIR/door-unlocker-admin-signing.cert.pem"
  local p12="$SIGNING_DIR/door-unlocker-admin-signing.p12"

  cat >"$openssl_config" <<CONFIG
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = extensions

[ dn ]
CN = $SIGNING_IDENTITY

[ extensions ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONFIG

  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$private_key" \
    -out "$certificate" \
    -config "$openssl_config" >/dev/null 2>&1

  openssl pkcs12 -export \
    -inkey "$private_key" \
    -in "$certificate" \
    -out "$p12" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -passout "pass:$SIGNING_P12_PASSWORD" >/dev/null 2>&1

  security import "$p12" \
    -k "$SIGNING_KEYCHAIN" \
    -P "$SIGNING_P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null

  security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$SIGNING_KEYCHAIN" \
    "$certificate" >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$SIGNING_KEYCHAIN_PASSWORD" \
    "$SIGNING_KEYCHAIN" >/dev/null
}

ensure_signing_keychain_in_search_list() {
  local existing_keychains=()
  local keychain

  while IFS= read -r keychain; do
    [[ -n "$keychain" ]] && existing_keychains+=("$keychain")
  done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')

  for keychain in "${existing_keychains[@]}"; do
    if [[ "$keychain" == "$SIGNING_KEYCHAIN" ]]; then
      return
    fi
  done

  security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${existing_keychains[@]}" >/dev/null
}

sign_bundle() {
  ensure_local_signing_identity
  ensure_signing_keychain_in_search_list
  find "$APP_BUNDLE" -name ".DS_Store" -delete
  find "$APP_BUNDLE" -name "._*" -delete
  xattr -cr "$APP_BUNDLE"
  codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE" >/dev/null
}

designated_requirement() {
  codesign -d --requirements - "$1" 2>&1 | sed -n 's/^designated => //p'
}

verify_designated_requirement_stability() {
  local requirement
  requirement="$(designated_requirement "$APP_BUNDLE")"

  if [[ -z "$requirement" ]]; then
    echo "Could not read designated requirement for $APP_BUNDLE." >&2
    exit 1
  fi

  if [[ ! -f "$DESIGNATED_REQUIREMENT_FILE" ]]; then
    printf '%s\n' "$requirement" > "$DESIGNATED_REQUIREMENT_FILE"
    return
  fi

  local expected
  expected="$(cat "$DESIGNATED_REQUIREMENT_FILE")"

  if [[ "$requirement" == "$expected" ]]; then
    return
  fi

  cat >&2 <<MESSAGE
Refusing to install $APP_NAME because its designated requirement changed.

This would make macOS treat the update as a different app and can reset
Bluetooth permission.

Expected:
$expected

Actual:
$requirement

If this is intentional, run once with:
DOOR_UNLOCKER_ADMIN_ACCEPT_NEW_REQUIREMENT=1 ./script/build_and_run.sh --install
MESSAGE

  if [[ "${DOOR_UNLOCKER_ADMIN_ACCEPT_NEW_REQUIREMENT:-0}" == "1" ]]; then
    printf '%s\n' "$requirement" > "$DESIGNATED_REQUIREMENT_FILE"
    return
  fi

  exit 1
}

build_bundle() {
  swift build --package-path "$PACKAGE_DIR"
  local build_dir
  build_dir="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"
  local build_binary="$build_dir/$APP_NAME"

  mkdir -p "$DIST_DIR" "$STAGING_DIR"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp -X "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  printf "APPL????" > "$APP_CONTENTS/PkgInfo"

  if [[ -f "$build_dir/$CLI_NAME" ]]; then
    cp -X "$build_dir/$CLI_NAME" "$CLI_BINARY"
    chmod +x "$CLI_BINARY"
  fi

  if [[ -f "$ICON_SOURCE" ]]; then
    cp -X "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE_NAME"
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>Door Unlocker</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Door Unlocker</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Door Unlocker uses Bluetooth to connect to the controller wirelessly.</string>
</dict>
</plist>
PLIST

  sign_bundle
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_PATH"
  ditto "$APP_BUNDLE" "$INSTALL_PATH"
  xattr -cr "$INSTALL_PATH"
  rm -rf "$STAGING_DIR"
}

verify_installed_app() {
  codesign --verify --deep --strict "$INSTALL_PATH"

  local requirement
  requirement="$(designated_requirement "$INSTALL_PATH")"

  if [[ "$requirement" != "$(cat "$DESIGNATED_REQUIREMENT_FILE")" ]]; then
    echo "Installed app does not match the expected designated requirement." >&2
    exit 1
  fi
}

verify_no_duplicate_app_bundles() {
  local duplicates
  duplicates="$(
    find "$ROOT_DIR" /Applications "$HOME/Applications" -maxdepth 4 -name "$APP_NAME.app" -print 2>/dev/null \
      | grep -Fv "$INSTALL_PATH" || true
  )"

  if [[ -n "$duplicates" ]]; then
    echo "Warning: found another $APP_NAME.app outside $INSTALL_PATH." >&2
    printf '%s\n' "$duplicates" >&2
  fi
}

open_app() {
  /usr/bin/open "$INSTALL_PATH"
}

cleanup_duplicate_build_artifacts
build_bundle
verify_designated_requirement_stability
kill_running_app
install_app
verify_installed_app
verify_no_duplicate_app_bundles

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALL_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not start within 5 seconds." >&2
    exit 1
    ;;
  --install|install)
    open_app
    ;;
  *)
    usage
    ;;
esac
