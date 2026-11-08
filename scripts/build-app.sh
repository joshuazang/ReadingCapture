#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
task_bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
task_app_path="$PWD/dist/Reading Capture.app"
mkdir -p "$task_app_path/Contents/MacOS"
cp "$task_bin_path/ReadingCapture" "$task_app_path/Contents/MacOS/ReadingCapture"
cat > "$task_app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.joshuazang.reading-capture</string>
<key>CFBundleName</key><string>Reading Capture</string>
<key>CFBundleExecutable</key><string>ReadingCapture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.joshuazang.reading-capture "$task_app_path"
lipo -verify_arch arm64 x86_64 "$task_app_path/Contents/MacOS/ReadingCapture"
ditto -c -k --sequesterRsrc --keepParent "$task_app_path" "$PWD/dist/ReadingCapture-macOS.zip"
task_image_stage="$(mktemp -d)"
trap 'rm -rf "$task_image_stage"' EXIT
ditto "$task_app_path" "$task_image_stage/Reading Capture.app"
ln -s /Applications "$task_image_stage/Applications"
hdiutil create -volname "Reading Capture" -srcfolder "$task_image_stage" -ov -format UDZO "$PWD/dist/ReadingCapture-macOS.dmg"
(cd dist && shasum -a 256 ReadingCapture-macOS.zip ReadingCapture-macOS.dmg > SHA256SUMS.txt)
echo "Built $task_app_path (ad-hoc signed; not notarized)."
