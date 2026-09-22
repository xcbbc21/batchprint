#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
deliver_dir="${1:-$project_dir/dist}"
mkdir -p "$deliver_dir" "$project_dir/.cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.cache"
for arch in arm64 x86_64; do
 swift build --package-path "$project_dir" --disable-sandbox --cache-path "$project_dir/.cache" --scratch-path "$project_dir/.build-$arch" --triple "$arch-apple-macosx14.0" -c release
done
app_dir="$deliver_dir/批量打印.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create "$project_dir/.build-arm64/arm64-apple-macosx/release/BatchPrint" "$project_dir/.build-x86_64/x86_64-apple-macosx/release/BatchPrint" -output "$app_dir/Contents/MacOS/BatchPrint"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
if [ -f "$project_dir/Resources/AppIcon.icns" ]; then cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/"; fi
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
