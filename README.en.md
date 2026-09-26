# GoTrans

On-device translation for macOS. Runs Google **Gemma 4** and Tencent **Hy-MT2** locally on Apple
Silicon through **MLX-Swift** and a curated CPU-only `llama.cpp` runtime. Once a model is
downloaded, no text you translate leaves your Mac.

[Download](https://github.com/GoDiao/gotrans/releases/latest) · [中文说明](README.md) · [Privacy Policy](PRIVACY.en.md)

## Download

Get `GoTrans-<version>.dmg` from [Releases](https://github.com/GoDiao/gotrans/releases/latest), open
it, and drag GoTrans into Applications.

macOS stops it on first launch, because GoTrans is ad-hoc signed and not notarised. Go to **System
Settings › Privacy & Security**, scroll down and click **Open Anyway** — once, and never again.
Background in [Code signing](#code-signing).

No model is downloaded automatically — pick one in settings first, see [Models](#models) below.

## What it does

- **Translate the current selection** from any app through the macOS Services menu (`⌥⌘T`)
- **Translate the clipboard** with a global hotkey (`⌥D`)
- **Results in a floating panel** that streams as it generates, can be pinned in place so long
  documents can be translated paragraph by paragraph without the panel jumping around
- **Automatic direction**: Chinese goes to English, everything else goes to Chinese — both targets
  are configurable
- **A local HTTP API** on `127.0.0.1:8765` so other tools (PopClip, Bob, Raycast, scripts) can use
  the same engine

## Requirements

- Apple Silicon Mac
- macOS 15 or later. On macOS 26 the interface uses Liquid Glass; on macOS 15 it falls back to
  standard system materials.

> **The app interface is currently Chinese only.** There is no localisation infrastructure yet,
> so every in-app label is hard-coded Chinese. Menu paths below are given in Chinese with an
> English gloss so they can be found. Localisation is open work.

## Models

Nothing is downloaded on first launch. Open **设置 › 模型** (Settings › Models), pick one, download
it, then set it as the active model.

| Model | Size | Notes |
| --- | ---: | --- |
| Qwen3.5 9B (4-bit) | ~6.0 GB | General purpose, the largest here |
| Gemma 4 E4B (4-bit) | ~5.2 GB | General purpose; also powers the free-form text actions |
| Gemma 4 E2B (4-bit) | ~3.6 GB | Smaller general-purpose option |
| Qwen3.5 4B (4-bit) | ~3.1 GB | General purpose, smaller than Gemma 4 E2B |
| Hy-MT2 1.8B (8-bit) | ~1.9 GB | Translation-specialised |
| Hy-MT2 1.8B (4-bit) | ~1.0 GB | Translation-specialised |
| Hy-MT2 1.8B (2-bit) | ~601 MB | Translation-specialised, curated GGUF |
| Hy-MT2 1.8B (1.25-bit) | ~462 MB | Translation-specialised, curated GGUF, smallest |

The two low-bit Hy-MT2 builds are downloaded as a single file pinned to an exact revision, and both
the byte count and the SHA-256 are verified afterwards. Downloads prefer Hugging Face and fall back
to ModelScope automatically.

Quantisation trades quality for size, and lower is not uniformly worse on every input — 2-bit does
not always beat 1.25-bit. Test with your own text before committing to one.

## Building from source

Not needed to use GoTrans — download the DMG instead. This is for working on the code.

You need Xcode with the macOS 26 SDK (the Liquid Glass branches are compiled behind availability
checks), XcodeGen, and the Metal toolchain. A first-time setup on a clean machine looks like this:

```bash
# 1. Xcode: accept the licence and install its system components
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

# 2. The Metal toolchain ships separately from Xcode (~840 MB).
#    Without it the MLX shaders fail with "cannot execute tool 'metal'".
xcodebuild -downloadComponent MetalToolchain

# 3. XcodeGen — no .xcodeproj is checked in, it is generated from App/project.yml
brew install xcodegen
```

Then build and run:

```bash
./script/build_and_run.sh
```

The script sets `DEVELOPER_DIR` for its own invocation only; it never changes your global
`xcode-select`. Override `DEVELOPER_DIR` before calling it to use a different Xcode.

To produce distributable artifacts in `dist/`:

```bash
./Scripts/release.sh
```

### A note on the bundled runtime

The low-bit Hy-MT2 models run on a static, CPU-only `llama.cpp` runtime shipped as a binary
XCFramework. `Package.swift` currently fetches that artifact from the original project's GitHub
release. Everything needed to rebuild it from source is in this repository — pinned upstream
commits in `Runtime/LlamaRuntime/upstream.json`, the composition patch, and a deterministic build
script:

```bash
Runtime/LlamaRuntime/build-xcframework.sh
```

Rebuilding with a different Xcode produces a different checksum than the pinned one, which is
expected; the pin exists to verify the published artifact, not to assert bit-for-bit reproducibility
across toolchains.

## Local HTTP API

Enable it in **设置 › 集成** (Settings › Integrations). Selection and hotkey translation are
in-process and work whether or not the API is running.

```bash
# Health
curl -s http://127.0.0.1:8765/health

# Translate (auto-detected direction)
curl -s -X POST http://127.0.0.1:8765/translate \
  -H 'Content-Type: application/json' \
  -d '{"text": "The quick brown fox jumps over the lazy dog."}'

# Streaming (SSE)
curl -s -N -X POST http://127.0.0.1:8765/translate \
  -H 'Content-Type: application/json' \
  -d '{"text": "今天天气真好", "stream": true}'
```

### `POST /translate`

| Field | Type | Meaning |
| --- | --- | --- |
| `text` | string | Required. Long input is truncated; the limit adapts to installed memory and can be overridden in settings. |
| `target` | string? | BCP-47 target such as `en` or `zh-Hans`. Omit for automatic direction. |
| `stream` | bool? | `true` returns Server-Sent Events. |

Response: `{"translation": "...", "detected": "en", "target": "zh-Hans", "truncated": false}`

The SSE stream emits `data: {"delta": "..."}` events, then one final event carrying the full
`translation` object, then `data: [DONE]`.

### `POST /v1/chat/completions`

Accepts the same request shape as the OpenAI chat completions endpoint, including `stream: true`,
so tools that speak that format can point at `http://127.0.0.1:8765/v1` with any API key. It takes
the last `user` message and translates it. The `model` field and system messages are ignored — this
is a translator, not a general chat endpoint, and it never contacts an external service.

### `GET /health`

`{"status": "ready"}` (200) or `{"status": "loading"}` (503).

Errors: 400 (empty text or invalid JSON), 503 (model not loaded, or the engine stayed busy for
30 s), 500 (engine failure, with details in `error`).

## PopClip

1. Run GoTrans and make sure a model is downloaded and active.
2. Double-click `popclip/GoTrans.popclipext` in Finder and accept the install prompt.
3. Select text anywhere and click the GoTrans item in the PopClip bar.

The extension calls the macOS Service, so the full result streams into the native scrollable panel
rather than a truncated preview. It does not require the HTTP API.

## Command line

```bash
xcodebuild -scheme gotrans-cli -destination 'platform=macOS' \
  -skipMacroValidation -derivedDataPath .build-cli build
.build-cli/Build/Products/Debug/gotrans-cli serve
```

Unlike the app, the CLI picks a recommended Gemma tier based on installed memory and downloads it on
first run. Other subcommands (`spike`, `engine-translate`, `hunyuan-spike`, `download-e2b`) exist for
development and diagnostics.

## Code signing

Builds are **ad-hoc signed and not notarised**, because notarisation requires a paid Apple Developer
account. macOS will refuse to open the app on first launch. To get past Gatekeeper:

**System Settings › Privacy & Security**, scroll to the blocked-app notice, choose **Open Anyway**.

Or from a terminal:

```bash
xattr -d com.apple.quarantine /Applications/GoTrans.app
```

macOS 15 Sequoia removed the old Control-click → Open shortcut, so that no longer works.

## Licence and attribution

GoTrans is released under the [MIT Licence](LICENSE).

It is derived from [GemmaTrans](https://github.com/Rand01ph/gemma-trans) by Rand01ph. The original copyright notice is retained in `LICENSE` as the licence requires.

Dependency, upstream-runtime and model licences are documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); copies are bundled inside the app. Model weights
are not distributed with this repository and remain under their own terms.
