# LlamaRuntime

GoTrans uses a curated, CPU-only `llama.cpp` runtime for exactly two Hy-MT2 v2 GGUF files. The app does not expose arbitrary GGUF loading.

The runtime is reconstructed from the fixed STQ PR head recorded in `upstream.json`, then `patches/combined.patch` ports the fixed Q2_0C/KleidiAI PR and applies GoTrans's type-number, old-STQ-layout, EOG, and per-model KleidiAI compatibility changes. No long-lived fork is required.

The XCFramework includes only the audited `llama-common` object closure required by chat-template/Jinja formatting. The build fails if download/HTTP symbols are present; tools, server, CURL, subprocess helpers, telemetry and Metal are not part of the runtime surface.

Build the static macOS arm64 XCFramework and deterministic ZIP with:

```sh
Runtime/LlamaRuntime/build-xcframework.sh
```

The script targets macOS 15.0 or later, prints the ZIP SHA-256 and SwiftPM checksum, and rejects archive members with a newer minimum OS. Release assets are immutable and use the tag `runtime-llama-1.0.0-r1`.

Published asset URL:

```text
https://github.com/GoDiao/gotrans/releases/download/runtime-llama-1.0.0-r1/LlamaRuntime-1.0.0-r1.zip
```

The expected asset and composition-patch digests are recorded in `CHECKSUMS.txt`.

`gt_llama_validate_prompt` tokenizes the complete chat template and reserves output capacity
without modifying KV state. Generation repeats this check before decoding. The Swift bridge maps
capacity rejection to `TranslationError.promptTooLong`.

Run `Tests/RuntimeGate.cpp` against the two pinned model files before publishing the asset. The gate loads 1.25-bit, translates 20 times, completely unloads it, loads 2-bit and translates 20 times, then unloads and switches back to 1.25-bit.

## Versioning

`1.0.0-r1` is the first runtime built under the GoTrans name. It corresponds to what GemmaTrans
published as `2.2.0-r1`, rebuilt after renaming the internal symbols (`gotrans_enabled`,
`GOTRANS_DISABLE_KLEIDIAI`) and the bridge source (`GTLlamaRuntime.cpp/.h`). The upstream
`llama.cpp` and KleidiAI revisions pinned in `upstream.json` are unchanged.

Rebuilding with a different Xcode produces a different checksum. The digests in `CHECKSUMS.txt`
identify the published artifact; they are not a claim of bit-for-bit reproducibility across
toolchains.
