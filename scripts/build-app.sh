#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_app="${REIMBURSE_OUTPUT_APP:-$project_dir/build/报销单助手.app}"
work_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-app-build.XXXXXX)
app_dir="$work_dir/报销单助手.app"
contents_dir="$app_dir/Contents"
icon_source="$project_dir/Assets/AppIcon.png"
iconset_dir="$work_dir/AppIcon.iconset"

export CLANG_MODULE_CACHE_PATH="$work_dir/clang-cache"
export SWIFT_MODULECACHE_PATH="$work_dir/swift-cache"

cd "$project_dir"
/usr/bin/swift build --disable-sandbox --cache-path "$work_dir/cache" --manifest-cache local --configuration release -debug-info-format none --scratch-path "$work_dir/swift-build" --product ReimburseMacApp
binary_dir=$(/usr/bin/swift build --disable-sandbox --cache-path "$work_dir/cache" --manifest-cache local --configuration release --scratch-path "$work_dir/swift-build" --show-bin-path)

/bin/mkdir -p "$contents_dir/MacOS"
/bin/cp "$binary_dir/ReimburseMacApp" "$contents_dir/MacOS/ReimburseMacApp"
/bin/chmod 755 "$contents_dir/MacOS/ReimburseMacApp"

/bin/mkdir -p "$contents_dir/Resources" "$iconset_dir"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    /usr/bin/sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/swift "$project_dir/scripts/make-icns.swift" "$iconset_dir" "$contents_dir/Resources/AppIcon.icns"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>报销单助手</string>
    <key>CFBundleExecutable</key><string>ReimburseMacApp</string>
    <key>CFBundleIdentifier</key><string>top.kjoe.ReimburseMacApp</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>报销单助手</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.8</string>
    <key>CFBundleVersion</key><string>12</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$app_dir"
/usr/bin/codesign --force --sign - "$app_dir"
/bin/mkdir -p "${output_app:h}"
/usr/bin/ditto "$app_dir" "$output_app"
/usr/bin/xattr -cr "$output_app"
/usr/bin/codesign --force --sign - "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"
echo "$output_app"
