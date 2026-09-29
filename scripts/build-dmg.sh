#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_dmg="$project_dir/build/报销单助手.dmg"
stage_dir=$(/usr/bin/mktemp -d /private/tmp/reimbursement-dmg.XXXXXX)
temporary_dmg="$stage_dir.dmg"

REIMBURSE_OUTPUT_APP="$stage_dir/报销单助手.app" "$project_dir/scripts/build-app.sh"
/bin/ln -s /Applications "$stage_dir/应用程序"

if [[ -e "$output_dmg" ]]; then
    /usr/bin/trash "$output_dmg"
fi

/usr/bin/hdiutil create -volname "报销单助手" -srcfolder "$stage_dir" -format UDZO "$temporary_dmg"
/usr/bin/ditto "$temporary_dmg" "$output_dmg"
echo "$output_dmg"
