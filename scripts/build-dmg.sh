#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_dmg="$project_dir/build/报销单助手-1.35.dmg"
if [[ -e "$output_dmg" ]]; then
    echo "安装包已存在，为避免覆盖请先核对已有文件：$output_dmg" >&2
    exit 1
fi
stage_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-dmg.XXXXXX)
temporary_dmg="$stage_dir.dmg"

REIMBURSE_VISION_TEST=0 REIMBURSE_OUTPUT_APP="$stage_dir/报销单助手.app" "$project_dir/scripts/build-app.sh"
/bin/ln -s /Applications "$stage_dir/应用程序"

/usr/bin/hdiutil create -volname "报销单助手" -srcfolder "$stage_dir" -format UDZO "$temporary_dmg"
/usr/bin/ditto "$temporary_dmg" "$output_dmg"
/usr/bin/hdiutil verify "$output_dmg"
echo "$output_dmg"
