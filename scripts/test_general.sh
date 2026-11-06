#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Explicit M0 manual test. Never invoked by build.sh or test.sh.
# This compiles a separate CLI and never rebuilds or changes either .app's signature.
# stdout: one metadata-only JSON line per fixture (PNG, then RTF/HTML).
# exit 0: both passed; 1: failure; 2: user must handle clipboard access;
# exit 3: an external copy won and remaining tests were stopped.
# No window, CGEvent, or system permission setting is operated by this script.
roundtrip_cache="${CLIPFLOW_GENERAL_TEST_CACHE:-$HOME/Library/Caches/ClipFlowGeneralRoundtrip}"
mkdir -p "$roundtrip_cache"
xcrun swiftc -swift-version 5 -parse-as-library -O \
    Sources/ClipFlowCore/PasteboardSnapshot.swift \
    Sources/ClipFlowCore/PasteboardLease.swift \
    scripts/general_roundtrip.swift \
    -o "$roundtrip_cache/ClipFlowGeneralRoundtrip"
exec "$roundtrip_cache/ClipFlowGeneralRoundtrip"
