# Acknowledgements / 謝辞

Jujube is an independent experiment built on model research, quantization, open-source inference software and mobile platform APIs developed by others. We are grateful to their authors and contributors.

**Jujube did not create the original model, its GGUF quantization, the llama.cpp inference engine, or the GGML RPC protocol.**

## Original model — Thinking Machines Lab

**[Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini)** is a multimodal, looped mixture-of-experts model developed and released by **Thinking Machines Lab, Inc.** on November 20, 2026. Jujube uses its text generation capability in the verified distributed-phone experiment; no image-input path was validated in this test.

Sources: [official model card](https://thinkingmachines.ai/model-card/inkling-2-mini/) · [weights and upstream model](https://huggingface.co/thinkingmachines/Inkling-2-Mini).

Model license published by the provider: **Apache-2.0**. Jujube did not train or author these weights.

## Quantization — AtomicChat

**[AtomicChat / Inkling-2-Mini-GGUF](https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF)** provides independently converted and quantized GGUF weights, including the **Inkling-2-Mini-AD-IQ1_S.gguf** variant used in the iPhone 15 + Pixel 6 Pro demonstration (approximately 6.88 GB).

AtomicChat developed the **Atomic Dynamic** per-tensor quantization configuration, calibration methodology, and relevant GGUF artifacts. These contributions are not Jujube's work. See [AtomicChat's documentation](https://atomic.chat/blog/guides/how-to-run-inkling-2-mini-locally) and the [GGUF model card](https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF).

The quantized weights are **not included** in this GitHub repository. Please consult the quantizer's repository and the original model's distribution terms before obtaining or using them.

## Local inference and distribution — ggml-org / llama.cpp

**[llama.cpp](https://github.com/ggml-org/llama.cpp)** and **GGML** provide model loading, local inference, CPU backends and the **GGML RPC** mechanism that Jujube used to split execution across two devices. Thanks to the **ggml-org maintainers and contributors** for developing these facilities.

- [llama.cpp repository](https://github.com/ggml-org/llama.cpp)
- [GGML RPC documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)
- [llama.cpp MIT license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE)
- Tested source revision: [56eea9e4b0f5d125da16b75b551440b170aa8b1f](https://github.com/ggml-org/llama.cpp/commit/56eea9e4b0f5d125da16b75b551440b170aa8b1f)

The external llama.cpp source or compiled engine is **not redistributed** here. Jujube's contribution is the specific integration and physical-device verification, not the invention of an RPC-based inference engine.

## Mobile platform technologies

The proof also relies on **Apple iOS / Secure Enclave / Security framework** and **Android / AndroidKeyStore / Java security and TLS APIs** for device identity, signing and local transport. We acknowledge the work behind these platform technologies.

**Hugging Face** hosts the upstream model and quantization repositories linked above.

## Jujube's contribution — integration and physical validation

The independently developed parts of this particular prototype are the iPhone chat test interface and prompt integration; the device-authenticated, time-limited TLS relay between iPhone and Pixel; the configuration and verification of placing **43 of 49 logical model placement slots** on Pixel's CPU-backed GGML RPC worker; and real-device Japanese conversation, debugging, measurement and source publication.

The prototype also fixed a crash in its own prompt preparation by splitting a 108-token input into 64 + 44 prefill tokens. This does **not** imply Jujube fixed or authored the general llama.cpp batching implementation.

**Limitations:** the experiment is not a general-purpose production app, does not run Pixel GPU inference, reloads the model for each turn, and does not establish that any arbitrary iPhone/Android pair will work.

## Licensing and independence

- The original Inkling 2 Mini model is published as **Apache-2.0** by Thinking Machines Lab.
- The upstream llama.cpp/GGML software is published under the **MIT license**.
- For AtomicChat GGUF files, refer to the publisher's model card and the underlying model's terms.
- **Jujube's original source has not yet been assigned an open-source license.** Public visibility and a dependency's license do not automatically grant reuse rights to this project's separate source files.
- No sponsorship, affiliation, endorsement, official collaboration or review by any of these upstream organizations, Apple, Google/Android or Hugging Face is implied.

---

## 日本語での謝辞

Jujubeは、**Thinking Machines LabによるInkling 2 Miniのモデル開発**、**AtomicChatによるGGUFへの変換・量子化と校正**、**ggml-orgおよび貢献者によるllama.cpp／GGML RPCの開発**という既存の技術的成果の上に成立しています。これらの開発者・貢献者の皆様に感謝いたします。

Jujubeで実装・検証したのは、iPhone 15とPixel 6 Proの間で、既存の推論エンジンを使って**1つのLLMの計算を分担するための端末連携、認証付き通信、モデル配置、日本語の複数ターン会話、実機試験と不具合修正**です。

AIモデルそのもの、AtomicChatの量子化手法、GGML RPCの仕組み、暗号技術の発明を主張するものではありません。Jujubeは上記の開発元とは独立した研究プロトタイプであり、公式提携・承認を意味しません。

元のAIモデルや推論エンジンのライセンスと、Jujube本体のコード（現時点でライセンス未選定）は区別して扱います。モデル・量子化版・エンジン本体は本リポジトリで再配布していません。
