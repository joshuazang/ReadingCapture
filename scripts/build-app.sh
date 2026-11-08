#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
task_arm_bin="$(swift build -c release --arch arm64 --show-bin-path)/ReadingCapture"
task_app_path="$PWD/dist/Reading Capture.app"
mkdir -p "$task_app_path/Contents/MacOS" "$task_app_path/Contents/Resources"
cp "$task_arm_bin" "$task_app_path/Contents/MacOS/ReadingCapture"
cat > "$task_app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.joshuazang.reading-capture</string>
<key>CFBundleName</key><string>Reading Capture</string>
<key>CFBundleExecutable</key><string>ReadingCapture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSAppleEventsUsageDescription</key><string>Read Skim’s book name and highlight annotations into your local capture library. Reading Capture does not change your PDFs.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
task_icon_dir="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$task_icon_dir"
iconutil -c icns "$task_icon_dir" -o "$task_app_path/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$task_icon_dir")"
codesign --force --sign - --entitlements scripts/ReadingCapture.entitlements --identifier com.joshuazang.reading-capture "$task_app_path"
[[ "$(lipo -archs "$task_app_path/Contents/MacOS/ReadingCapture")" == arm64 ]]
ditto -c -k --sequesterRsrc --keepParent "$task_app_path" "$PWD/dist/ReadingCapture-macOS.zip"
task_image_stage="$(mktemp -d)"
trap 'rm -rf "$task_image_stage"' EXIT
ditto "$task_app_path" "$task_image_stage/Reading Capture.app"
ln -s /Applications "$task_image_stage/Applications"
hdiutil create -volname "Reading Capture" -srcfolder "$task_image_stage" -ov -format UDZO "$PWD/dist/ReadingCapture-macOS.dmg"
(cd dist && shasum -a 256 ReadingCapture-macOS.zip ReadingCapture-macOS.dmg > SHA256SUMS.txt)
echo "Built $task_app_path (ad-hoc signed; not notarized)."
