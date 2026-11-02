#!/bin/bash
# Builds an UNSIGNED Shell.ipa — no Apple Developer account, no Mac needed.
# Runs on any macOS with Xcode + xcodegen (the GitHub Actions macos runner has Xcode preinstalled).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

xcodegen generate

rm -rf build
mkdir -p build

xcodebuild archive \
  -project Shell.xcodeproj \
  -scheme Shell \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Shell.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

mkdir -p build/Payload
cp -R "build/Shell.xcarchive/Products/Applications/Shell.app" build/Payload/
cd build
zip -qry Shell-unsigned.ipa Payload
echo "OK: $(pwd)/Shell-unsigned.ipa"
