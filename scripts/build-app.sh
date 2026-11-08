#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
task_bin_path="$(swift build -c release --show-bin-path)"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.joshuazang.reading-capture "$task_app_path"
ditto -c -k --keepParent "$task_app_path" "$PWD/dist/ReadingCapture-macOS.zip"
echo "Built $task_app_path (ad-hoc signed; not notarized)."
