# Build and provisioning (advanced development prototype)

These steps describe dependencies and configuration requirements. They are **not a one-command end-to-end reproducer**.

## Tested dependency revision

The iOS and Pixel CPU/RPC engines used ggml-org/llama.cpp revision:

~~~text
56eea9e4b0f5d125da16b75b551440b170aa8b1f
~~~

The compiled C/C++ inference engine and model are **not included** in this repository. Prepare a compatible iPhoneOS arm64 static llama.cpp/RPC build, and a matching Android arm64 CPU GGML RPC server, from upstream. Check the upstream MIT license.

Use the compatible GGUF from a model provider. The original test selected:

~~~text
Model file: Inkling-2-Mini-AD-IQ1_S.gguf
Size:       6,881,463,904 bytes
SHA-256:    4d3cab7e88016548136e13f7ec465db7fc49ab8cf9559a60f3daad1f3f15c9d5
~~~

Do not bypass checksum enforcement if a download differs; instead verify whether the quantized model itself differs and adapt only intentionally.

## Pixel Android TLS gateway

Build sources in android/pixel-tls-relay/ using Android SDK API 36, Android Gradle Plugin 9.2.0, a compatible Gradle runtime and Java 17:

~~~sh
gradle -p android/pixel-tls-relay assembleDebug
~~~

This yields the **TLS helper only**, not the native GGML worker.

The code deliberately retains tested internal package ID jp.maya.stratatrial; change to a unique ID for your own independent installation if required. Its server bind address is 192.0.2.1 (nonfunctional placeholder) and the legacy SHA-256 trust pin is zeroed.

For your device and network:
- Configure a private LAN address actually assigned to Pixel.
- Generate your own AndroidKeyStore server identity; provision the corresponding pinned certificate SHA-256 on iPhone.
- Independently generate an iPhone Secure Enclave P-256 key; enroll the **public** key on Pixel. Never export/publish the private key.
- Build and start the native Android GGML CPU RPC worker bound only to 127.0.0.1:50054.
- Explicitly start the TLS helper using the debug ADB intent mode start-keystore (max 30 min) or start-keystore-5min (max 5 min). Avoid auto-start services.
- Stop worker and relay at completion.

Manual device pairing/enrollment, native RPC binary deployment, trust renewal and SDK installation are **not automated** in this source snapshot.

## iPhone test application

The Objective-C++ chat app under ios/jujube-split-test/ links prebuilt iOS llama.cpp and GGML RPC static libraries. Configure CMake with local paths for the same version-pinned sources and compiled libraries, and use a developer-owned bundle ID and Apple signing team.

Example CMake configuration (adjust for your Xcode installation and paths):

~~~sh
cmake -S ios/jujube-split-test -B build-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DJUJUBE_LLAMA_SOURCE=/your/path/to/llama.cpp \
  -DJUJUBE_IOS_BUILD=/your/path/to/ios-rpc-build \
  -DJUJUBE_TEAM_ID=YOUR_APPLE_TEAM_ID \
  -DJUJUBE_BUNDLE_ID=org.example.yourjujube.splitprobe
~~~

The iPhone source has intentionally invalid Pixel IP and certificate pin placeholders. Provision your local pair and matching trust values. The GGUF belongs in the test app's Documents directory, not the public Git repository.

The test app also contains a development-only optional Qwen path; that artifact is not bundled unless explicitly supplied via JUJUBE_OPTIONAL_QWEN_GGUF. Missing that optional model does not prevent using the separately provisioned Inkling GGUF path.

## Failure modes

Review model fingerprint/length, AndroidKeyStore certificate expiry, TLS leaf SHA-256 pin, authenticated iPhone P-256 public key, LAN reachability, matching GGML RPC versions, and memory budget in that order.

Seeing a node/hello advertisement is **not evidence** that model inference is distributed. Only real joint model output with network traces/verified engine output demonstrates this specific proof.

No binaries, signing credentials or user data are provided here.
