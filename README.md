# GoTrans

macOS 本地翻译。通过 **MLX-Swift** 和一套策展的纯 CPU `llama.cpp` 运行时，在 Apple Silicon 上本地
运行 Google **Gemma 4** 与腾讯 **Hy-MT2**。模型下载完成后，你翻译的文本不会离开这台 Mac。

[下载最新版](https://github.com/GoDiao/gotrans/releases/latest) · [English](README.en.md) · [隐私政策](PRIVACY.md)

## 下载

从 [Releases](https://github.com/GoDiao/gotrans/releases/latest) 下载 `GoTrans-<版本>.dmg`，打开后把
GoTrans 拖进「应用程序」。

**首次打开会被系统拦下。** GoTrans 使用 ad-hoc 签名、未经 Apple 公证，放行方式见[代码签名](#代码签名)。

启动后不会自动下载任何模型，需要自己在设置里选一个，见下面的[模型](#模型)一节。

## 能做什么

- **翻译当前选中的文字**，在任意 App 中通过 macOS 服务菜单触发（`⌥⌘T`）
- **翻译剪贴板**，全局快捷键 `⌥D`
- **结果显示在浮窗里**，边生成边流式输出；浮窗可以固定位置，逐段翻译长文时不会乱跳
- **自动判断方向**：中文译为英文，其他语言译为中文——两个目标语言都可以改
- **本地 HTTP API**，监听 `127.0.0.1:8765`，PopClip、Bob、Raycast 或你自己的脚本可以直接调用同一个引擎

## 系统要求

- Apple Silicon Mac
- macOS 15 或更高版本。macOS 26 上界面使用 Liquid Glass，macOS 15 上回退为标准系统材质。

## 模型

首次启动不会自动下载任何东西。进入**设置 › 模型**，选一个下载，然后设为当前使用。

| 模型 | 体积 | 说明 |
| --- | ---: | --- |
| Gemma 4 E4B (4-bit) | 约 4.9 GB | 通用模型，文本处理功能也依赖它 |
| Gemma 4 E2B (4-bit) | 约 3.6 GB | 更小的通用模型 |
| Hy-MT2 1.8B (8-bit) | 约 1.9 GB | 翻译专用 |
| Hy-MT2 1.8B (4-bit) | 约 1.1 GB | 翻译专用 |
| Hy-MT2 1.8B (2-bit) | 约 600 MB | 翻译专用，策展 GGUF |
| Hy-MT2 1.8B (1.25-bit) | 约 462 MB | 翻译专用，策展 GGUF，体积最小 |

两款低比特 Hy-MT2 以单文件形式下载，锁定到确切的 revision，下载完成后校验字节数和 SHA-256。下载
优先走 Hugging Face，不可用时自动回退 ModelScope。

量化是拿质量换体积，而且并非位数越低就一定越差——2-bit 不保证在每个输入上都优于 1.25-bit。建议用
你自己常用的文本实测后再决定。

## 从源码构建

使用 GoTrans 不需要这一步，下载 DMG 即可。以下是给要改代码的人的。

需要带 macOS 26 SDK 的 Xcode（Liquid Glass 的分支是在可用性检查保护下编译的）、XcodeGen，以及
Metal 工具链。在一台干净的机器上，首次配置是这样：

```bash
# 1. Xcode：同意许可协议，安装系统组件
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

# 2. Metal 工具链不随 Xcode 提供，需要单独下载（约 840 MB）。
#    缺它的话 MLX 的着色器会报 "cannot execute tool 'metal'"。
xcodebuild -downloadComponent MetalToolchain

# 3. XcodeGen —— 仓库里不存 .xcodeproj，由 App/project.yml 现生成
brew install xcodegen
```

然后构建并运行：

```bash
./script/build_and_run.sh
```

该脚本只为自己这次调用设置 `DEVELOPER_DIR`，不会修改你的全局 `xcode-select`。想用别的 Xcode，
调用前覆盖 `DEVELOPER_DIR` 即可。

产出可分发的构件到 `dist/`：

```bash
./Scripts/release.sh
```

### 关于内置运行时

低比特 Hy-MT2 跑在一套静态的、纯 CPU 的 `llama.cpp` 运行时上，以二进制 XCFramework 形式提供。
`Package.swift` 目前从原项目的 GitHub release 拉取这个构件。从源码重建它所需的一切都在本仓库里
——`Runtime/LlamaRuntime/upstream.json` 里固定的上游 commit、合成补丁，以及一个确定性构建脚本：

```bash
Runtime/LlamaRuntime/build-xcframework.sh
```

用不同版本的 Xcode 重建会得到与固定值不同的校验和，这是正常的；那个固定值的作用是校验已发布的
构件，而不是声称跨工具链的逐字节可重现。

## 本地 HTTP API

在**设置 › 集成**中开启。划词和快捷键翻译是进程内调用，无论 API 开不开都能用。

```bash
# 健康检查
curl -s http://127.0.0.1:8765/health

# 翻译（自动判断方向）
curl -s -X POST http://127.0.0.1:8765/translate \
  -H 'Content-Type: application/json' \
  -d '{"text": "The quick brown fox jumps over the lazy dog."}'

# 流式（SSE）
curl -s -N -X POST http://127.0.0.1:8765/translate \
  -H 'Content-Type: application/json' \
  -d '{"text": "今天天气真好", "stream": true}'
```

### `POST /translate`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `text` | string | 必填。过长会被截断；上限随机器内存自动调整，也可以在设置里手动覆盖。 |
| `target` | string? | BCP-47 目标语言码，如 `en`、`zh-Hans`。省略则自动判断方向。 |
| `stream` | bool? | `true` 返回 Server-Sent Events。 |

响应：`{"translation": "...", "detected": "en", "target": "zh-Hans", "truncated": false}`

SSE 流先发若干 `data: {"delta": "..."}`，然后一条携带完整 `translation` 对象的事件，最后是
`data: [DONE]`。

### `POST /v1/chat/completions`

接受与 OpenAI chat completions 相同的请求格式（含 `stream: true`），所以支持该格式的工具可以直接
指向 `http://127.0.0.1:8765/v1`，API key 随便填。它取最后一条 `user` 消息做翻译。`model` 字段和
system 消息会被忽略——这是个翻译器，不是通用聊天接口，而且全程本地，不连任何外部服务。

### `GET /health`

`{"status": "ready"}`（200）或 `{"status": "loading"}`（503）。

错误码：400（空文本或无效 JSON）、503（模型未加载，或引擎繁忙超过 30 秒）、500（引擎错误，详情在
`error` 字段）。

## PopClip

1. 运行 GoTrans，确保已经下载并启用了一个模型。
2. 在 Finder 里双击 `popclip/GoTrans.popclipext`，按提示安装。
3. 在任意 App 中选中文字，点击 PopClip 弹条里的 GoTrans。

这个扩展调用的是 macOS 服务，因此完整译文会流式显示在原生的可滚动浮窗里，而不是被截断的预览。
它不需要开启 HTTP API。

## 命令行

```bash
xcodebuild -scheme gotrans-cli -destination 'platform=macOS' \
  -skipMacroValidation -derivedDataPath .build-cli build
.build-cli/Build/Products/Debug/gotrans-cli serve
```

与 App 不同，CLI 会按机器内存挑一档推荐的 Gemma 并在首次运行时自动下载。其余子命令
（`spike`、`engine-translate`、`hunyuan-spike`、`download-e2b`）用于开发和诊断。

## 代码签名

构建产物是 **ad-hoc 签名、未经公证**的，因为公证需要付费的 Apple 开发者账号。macOS 首次打开时会
拒绝运行。绕过 Gatekeeper 的方式：

**系统设置 › 隐私与安全性**，下滑到被阻止的提示，选择**仍要打开**。

或者在终端执行：

```bash
xattr -d com.apple.quarantine /Applications/GoTrans.app
```

macOS 15 Sequoia 起已经移除了旧的「按住 Control 点按 → 打开」这条路径，那个方法不再有效。

## 许可证与归属

GoTrans 以 [MIT 许可证](LICENSE) 发布。

本项目衍生自 Rand01ph 的 [GemmaTrans](https://github.com/Rand01ph/gemma-trans)。
按许可证要求，原始版权声明保留在 `LICENSE` 中。

依赖、上游运行时和模型的许可证记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，副本会打包
进 App 内。模型权重不随本仓库分发，并受其各自条款约束。
