#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_cache="${CLIPFLOW_BUILD_CACHE:-$HOME/Library/Caches/ClipFlowBuild}"
stage="${1:-m1}"
if [[ "$stage" == m0 ]]; then
  products=(ClipFlowProbe ClipFlowTarget)
  local_apps="$HOME/Applications/ClipFlow M0"
  archive="dist/ClipFlow-M0.zip"
elif [[ "$stage" == m1 ]]; then
  products=(ClipFlowApp)
  local_apps="${CLIPFLOW_INSTALL_DIR:-$HOME/Applications}"
  archive="dist/ClipFlow-0.6.1.zip"
else
  echo "Usage: $0 [m0|m1]" >&2
  exit 2
fi
swift build --scratch-path "$build_cache" -c release
binary_directory=$(swift build --scratch-path "$build_cache" -c release --show-bin-path)
for product in $products; do
  app_name="$product"
  [[ "$product" == ClipFlowApp ]] && app_name=ClipFlow
  bundle="$build_cache/Bundles/$stage/${app_name}.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$binary_directory/$product" "$bundle/Contents/MacOS/$product"
  if [[ "$product" == ClipFlowProbe ]]; then
    display="ClipFlow M0"
    identifier="local.lrc.clipflow.m0"
    agent=true
    version="0.0.1"
  elif [[ "$product" == ClipFlowTarget ]]; then
    display="ClipFlow M0 Target"
    identifier="local.lrc.clipflow.m0.target"
    agent=false
    version="0.0.1"
  else
    display="ClipFlow"
    identifier="local.lrc.clipflow"
    agent=true
    version="0.6.1"
  fi
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>$display</string>
<key>CFBundleDisplayName</key><string>$display</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><$agent/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  # File-provider folders may add Finder display metadata to generated bundles.
  # Remove only this cosmetic attribute from our build product, never quarantine/security data.
  xattr -rd com.apple.FinderInfo "$bundle" 2>/dev/null || true
  codesign --force --sign - "$bundle"
  codesign --verify --strict "$bundle"
  # A file provider reattaches FinderInfo even after stripping it, making loose bundles
  # invalid. Keep runnable apps on the local disk and deliver a ZIP in the project.
  mkdir -p "$local_apps" dist
  ditto --norsrc --noextattr "$bundle" "$local_apps/${app_name}.app"
  codesign --verify --strict "$local_apps/${app_name}.app"
done
ditto -c -k --keepParent --norsrc "$build_cache/Bundles/$stage" "$archive"
echo "$stage apps: $local_apps (local ad-hoc signature; not notarized). ZIP: $PWD/$archive"
