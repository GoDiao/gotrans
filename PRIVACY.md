# 隐私政策

最后更新：2026-09-20 · [English](PRIVACY.en.md)

GoTrans 是一个本地翻译工具。**你翻译的文本不会离开这台 Mac。**

这份文档描述的是当前源码的实际行为，每一条都可以在本仓库中核对。

## 一句话总结

GoTrans 不收集、不上传、不共享任何个人数据。它唯一会主动联网的时刻，是你点击下载模型的时候。

## 联网行为

运行时 GoTrans 只会连接下面两个地址，且仅在你主动下载模型时：

| 地址 | 时机 | 用途 |
| --- | --- | --- |
| `huggingface.co` | 你在设置中点击下载模型 | 下载模型权重 |
| `modelscope.cn` | Hugging Face 不可用时自动回退 | 同上 |

除此之外没有任何出站请求：没有更新检查、没有使用统计、没有崩溃上报、没有许可证校验。你可以用
Little Snitch、`lsof -i` 或任何抓包工具自行验证。

模型下载会与 Hugging Face 或 ModelScope 发生交互，这部分受各自的隐私政策约束。GoTrans 不会在这些
请求中附带你的任何信息。

## 本地 HTTP API

GoTrans 提供一个本地 API 供 PopClip 等工具调用。它：

- 只绑定 **`127.0.0.1`**（IPv4 回环），不监听任何对外网络接口，同一局域网内的其他设备无法访问
- 需要你在**设置 › 集成**中手动开启，默认关闭
- 不做任何鉴权，因为它本就只接受本机请求

划词翻译和快捷键翻译是进程内直接调用引擎，无论这个 API 开不开都能工作。

## 不收集任何数据

App 内置的 `PrivacyInfo.xcprivacy` 声明：

- `NSPrivacyTracking` = `false`（不做追踪）
- `NSPrivacyTrackingDomains` 为空
- `NSPrivacyCollectedDataTypes` 为空（不收集任何类别的数据）

代码中不包含任何分析、遥测、崩溃上报或广告 SDK。

## 文本是怎么被读取的

GoTrans 有两条获取待翻译文本的通道，**都必须由你主动触发**，且都不需要「辅助功能」权限：

- **服务菜单**（`⌥⌘T`）：你选中文字后主动调用，由 macOS 把选中内容交给 GoTrans
- **剪贴板快捷键**（`⌥D`）：你按下快捷键时，GoTrans 才去读一次剪贴板

早期版本曾用 AXSelectedText 和模拟 `⌘C` 来读取选中文本，这两种方式都需要常驻的辅助功能权限。
当前版本已完全移除该路径——GoTrans **不会在后台监听你的剪贴板或屏幕内容**。

## 本机保存了什么

| 内容 | 位置 |
| --- | --- |
| 设置项 | `UserDefaults` suite `com.godiao.GoTrans.app` |
| 已下载的模型 | `~/Library/Application Support/GoTrans/models` |
| 运行日志 | `~/Library/Logs/GoTrans/gotrans.log` |

**日志不包含你翻译的任何文本。** 它记录的是引擎生命周期事件：当前模型 id、推理参数、加载与卸载、
错误类型。同样的内容也会写入 `os_log`，可在「控制台」App 中查看。

要彻底清除 GoTrans 的全部本地数据，删掉上述三个路径即可。

## 沙盒说明

通过 GitHub 分发的版本**未启用 App 沙盒**。这是 Developer ID 分发的常见做法，但意味着 GoTrans
在文件系统权限上不受沙盒限制。上面关于联网和数据收集的所有陈述不因此改变——它们由代码本身保证，
你可以审计。

## 模型权重

模型权重不随本仓库或 App 分发，由你主动下载，并受其各自的许可证与条款约束。相关许可证记录在
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

模型在本机执行推理，不会把你的文本发送给模型发布方。

## 变更

这份政策随代码一起版本管理。任何影响上述行为的改动都会同时更新本文档，历史可在 git 记录中查阅。

## 联系

问题或疑虑请在 [GitHub Issues](https://github.com/GoDiao/gotrans/issues) 提出。
