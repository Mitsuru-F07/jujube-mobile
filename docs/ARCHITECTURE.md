# Architecture / 分散構成

~~~text
iPhone 15: Jujube Split Test
  - verifies model length and SHA-256
  - formats Inkling-specific chat turns and chunks prefill to <=64 tokens
  - executes local part of llama.cpp model
  - loopback RPC connection on 127.0.0.1:55155
                  |
       Pinned TLS 1.2 over private Wi-Fi
       Secure Enclave P-256 challenge signature
                  |
                  v
Pixel 6 Pro: AndroidKeyStore TLS gateway
  - authorizes the paired iPhone before forwarding
  - explicit test-only activation with 5/30-minute deadline
                  |
                  v
Pixel: ggml-rpc-server, --device CPU
       listening ONLY on 127.0.0.1:50054
~~~

## Verified scope

- Real iPhone 15 + Pixel 6 Pro split inference of one Inkling 2 Mini model over LAN.
- 43/49 *logical* layer placement slots on remote RPC, not 43 distinct physical weight layers. The Inkling architecture reuses looped physical layers.
- Approximately 4,824.96 MiB of model buffers on Pixel and 1,726.29 MiB on iPhone.
- Japanese text chat, with 128 output-token cap and previous two turns of history held in UI memory.
- The current path reloads weights every turn, does not stream user-facing partial tokens and does not support unattended persistent compute.
- Pixel work is CPU. The Mac Pro and cloud LLMs are **not inference devices** in the physical proof.

## Boundaries

The Android TLS helper's existing package ID and the iPhone's internal protocol labels retain historical Strata/Maya names for compatibility. The original Maya Mobile/Jujube normal app and separate staged Jujube Node are distinct from this validated split proof.

The public source replaces its local IP and public trust pins with intentionally invalid placeholders. No automatic certificate enrollment, pairing GUI or portable installation flow is provided.
