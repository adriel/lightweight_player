#!/bin/zsh
cd "${0:a:h}/.."
xcodegen generate -q >/dev/null && xcodebuild -project LightPlayer.xcodeproj -scheme ${SCHEME:-LightPlayer} -configuration ${CONFIG:-Release} -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: unre|BUILD (SUCC|FAIL)" | grep -v "CoreSimulator" | head -${LINES_MAX:-40}
