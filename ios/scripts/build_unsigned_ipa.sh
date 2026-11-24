#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "正在透過 Homebrew 安裝 xcodegen..."
  brew install xcodegen
fi

echo "==> 產生 Readify.xcodeproj..."
xcodegen generate

echo "==> 編譯 Release Readify.app (免開發者簽章)..."
xcodebuild build \
  -project Readify.xcodeproj \
  -scheme Readify \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

APP_PATH="$PWD/build/DerivedData/Build/Products/Release-iphoneos/Readify.app"
rm -rf "$PWD/build/ipa"
mkdir -p "$PWD/build/ipa/Payload"
cp -R "$APP_PATH" "$PWD/build/ipa/Payload/Readify.app"
codesign --force --deep --sign - "$PWD/build/ipa/Payload/Readify.app"

(
  cd "$PWD/build/ipa"
  zip -qry "$PWD/../Readify-unsigned.ipa" Payload
)

echo "✅ 已產出：$PWD/build/Readify-unsigned.ipa"
