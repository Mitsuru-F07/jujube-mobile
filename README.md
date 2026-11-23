# Jujube — Together, We Think Bigger.

**Experimental cross-platform distributed LLM inference: one iPhone 15 and one Pixel 6 Pro collaborate to execute one Inkling 2 Mini model over an authenticated local network.**

This is a **research prototype, not a finished app or one-click installation package.** The public source is sanitized. Reproduction requires manually building a matching llama.cpp runtime, acquiring model weights, device-specific pairing, network setup and signing.

## Verified milestone — November 23–24, 2026 (JST)

- **Parent:** iPhone 15 running an Objective-C++ chat and llama.cpp coordinator.
- **Worker:** Google Pixel 6 Pro running CPU-based GGML RPC behind an AndroidKeyStore TLS authentication relay. The Mac Pro is only a development/ADB host, **not** used for inference.
- **Model:** Thinking Machines Lab Inkling 2 Mini, quantization Inkling-2-Mini-AD-IQ1_S.gguf (6,881,463,904 bytes). **No model weights are included.**
- **Partitioning:** 43 of 49 logical placement slots on the Pixel RPC device. Captured model buffers: approximately 4,824.96 MiB remote, 1,726.29 MiB iPhone-local. These slots are not 49 independent physical weight layers.
- **Conversation:** real Japanese text chat over multiple turns, with a 108-token long prompt fixed by splitting prefill into 64 + 44 tokens.
- **Examples including full model loading:** 48 generated tokens / 136.208 seconds; 128 / 165.914 seconds; 128 / 181.249 seconds. See [measurements](docs/MEASUREMENTS.md). These are **not** decode-only tokens per second.
- Every turn currently reloads the weights and the test-only relay requires manual, short-lived activation.

This is **one distributed model** running across two devices, rather than a multi-agent chat or a cloud-backed inference service. It does not prove GPU inference on the Pixel, persistence, unrestricted portability, multimodal processing or production-grade pairing.

## Source layout

| Component | Purpose | Validation |
| --- | --- | --- |
| [ios/jujube-split-test](ios/jujube-split-test) | iPhone chat UI, model checksum, split llama.cpp backend, pinned TLS client | Yes: physical iPhone 15 |
| [android/pixel-tls-relay](android/pixel-tls-relay) | Pixel AndroidKeyStore TLS gateway to locally bound CPU GGML RPC worker | Yes: physical Pixel 6 Pro |
| [docs](docs) | Security, results, architecture and manual build setup | Documentation |

A separate development-stage Android Jujube Node implements discovery and other prototypes. **That Node app was not the verified Inkling split-compute worker**; it is intentionally not presented here as one.

## Reproduction

Read [Build and provisioning](docs/BUILD.md), [Architecture](docs/ARCHITECTURE.md), and [Security](docs/SECURITY.md).

1. Obtain licensed GGUF weights from the model publisher/quantization provider.
2. Build matching upstream [llama.cpp](https://github.com/ggml-org/llama.cpp) revision **56eea9e4b0f5d125da16b75b551440b170aa8b1f** with CPU and RPC support for the target platforms.
3. Provision **your own** Pixel LAN address and public-key trust pins. Published source deliberately uses reserved **192.0.2.1** and **64-zero SHA-256 placeholder pins**, so it does **not** connect out of the box.
4. Manually start a loopback-only RPC CPU worker on Pixel and its bounded, authenticated TLS relay; then build, sign and open the iPhone test app.

No private keys, personal device pins, signing assets, model weights, APK/IPA, user conversations, machine-specific build paths or device backups are included.

## Credits and licensing

- [Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) by Thinking Machines Lab, model license **Apache-2.0**. The tested GGUF quantization is separately obtainable from providers including [AtomicChat](https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF).
- [llama.cpp](https://github.com/ggml-org/llama.cpp) by ggml-org, upstream **MIT** license, used as an external runtime (not bundled).
- No reuse license has yet been granted for original Jujube prototype source. Public visibility alone does not imply permission to redistribute, modify or commercially use these files. Third-party components retain their own terms.

## 日本語

**Jujube（ジュジュベ）**は、iPhone 15を親機、Pixel 6 Proを子機として、**1つのLLMを2台のスマートフォンへ分散して実行する**研究プロトタイプです。

2026年11月23〜24日に、Inkling 2 Miniの分散推論と日本語の複数ターン会話を実機確認しました。49の論理配置スロットのうち43をPixel側へ割り当てています。現在は毎回モデルを読み込むため、1回の回答に約2〜3分かかります。

公開コードでは端末固有のIP、認証ピン、開発者のローカルパスを安全なサンプルに置き換えています。**そのまま実行できる完成品ではなく、モデル・認証鍵・通信・ビルドの準備が必要です。**

**「小さな力を合わせて、大きな知恵に。」**
