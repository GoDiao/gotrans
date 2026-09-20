# Privacy Policy

Last updated: 2026-09-20 · [中文](PRIVACY.md)

GoTrans is an on-device translator. **The text you translate never leaves your Mac.**

This document describes what the current source actually does. Every claim below can be checked
against this repository.

## In one sentence

GoTrans collects nothing, uploads nothing and shares nothing. The only time it reaches the network
on its own behalf is when you click to download a model.

## Network activity

At runtime GoTrans contacts exactly two hosts, and only while you are downloading a model:

| Host | When | Why |
| --- | --- | --- |
| `huggingface.co` | You start a model download in settings | Fetch model weights |
| `modelscope.cn` | Automatic fallback when Hugging Face is unreachable | Same |

There are no other outbound requests: no update checks, no usage statistics, no crash reporting, no
licence validation. Verify it yourself with Little Snitch, `lsof -i`, or any packet capture tool.

Downloading a model means interacting with Hugging Face or ModelScope, which is governed by their
own privacy policies. GoTrans attaches no information about you to those requests.

## The local HTTP API

GoTrans exposes a local API for tools such as PopClip. It:

- binds **`127.0.0.1`** (IPv4 loopback) only — it does not listen on any external interface, and
  other devices on your network cannot reach it
- is **off by default** and must be enabled in **设置 › 集成** (Settings › Integrations)
- performs no authentication, because it only ever accepts requests from this machine

Selection and hotkey translation call the engine in-process and work whether or not the API is
running.

## No data collection

The bundled `PrivacyInfo.xcprivacy` declares:

- `NSPrivacyTracking` = `false`
- `NSPrivacyTrackingDomains` — empty
- `NSPrivacyCollectedDataTypes` — empty

There is no analytics, telemetry, crash-reporting or advertising SDK anywhere in the code.

## How text reaches the app

GoTrans has two ways to receive text, **both of which you trigger explicitly**, and neither requires
Accessibility permission:

- **Services menu** (`⌥⌘T`): you select text and invoke it; macOS hands the selection to GoTrans
- **Clipboard hotkey** (`⌥D`): GoTrans reads the clipboard once, at the moment you press the key

Earlier versions used AXSelectedText and a synthetic `⌘C` to capture selections, both of which need
standing Accessibility access. That path has been removed entirely — GoTrans **does not monitor your
clipboard or screen in the background**.

## What is stored on your Mac

| Data | Location |
| --- | --- |
| Settings | `UserDefaults` suite `com.godiao.GoTrans.app` |
| Downloaded models | `~/Library/Application Support/GoTrans/models` |
| Run log | `~/Library/Logs/GoTrans/gotrans.log` |

**The log contains none of the text you translate.** It records engine lifecycle events: the active
model id, inference parameters, load and unload, and error kinds. The same entries also go to
`os_log` and are visible in Console.app.

To remove all local GoTrans data, delete those three paths.

## A note on sandboxing

Builds distributed through GitHub are **not App Sandboxed**. This is normal for Developer ID
distribution, but it does mean GoTrans is not constrained by the sandbox at the filesystem level.
Nothing above changes as a result — the network and data-collection claims are properties of the
code, and you can audit them.

## Model weights

Model weights are not distributed with this repository or the app. You download them deliberately,
and they remain subject to their own licences and terms, recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Inference runs locally; your text is never sent to the model publisher.

## Changes

This policy is versioned alongside the code. Any change affecting the behaviour described here
updates this document in the same commit, and the history is in git.

## Contact

Raise questions or concerns at [GitHub Issues](https://github.com/GoDiao/gotrans/issues).
