#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Explicit controlled test only; never called by build.sh/test.sh.
# This is an independent general-pasteboard writer, NOT a physical Command+C.
# Run after selecting clipboard paste mode with a 500 ms wait in the M1 app.
# After stdout {"armed":true}, trigger the app once with real Option+1.
# Avoid other copies during the test. A 60 s trigger timeout performs no write.
# The known NewCopy fixture remains on the clipboard; no old contents are saved.
external_copy_cache="${CLIPFLOW_EXTERNAL_COPY_CACHE:-$HOME/Library/Caches/ClipFlowExternalCopy}"
mkdir -p "$external_copy_cache"
xcrun swiftc -swift-version 5 -parse-as-library -O \
    Sources/ClipFlowCore/PasteboardSnapshot.swift \
    scripts/external_copy_probe.swift \
    -o "$external_copy_cache/ClipFlowExternalCopyProbe"
exec "$external_copy_cache/ClipFlowExternalCopyProbe"
