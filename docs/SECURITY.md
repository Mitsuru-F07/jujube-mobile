# Security model and release audit

**Experimental source only. Not production security software.**

1. Public source intentionally omits private keys, model weights, signed binaries, development provisioning, device backups, logs and personal chat data.
2. The example address is **192.0.2.1**, an RFC 5737 documentation address that is not a working Pixel endpoint. All public SHA-256 trust pins are set to 64 zero hex characters. **Replace these with your own securely provisioned device identity before testing; never disable pin validation to make it connect.**
3. The Pixel native GGML RPC worker must bind **only** to 127.0.0.1:50054, not a LAN/public interface. A separate authenticated TLS gateway controls access.
4. The iPhone demo pins the Pixel's TLS server certificate and signs a nonce using an on-device Secure Enclave P-256 client key. The Pixel verifies the client's previously provisioned public key before forwarding RPC.
5. The gateway runs only after an explicit debug start, and closes after a 5- or 30-minute test limit. There is no auto-start daemon.
6. The test AndroidKeyStore certificate has short validity (configured for one day); renewal and re-pinning must be manual and carefully validated. Source also retains a legacy PKCS12 software certificate test branch; this is **not** a recommended production mode.
7. The iPhone prototype stores the most recent diagnostic result locally. Protect or erase diagnostic chat text before sharing devices/backups; production logging needs a separate privacy design.
8. The published version has not been independently audited or tested on untrusted networks. Do not expose device RPC ports to the internet.
9. Staged Jujube Node features in other projects are not validated transport or compute routes for this proof.

The source release contains intentionally invalid device connection details and is **not expected to connect out of the box**. The preserved locally working projects are not modified by preparing this release.

Please contact the repository maintainer privately through GitHub for security issues before disclosing vulnerabilities.
