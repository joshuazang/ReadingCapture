#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_verify_dir="$(mktemp -d)"
task_mounted=0
cleanup() {
  if [[ "$task_mounted" == 1 ]]; then hdiutil detach "$task_verify_dir/mount"; fi
  rm -rf "$task_verify_dir"
}
trap cleanup EXIT
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
unzip -t dist/ReadingCapture-macOS.zip
ditto -x -k dist/ReadingCapture-macOS.zip "$task_verify_dir/unzipped"
codesign --verify --deep --strict --all-architectures "$task_verify_dir/unzipped/Reading Capture.app"
cmp "dist/Reading Capture.app/Contents/MacOS/ReadingCapture" "$task_verify_dir/unzipped/Reading Capture.app/Contents/MacOS/ReadingCapture"
hdiutil verify dist/ReadingCapture-macOS.dmg
mkdir "$task_verify_dir/mount"
hdiutil attach -readonly -nobrowse -mountpoint "$task_verify_dir/mount" dist/ReadingCapture-macOS.dmg
task_mounted=1
codesign --verify --deep --strict --all-architectures "$task_verify_dir/mount/Reading Capture.app"
[[ "$(lipo -archs "$task_verify_dir/mount/Reading Capture.app/Contents/MacOS/ReadingCapture")" == arm64 ]]
cmp "dist/Reading Capture.app/Contents/MacOS/ReadingCapture" "$task_verify_dir/mount/Reading Capture.app/Contents/MacOS/ReadingCapture"
[[ "$(readlink "$task_verify_dir/mount/Applications")" == /Applications ]]
echo "Verified ZIP extraction, DMG mounting, Apple Silicon-only architecture, signatures and exact packaged executable bytes."
