#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app="$project_dir/build/报销单助手.app"
dmg="$project_dir/build/报销单助手.dmg"

[[ -f "$project_dir/Assets/AppIcon.png" ]]
[[ -f "$app/Contents/Resources/AppIcon.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" == "AppIcon" ]]
/usr/bin/hdiutil verify "$dmg"
/usr/bin/hdiutil imageinfo "$dmg" | /usr/bin/grep -q '报销单助手'

mount_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-dmg-check.XXXXXX)
device=$(/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg" | /usr/bin/awk '/^\/dev/{print $1; exit}')
trap '/usr/bin/hdiutil detach "$device" >/dev/null' EXIT
[[ -d "$mount_dir/报销单助手.app" ]]
[[ -L "$mount_dir/应用程序" ]]
/usr/bin/codesign --verify --deep --strict "$mount_dir/报销单助手.app"
/usr/bin/hdiutil detach "$device" >/dev/null
trap - EXIT

echo "Package checks passed"
