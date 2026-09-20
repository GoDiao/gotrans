#!/bin/zsh
# 构建并打包，产出 dist/GoTrans-<版本>.zip 与 dist/GoTrans-<版本>.dmg
#
# 免费分发方案：工程使用 ad-hoc 签名（CODE_SIGN_IDENTITY: "-"），不需要任何 Apple
# 开发者账号，因此也无法公证（notarytool 只接受付费账号的 App Store Connect 凭据）。
# 后果是用户首次打开会被 Gatekeeper 拦下，脚本结尾会打印规避方式。
#
# 将来购买 Developer ID 证书后要恢复公证，需要三处改动：
#   1. App/project.yml 的 Release config：CODE_SIGN_IDENTITY 改回
#      "Developer ID Application"，并加回 ENABLE_HARDENED_RUNTIME 与 --timestamp；
#   2. 本脚本：恢复 notarytool 提交与 stapler 装订；
#   3. .github/workflows/release-macos.yml：恢复证书导入与 ASC API Key 写入。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="App"
VERSION=$(grep 'MARKETING_VERSION' $APP_DIR/project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')

echo "==> 构建 Release $VERSION"
cd $APP_DIR
xcodegen generate >/dev/null
# 完整输出写日志：失败时 tail -2 只会留下一行无意义的警告，看不到真正的错误。
BUILD_LOG="$(mktemp -t gotrans-release-build)"
if xcodebuild -project GoTrans.xcodeproj -scheme GoTrans -configuration Release \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath build-release build > "$BUILD_LOG" 2>&1; then
    tail -2 "$BUILD_LOG"
else
    echo "❌ 构建失败，以下为末尾 40 行：" >&2
    tail -40 "$BUILD_LOG" >&2
    echo "完整日志：$BUILD_LOG" >&2
    exit 1
fi
APP="build-release/Build/Products/Release/GoTrans.app"
[ -d "$APP" ] || { echo "❌ 构建报告成功但产物不存在：$APP" >&2; exit 1; }

echo "==> 校验签名"
codesign --verify --deep --strict "$APP"
# 一次取出后用变量判断。不要写成 codesign ... | grep -q：grep -q 命中即退出并关闭管道，
# codesign 收到 SIGPIPE 退出 141，pipefail 会把它当成整条管道失败，造成误判。
# ad-hoc 签名的 TeamIdentifier 为 not set、没有 Authority 行，这是预期结果。
SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
printf '%s\n' "$SIGN_INFO" | grep -E "Identifier=|Signature=|TeamIdentifier=" || true
case "$SIGN_INFO" in
    *"Signature=adhoc"*) ;;
    *)
        echo "❌ 期望 ad-hoc 签名，实际不是。检查 App/project.yml 的 CODE_SIGN_IDENTITY。" >&2
        exit 1
        ;;
esac

echo "==> 打包 ZIP"
mkdir -p ../dist
ZIP="../dist/GoTrans-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 生成 DMG（拖拽安装）"
DMG="../dist/GoTrans-$VERSION.dmg"
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
    # create-dmg 偶发非零退出但产物正常，故临时关 -e，事后校验产物存在
    set +e
    create-dmg \
        --volname "GoTrans" \
        --window-size 600 360 \
        --icon "GoTrans.app" 150 185 \
        --app-drop-link 450 185 \
        "$DMG" "$APP"
    set -e
else
    echo "   （create-dmg 未安装，用 hdiutil 生成基础 DMG；brew install create-dmg 可得带背景的拖拽版）"
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "GoTrans" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
fi
[ -f "$DMG" ] || { echo "❌ DMG 生成失败"; exit 1; }

# 没有公证就没有 Apple 背书，改用校验和让下载者能自行确认文件完整。
echo "==> 产物校验和（SHA-256）"
shasum -a 256 "$ZIP" "$DMG" | sed 's|../dist/|dist/|'

cat <<'NOTE'

⚠️  本产物为 ad-hoc 签名、未公证。用户首次打开会被 Gatekeeper 拦下，需要：
      系统设置 › 隐私与安全性 › 下滑到「已阻止使用」› 仍要打开
    或在终端执行：
      xattr -d com.apple.quarantine /Applications/GoTrans.app
    注意 macOS 15 Sequoia 起已移除「右键 → 打开」这一绕过方式，不要再这样引导用户。
NOTE

echo "✅ 完成: $ZIP"
echo "✅ 完成: $DMG"
