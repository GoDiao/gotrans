#!/bin/bash
# 从一张 1024×1024 的母图生成 AppIcon.appiconset 需要的全部 10 个尺寸。
#
#   Scripts/make-icon.sh path/to/icon-1024.png
#
# 母图要求（macOS 不会自动给 App 图标加圆角遮罩，造型必须画进图里）：
#   - 1024×1024 PNG，带 alpha 通道
#   - 圆角方形（squircle）造型和阴影自己画好，四周留出透明边距
#   - 小尺寸（16pt）下仍要能辨认，别放细节和文字
#
# 只重写 PNG，不动 Contents.json——那份清单已经是对的。
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "用法: $0 <icon-1024.png>" >&2
    exit 1
fi

MASTER="$1"
ICONSET="$(cd "$(dirname "$0")/.." && pwd)/App/GoTrans/Assets.xcassets/AppIcon.appiconset"

[ -f "$MASTER" ] || { echo "❌ 找不到母图: $MASTER" >&2; exit 1; }
[ -d "$ICONSET" ] || { echo "❌ 找不到资产目录: $ICONSET" >&2; exit 1; }

WIDTH=$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')
HEIGHT=$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight/{print $2}')
if [ "$WIDTH" != "$HEIGHT" ]; then
    echo "❌ 母图必须是正方形，当前 ${WIDTH}×${HEIGHT}" >&2
    exit 1
fi
if [ "$WIDTH" -lt 1024 ]; then
    echo "❌ 母图至少 1024×1024，当前 ${WIDTH}×${WIDTH}（放大会糊）" >&2
    exit 1
fi

# 文件名 → 像素边长。与 Contents.json 的 size/scale 组合一一对应。
TARGETS=(
    "AppIcon-16.png:16"
    "AppIcon-16@2x.png:32"
    "AppIcon-32.png:32"
    "AppIcon-32@2x.png:64"
    "AppIcon-128.png:128"
    "AppIcon-128@2x.png:256"
    "AppIcon-256.png:256"
    "AppIcon-256@2x.png:512"
    "AppIcon-512.png:512"
    "AppIcon-512@2x.png:1024"
)

echo "==> 母图 ${WIDTH}×${HEIGHT}: $MASTER"
for entry in "${TARGETS[@]}"; do
    name="${entry%%:*}"
    px="${entry##*:}"
    sips -s format png -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" >/dev/null
    printf "    %-22s %s×%s\n" "$name" "$px" "$px"
done

echo "==> 完成。重新生成工程并构建即可看到新图标："
echo "    (cd App && xcodegen generate) && ./script/build_and_run.sh"
