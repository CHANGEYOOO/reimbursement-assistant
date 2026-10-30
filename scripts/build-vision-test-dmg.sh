#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_name="报销单助手·视觉测试"
output_dmg="$project_dir/build/报销单助手-视觉测试-1.34.909.dmg"
if [[ -e "$output_dmg" ]]; then
    echo "测试安装包已存在，为避免覆盖请先核对已有文件：$output_dmg" >&2
    exit 1
fi
stage_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-vision-test-dmg.XXXXXX)
temporary_dmg="$stage_dir.dmg"

REIMBURSE_VISION_TEST=1 REIMBURSE_OUTPUT_APP="$stage_dir/$app_name.app" "$project_dir/scripts/build-app.sh"
/bin/ln -s /Applications "$stage_dir/应用程序"
/bin/mkdir -p "${output_dmg:h}"
/usr/bin/hdiutil create -volname "$app_name" -srcfolder "$stage_dir" -format UDZO "$temporary_dmg"
/usr/bin/ditto "$temporary_dmg" "$output_dmg"
/usr/bin/hdiutil verify "$output_dmg"
echo "$output_dmg"
