#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_cache="${CLIPFLOW_BUILD_CACHE:-$HOME/Library/Caches/ClipFlowTesting}"
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

# CLT 6.4 ships Swift Testing but not XCTest. Its default swiftbuild setup fails
# to load TestingMacros, and the native engine needs an explicit framework path.
if [[ -d "$testing_frameworks/Testing.framework" && -f "$testing_plugin" ]]; then
    swift test --scratch-path "$build_cache" --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" \
        -Xlinker -rpath -Xlinker "$testing_frameworks"
else
    swift test --scratch-path "$build_cache" --disable-xctest
fi
