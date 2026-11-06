#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

raw_probe_cache="${CLIPFLOW_RAW_KEY_CACHE:-$HOME/Library/Caches/ClipFlowRawKeyProbe}"
raw_probe_binary="$raw_probe_cache/raw-key-probe"
raw_probe_source="$PWD/scripts/raw_key_probe.swift"

if [[ "${1:-}" == "--typecheck" ]]; then
    xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macosx14.0 "$raw_probe_source"
    exit 0
fi

if [[ $# -eq 0 ]]; then
    print -u2 'Usage: scripts/test_raw_keys.sh --preflight | --build-only | --typecheck | --target-pid N --count 15 --output PATH'
    print -u2 'No default observation. Listening requires explicit target PID and output arguments.'
    exit 2
fi

mkdir -p "$raw_probe_cache"
if [[ ! -x "$raw_probe_binary" || "$raw_probe_source" -nt "$raw_probe_binary" ]]; then
    xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 "$raw_probe_source" -o "$raw_probe_binary"
fi

if [[ "${1:-}" == "--build-only" ]]; then
    print -r -- "Built standalone passive observer: $raw_probe_binary"
    print -r -- 'No tap installed, no events observed, no ClipFlow App binary changed.'
    exit 0
fi

# --preflight only checks existing permission state. The Swift executable never
# requests permission or injects an event, including when observation is denied.
exec "$raw_probe_binary" "$@"
