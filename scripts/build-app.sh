#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
vision_test="${REIMBURSE_VISION_TEST:-0}"
app_name="报销单助手"
bundle_identifier="top.kjoe.ReimburseMacApp"
app_version="1.34"
app_build="38"
swift_flags=()
if [[ "$vision_test" == 1 ]]; then
    app_name="报销单助手·视觉测试"
    bundle_identifier="top.kjoe.ReimburseMacApp.vision-test"
    app_version="1.34.908"
    app_build="908"
    swift_flags=(-Xswiftc -DREIMBURSE_VISION_TEST)
fi
output_app="${REIMBURSE_OUTPUT_APP:-$project_dir/build/$app_name.app}"
if [[ "$vision_test" == 1 && "${output_app:t}" != "$app_name.app" ]]; then
    echo "视觉测试版必须使用独立应用文件名：$app_name.app" >&2
    exit 1
fi
work_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-app-build.XXXXXX)
app_dir="$work_dir/$app_name.app"
contents_dir="$app_dir/Contents"
icon_source="$project_dir/Assets/AppIcon.png"
iconset_dir="$work_dir/AppIcon.iconset"

export CLANG_MODULE_CACHE_PATH="$work_dir/clang-cache"
export SWIFT_MODULECACHE_PATH="$work_dir/swift-cache"

cd "$project_dir"
/usr/bin/swift build --disable-sandbox --cache-path "$work_dir/cache" --manifest-cache local --configuration release -debug-info-format none --scratch-path "$work_dir/swift-build" --product ReimburseMacApp "${swift_flags[@]}"
binary_dir=$(/usr/bin/swift build --disable-sandbox --cache-path "$work_dir/cache" --manifest-cache local --configuration release --scratch-path "$work_dir/swift-build" --show-bin-path "${swift_flags[@]}")

/bin/mkdir -p "$contents_dir/MacOS"
/bin/cp "$binary_dir/ReimburseMacApp" "$contents_dir/MacOS/ReimburseMacApp"
/bin/chmod 755 "$contents_dir/MacOS/ReimburseMacApp"

/bin/mkdir -p "$contents_dir/Resources" "$iconset_dir"
if [[ "$vision_test" == 1 ]]; then
    icon_source="$work_dir/VisionTestIcon.png"
    /usr/bin/swift -module-cache-path "$work_dir/swift-cache" "$project_dir/scripts/make-vision-test-icon.swift" "$icon_source"
fi
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    /usr/bin/sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/swift "$project_dir/scripts/make-icns.swift" "$iconset_dir" "$contents_dir/Resources/AppIcon.icns"

cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>$app_name</string>
    <key>CFBundleExecutable</key><string>ReimburseMacApp</string>
    <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>$app_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$app_version</string>
    <key>CFBundleVersion</key><string>$app_build</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$vision_test" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :ReimbursementVisionTest bool true" "$contents_dir/Info.plist"
fi

release_remote=$(/usr/bin/git -C "$project_dir" remote get-url origin)
if [[ "$release_remote" == https://github.com/* ]]; then
    release_repository="${release_remote#https://github.com/}"
elif [[ "$release_remote" == git@github.com:* ]]; then
    release_repository="${release_remote#git@github.com:}"
else
    echo "无法从 origin 读取 GitHub 更新仓库" >&2
    exit 1
fi
release_repository="${release_repository%.git}"
if [[ ! "$release_repository" =~ '^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$' ]]; then
    echo "GitHub 更新仓库格式无效" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Add :ReimbursementGitHubRepository string $release_repository" "$contents_dir/Info.plist"

/usr/bin/xattr -cr "$app_dir"
/usr/bin/codesign --force --sign - "$app_dir"
/bin/mkdir -p "${output_app:h}"
/usr/bin/ditto "$app_dir" "$output_app"
/usr/bin/xattr -cr "$output_app"
/usr/bin/codesign --force --sign - "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"
echo "$output_app"
