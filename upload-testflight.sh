#!/bin/bash
# Archive + upload Nitrous to TestFlight.
# Usage: ./upload-testflight.sh [buildNumber]
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

BUILD=${1:-}
if [ -n "$BUILD" ]; then
  /usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/g" project.yml
  xcodegen generate
fi

xcodebuild -project Nitrous.xcodeproj -scheme Nitrous \
  -destination 'generic/platform=iOS' \
  -archivePath build-archive/Nitrous.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath build-archive/Nitrous.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build-archive/export \
  -allowProvisioningUpdates

echo "Uploaded. Build appears in TestFlight after ~2 min of processing."
