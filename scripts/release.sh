#!/bin/bash
set -euo pipefail

# ─── Config ───
APP_NAME="Token Remote"
BUNDLE_ID="com.tokenremote.desktop"
SCHEME="TokenRemoteDesktop"
PROJECT="TokenRemoteDesktop.xcodeproj"
TEAM_ID="6J8NCZC8G6"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/TokenRemote.dmg"
ZIP_PATH="$PROJECT_DIR/dist/TokenRemote.zip"

# ─── Resolve signing identity ───
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')

if [ -z "$SIGN_IDENTITY" ]; then
    echo "❌ No 'Developer ID Application' certificate found."
    echo "   Install one from https://developer.apple.com/account/resources/certificates"
    exit 1
fi
echo "🔑 Signing with: $SIGN_IDENTITY"

# ─── Clean ───
echo "🧹 Cleaning..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$PROJECT_DIR/dist"

# ─── Archive ───
echo "📦 Archiving..."
xcodebuild archive \
    -project "$PROJECT_DIR/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    2>&1 | tail -5

# ─── Export ───
echo "📤 Exporting..."
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    2>&1 | tail -5

APP_PATH="$EXPORT_PATH/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Export failed — $APP_PATH not found"
    exit 1
fi

echo "✅ Exported: $APP_PATH"

# ─── Notarize ───
echo "🔏 Notarizing..."
ZIP_FOR_NOTARIZE="$BUILD_DIR/notarize-upload.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARIZE"

xcrun notarytool submit "$ZIP_FOR_NOTARIZE" \
    --keychain-profile "AC_PASSWORD" \
    --wait \
    2>&1 | tee "$BUILD_DIR/notarize.log"

# Staple the ticket
echo "📌 Stapling..."
xcrun stapler staple "$APP_PATH"

# ─── Package DMG ───
echo "💿 Creating DMG..."
hdiutil create -volname "Token Remote" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# Also notarize the DMG
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "AC_PASSWORD" \
    --wait \
    2>&1 | tee -a "$BUILD_DIR/notarize.log"

xcrun stapler staple "$DMG_PATH"

# ─── Also create a zip for GitHub releases ───
echo "📦 Creating zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo ""
echo "════════════════════════════════════════════"
echo "✅ Release ready!"
echo "   DMG:  $DMG_PATH"
echo "   ZIP:  $ZIP_PATH"
echo "   App:  $APP_PATH"
echo "════════════════════════════════════════════"
