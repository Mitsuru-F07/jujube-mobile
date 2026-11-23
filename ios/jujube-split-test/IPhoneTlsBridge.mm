#import "IPhoneTlsBridge.h"
#import <Security/Security.h>
#import <Security/SecureTransport.h>
#import <CommonCrypto/CommonDigest.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <type_traits>

// SecureTransport is intentionally used for this iOS test probe.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr auto ioTimeout = 30s;
constexpr int maxConnections = 16;
constexpr char challengeMagic[] = "STRATA1!";
constexpr char authOK[] = "AUTHOK1!";
constexpr char authDomain[] = "STRATA-CLIENT-AUTH-v1:";
constexpr char pin[] = "0000000000000000000000000000000000000000000000000000000000000000";
static_assert(sizeof(pin) == 2 * CC_SHA256_DIGEST_LENGTH + 1);
static_assert(sizeof(authDomain) - 1 == 22);

template <typename T> struct CFReleaseOwned {
    void operator()(T *object) const { CFRelease(object); }
};
template <typename Ref>
using OwnedCF = std::unique_ptr<std::remove_pointer_t<Ref>, CFReleaseOwned<std::remove_pointer_t<Ref>>>;

struct Socket {
    int fd;
    explicit Socket(int value) : fd(value) {}
    ~Socket() { if (fd >= 0) close(fd); }
    Socket(const Socket &) = delete;
    Socket &operator=(const Socket &) = delete;
};

NSString *documents(NSString *name) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [@"Documents" stringByAppendingPathComponent:name]];
}

NSDictionary *keyQuery() {
    NSData *tag = [@"jp.maya.strata.splitprobe.tls-client-v1" dataUsingEncoding:NSUTF8StringEncoding];
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecAttrApplicationTag: tag,
        (__bridge id)kSecReturnRef: @YES
    };
}

OwnedCF<SecKeyRef> clientKey(bool create) {
    NSDictionary *query = keyQuery();
    CFTypeRef found = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
    if (status == errSecSuccess) {
        OwnedCF<SecKeyRef> key((SecKeyRef)found);
        NSDictionary *attributes = CFBridgingRelease(SecKeyCopyAttributes(key.get()));
        if ([attributes[(__bridge id)kSecAttrTokenID] isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave]) {
            return key;
        }
        BridgeAudit(@"FAIL client key is outside the Secure Enclave");
        return {};
    }
    if (!create || status != errSecItemNotFound) {
        BridgeAudit([NSString stringWithFormat:@"FAIL client key lookup OSStatus=%d", (int)status]);
        return {};
    }

    CFErrorRef error = nullptr;
    OwnedCF<SecAccessControlRef> access(SecAccessControlCreateWithFlags(
        kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecAccessControlPrivateKeyUsage, &error));
    if (!access) {
        BridgeAudit([NSString stringWithFormat:@"FAIL client key access control %@", CFBridgingRelease(error)]);
        return {};
    }
    NSDictionary *attributes = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeySizeInBits: @256,
        (__bridge id)kSecAttrTokenID: (__bridge id)kSecAttrTokenIDSecureEnclave,
        (__bridge id)kSecPrivateKeyAttrs: @{
            (__bridge id)kSecAttrIsPermanent: @YES,
            (__bridge id)kSecAttrApplicationTag: query[(__bridge id)kSecAttrApplicationTag],
            (__bridge id)kSecAttrAccessControl: (__bridge id)access.get()
        }
    };
    OwnedCF<SecKeyRef> key(SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error));
    if (!key) {
        BridgeAudit([NSString stringWithFormat:@"FAIL client key generation %@", CFBridgingRelease(error)]);
    } else {
        BridgeAudit(@"Secure Enclave P-256 client key created");
    }
    return key;
}

NSData *publicBytes(SecKeyRef privateKey) {
    OwnedCF<SecKeyRef> publicKey(SecKeyCopyPublicKey(privateKey));
    if (!publicKey) return nil;
    CFErrorRef error = nullptr;
    NSData *bytes = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey.get(), &error));
    if (error) CFRelease(error);
    return bytes.length == 65 && static_cast<const uint8_t *>(bytes.bytes)[0] == 4 ? bytes : nil;
}

struct RunState {
    const Clock::time_point expires = Clock::now() + 8min;
    std::atomic<bool> stopping{false};
    std::atomic<int> connections{0};

    bool active() const { return !stopping.load() && Clock::now() < expires; }
};

int waitReady(const RunState &run, pollfd *fds, nfds_t count, Clock::time_point deadline) {
    deadline = std::min(deadline, run.expires);
    while (run.active() && Clock::now() < deadline) {
        const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(deadline - Clock::now()).count();
        int ready = poll(fds, count, static_cast<int>(std::clamp(remaining, 0LL, 200LL)));
        if (ready > 0 || (ready < 0 && errno != EINTR)) return ready;
    }
    return 0;
}

bool configureSocket(int fd) {
    int yes = 1;
    int f = fcntl(fd, F_GETFL);
    if (f < 0 || fcntl(fd, F_SETFL, f | O_NONBLOCK) < 0) {
        BridgeAudit([NSString stringWithFormat:@"FAIL remote socket fcntl errno=%d", errno]);
        return false;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) {
        BridgeAudit([NSString stringWithFormat:@"FAIL socket SO_NOSIGPIPE errno=%d", errno]);
        return false;
    }
    return true;
}

sockaddr_in endpoint(uint32_t address, uint16_t port) {
    sockaddr_in result{};
    result.sin_len = sizeof(result);
    result.sin_family = AF_INET;
    result.sin_addr.s_addr = htonl(address);
    result.sin_port = htons(port);
    return result;
}

bool connectPixel(const RunState &run, int fd, Clock::time_point deadline) {
    auto address = endpoint(0, 55443);
    if (inet_pton(AF_INET, "192.0.2.1", &address.sin_addr) != 1) return false;
    if (connect(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0) {
        BridgeAudit(@"Pixel TCP immediately connected");
        return true;
    }
    int connectError = errno;
    if (connectError != EINPROGRESS) {
        BridgeAudit([NSString stringWithFormat:@"FAIL Pixel connect errno=%d (%s)", connectError, strerror(connectError)]);
        return false;
    }
    pollfd event{fd, POLLOUT, 0};
    int error = 0;
    socklen_t size = sizeof(error);
    int polled = waitReady(run, &event, 1, deadline);
    if (polled <= 0) {
        BridgeAudit([NSString stringWithFormat:@"FAIL Pixel connect poll result=%d errno=%d", polled, errno]);
        return false;
    }
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error != 0) {
        BridgeAudit([NSString stringWithFormat:@"FAIL Pixel TCP completion SO_ERROR=%d errno=%d",error,errno]);
        return false;
    }
    BridgeAudit(@"Pixel TCP connected to 192.0.2.1:55443");
    return true;
}

struct TlsSocket {
    int fd;
    short blockedOn = 0;
};

bool retryable() { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR; }

OSStatus tlsRead(SSLConnectionRef connection, void *data, size_t *length) {
    auto &socket = *const_cast<TlsSocket *>(static_cast<const TlsSocket *>(connection));
    const size_t requested = *length;
    const ssize_t count = recv(socket.fd, data, requested, 0);
    *length = count > 0 ? count : 0;
    if (count == static_cast<ssize_t>(requested)) return noErr;
    if (count == 0) return errSSLClosedAbort;
    if (count > 0 || retryable()) {
        socket.blockedOn = POLLIN;
        return errSSLWouldBlock;
    }
    return errSSLClosedAbort;
}

OSStatus tlsWrite(SSLConnectionRef connection, const void *data, size_t *length) {
    auto &socket = *const_cast<TlsSocket *>(static_cast<const TlsSocket *>(connection));
    const size_t requested = *length;
    const ssize_t count = send(socket.fd, data, requested, 0);
    *length = count > 0 ? count : 0;
    if (count == static_cast<ssize_t>(requested)) return noErr;
    if (count >= 0 || retryable()) {
        socket.blockedOn = POLLOUT;
        return errSSLWouldBlock;
    }
    return errSSLClosedAbort;
}

bool verifyPin(SSLContextRef tls) {
    SecTrustRef peer = nullptr;
    if (SSLCopyPeerTrust(tls, &peer) != noErr || !peer) return false;
    OwnedCF<SecTrustRef> trust(peer);
    // Index zero is available before trust evaluation. This trust object
    // stays on the connection's worker thread.
    SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust.get(), 0);
    if (!leaf) return false;
    NSData *der = CFBridgingRelease(SecCertificateCopyData(leaf));
    if (!der.length || der.length > UINT32_MAX) return false;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(der.bytes, static_cast<CC_LONG>(der.length), digest);
    constexpr char hex[] = "0123456789abcdef";
    char actual[sizeof(pin)]{};
    for (size_t i = 0; i < sizeof(digest); ++i) {
        actual[2 * i] = hex[digest[i] >> 4];
        actual[2 * i + 1] = hex[digest[i] & 15];
    }
    const bool match = strcmp(actual, pin) == 0;
    BridgeAudit([NSString stringWithFormat:@"TLS leaf DER SHA-256 %s pin=%@", actual, match ? @"match" : @"mismatch"]);
    return match;
}

bool waitTls(const RunState &run, const TlsSocket &socket, Clock::time_point deadline) {
    pollfd event{socket.fd, socket.blockedOn, 0};
    return event.events && waitReady(run, &event, 1, deadline) > 0;
}

bool handshake(const RunState &run, SSLContextRef tls, TlsSocket &socket, Clock::time_point deadline) {
    // On iOS this option pauses for manual verification. A completed
    // handshake without the manual verification event is rejected.
    if (SSLSetIOFuncs(tls, tlsRead, tlsWrite) != noErr ||
        SSLSetConnection(tls, &socket) != noErr ||
        SSLSetProtocolVersionMin(tls, kTLSProtocol12) != noErr ||
        SSLSetProtocolVersionMax(tls, kTLSProtocol12) != noErr ||
        SSLSetSessionOption(tls, kSSLSessionOptionBreakOnServerAuth, true) != noErr) {
        BridgeAudit(@"FAIL TLS configuration");
        return false;
    }
    bool pinned = false;
    while (run.active() && Clock::now() < deadline) {
        socket.blockedOn = 0;
        const OSStatus status = SSLHandshake(tls);
        if (status == errSSLServerAuthCompleted && !pinned) {
            if (!verifyPin(tls)) {
                BridgeAudit(@"FAIL TLS certificate pin verification");
                return false;
            }
            pinned = true;
        } else if (status == noErr && pinned) {
            BridgeAudit(@"TLS 1.2 handshake complete");
            return true;
        } else if (status != errSSLWouldBlock) {
            BridgeAudit([NSString stringWithFormat:@"FAIL TLS handshake OSStatus=%d pinned=%d", (int)status, pinned]);
            return false;
        } else if (!waitTls(run, socket, deadline)) {
            break;
        }
    }
    BridgeAudit(@"FAIL TLS handshake timed out or stopped");
    return false;
}

bool tlsExact(const RunState &run, SSLContextRef tls, TlsSocket &socket,
              uint8_t *bytes, size_t length, bool writing, Clock::time_point deadline) {
    size_t offset = 0;
    while (run.active() && Clock::now() < deadline) {
        size_t processed = 0;
        socket.blockedOn = 0;
        OSStatus status = writing
            ? SSLWrite(tls, bytes + offset, length - offset, &processed)
            : SSLRead(tls, bytes + offset, length - offset, &processed);
        offset += processed;
        if (status == noErr && offset == length) return true;
        if (!writing && status == errSSLWouldBlock && offset == length) return true;
        if (status == errSSLWouldBlock && waitTls(run, socket, deadline)) continue;
        if (status != noErr || processed == 0) break;
    }
    return false;
}

bool authenticate(const RunState &run, SSLContextRef tls, TlsSocket &socket, SecKeyRef key) {
    constexpr size_t magicLength = sizeof(challengeMagic) - 1;
    constexpr size_t domainLength = sizeof(authDomain) - 1;
    constexpr size_t nonceLength = 32;
    const auto deadline = Clock::now() + ioTimeout;
    uint8_t challenge[magicLength + nonceLength];
    if (!tlsExact(run, tls, socket, challenge, sizeof(challenge), false, deadline) ||
        memcmp(challenge, challengeMagic, magicLength) != 0) {
        BridgeAudit(@"FAIL TLS authentication challenge");
        return false;
    }
    uint8_t payload[domainLength + nonceLength];
    memcpy(payload, authDomain, domainLength);
    memcpy(payload + domainLength, challenge + magicLength, nonceLength);
    NSData *message = [NSData dataWithBytes:payload length:sizeof(payload)];
    CFErrorRef error = nullptr;
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(
        key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)message, &error));
    if (signature.length == 0 || signature.length > 256) {
        BridgeAudit([NSString stringWithFormat:@"FAIL TLS challenge signing %@", CFBridgingRelease(error)]);
        return false;
    }
    uint8_t frame[2 + 256];
    frame[0] = signature.length >> 8;
    frame[1] = signature.length & 255;
    memcpy(frame + 2, signature.bytes, signature.length);
    uint8_t ack[sizeof(authOK) - 1];
    if (!tlsExact(run, tls, socket, frame, 2 + signature.length, true, deadline) ||
        !tlsExact(run, tls, socket, ack, sizeof(ack), false, deadline) ||
        memcmp(ack, authOK, sizeof(ack)) != 0) {
        BridgeAudit(@"FAIL Pixel authentication acknowledgement");
        return false;
    }
    BridgeAudit(@"Pixel AUTHOK1! received, RPC forwarding authorized");
    return true;
}

NSString *relay(const RunState &run, int local, SSLContextRef tls, TlsSocket &socket) {
    std::array<uint8_t, 16384> outbound, inbound;
    size_t outSize = 0, outOffset = 0, inSize = 0, inOffset = 0;
    short tlsWriteEvents = 0, tlsReadEvents = POLLIN;
    auto idleDeadline = Clock::now() + ioTimeout;
    auto outDeadline = Clock::time_point::max();
    auto inDeadline = Clock::time_point::max();

    while (run.active()) {
        auto deadline = std::min({idleDeadline, outDeadline, inDeadline});
        if (Clock::now() >= deadline) return @"FAIL RPC relay I/O timeout";
        const bool writing = outSize != 0;
        const bool delivering = inSize != 0;
        pollfd events[] = {
            {local, static_cast<short>((writing ? 0 : POLLIN) | (delivering ? POLLOUT : 0)), 0},
            {socket.fd, static_cast<short>((writing ? tlsWriteEvents : 0) |
                                          (delivering ? 0 : tlsReadEvents)), 0}
        };
        size_t buffered = 0;
        bool readBuffered = !delivering && tlsReadEvents == POLLIN &&
                            SSLGetBufferedReadSize(tls, &buffered) == noErr && buffered > 0;
        if (readBuffered) {
            int ready = poll(events, 2, 0);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) return @"FAIL RPC relay poll";
        } else {
            int ready = waitReady(run, events, 2, deadline);
            if (ready < 0) return @"FAIL RPC relay poll";
            if (ready == 0) return run.active() ? @"FAIL RPC relay I/O timeout" : @"RPC relay stopped";
        }
        const short localReady = events[0].revents;
        const short pixelReady = events[1].revents;
        if ((localReady | pixelReady) & (POLLERR | POLLNVAL)) return @"FAIL RPC relay socket";

        if (!writing && (localReady & (POLLIN | POLLHUP))) {
            ssize_t count = recv(local, outbound.data(), outbound.size(), 0);
            if (count == 0) return @"RPC localhost stream closed";
            if (count < 0 && !retryable()) return @"FAIL RPC localhost read";
            if (count > 0) {
                outSize = count;
                tlsWriteEvents = POLLOUT;
                outDeadline = idleDeadline = Clock::now() + ioTimeout;
            }
        }
        if (outSize && (pixelReady & (tlsWriteEvents | POLLHUP))) {
            socket.blockedOn = 0;
            size_t processed = 0;
            const OSStatus status = SSLWrite(tls, outbound.data() + outOffset, outSize - outOffset, &processed);
            outOffset += processed;
            if (processed) idleDeadline = Clock::now() + ioTimeout;
            if (status == noErr && outOffset == outSize) {
                outOffset = outSize = 0;
                outDeadline = Clock::time_point::max();
            } else if (status == errSSLWouldBlock && socket.blockedOn) {
                tlsWriteEvents = socket.blockedOn;
            } else if (status != noErr || !processed) {
                return [NSString stringWithFormat:@"FAIL RPC TLS write OSStatus=%d", (int)status];
            }
        }
        if (!delivering && (readBuffered || (pixelReady & (tlsReadEvents | POLLHUP)))) {
            socket.blockedOn = 0;
            const OSStatus status = SSLRead(tls, inbound.data(), inbound.size(), &inSize);
            if (status != noErr && status != errSSLWouldBlock) {
                if (status == errSSLClosedGraceful && !inSize) return @"Pixel TLS stream closed";
                if (status != errSSLClosedGraceful || !inSize) {
                    return [NSString stringWithFormat:@"FAIL RPC TLS read OSStatus=%d", (int)status];
                }
            }
            tlsReadEvents = socket.blockedOn ? socket.blockedOn : POLLIN;
            if (inSize) inDeadline = idleDeadline = Clock::now() + ioTimeout;
        }
        if (inSize && (localReady & POLLOUT)) {
            ssize_t count = send(local, inbound.data() + inOffset, inSize - inOffset, 0);
            if (count <= 0 && (count == 0 || !retryable())) return @"FAIL RPC localhost write";
            if (count > 0) {
                idleDeadline = Clock::now() + ioTimeout;
                inOffset += count;
                if (inOffset == inSize) {
                    inOffset = inSize = 0;
                    inDeadline = Clock::time_point::max();
                }
            }
        }
        if ((localReady & POLLHUP) && !(localReady & POLLIN)) return @"RPC localhost stream closed";
        if ((pixelReady & POLLHUP) && !(pixelReady & POLLIN) && !inSize) return @"FAIL Pixel TCP closed";
    }
    return @"RPC relay stopped";
}

void serve(const RunState &run, int local, SecKeyRef key) {
    const auto deadline = Clock::now() + 10s;
    Socket remote(socket(AF_INET, SOCK_STREAM, 0));
    if (remote.fd < 0 || !configureSocket(remote.fd) || !connectPixel(run, remote.fd, deadline)) {
        BridgeAudit(@"FAIL Pixel TCP connection to 192.0.2.1:55443");
        return;
    }
    TlsSocket transport{remote.fd};
    OwnedCF<SSLContextRef> tls(SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType));
    if (!tls) {
        BridgeAudit(@"FAIL TLS context creation");
        return;
    }
    if (!handshake(run, tls.get(), transport, deadline) ||
        !authenticate(run, tls.get(), transport, key)) return;
    BridgeAudit(relay(run, local, tls.get(), transport));
}
} // namespace

void BridgeAudit(NSString *message) {
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    NSLog(@"STRATA_BRIDGE %@", message);
    NSString *path = documents(@"bridge-status.txt");
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        NSError *error = nil;
        if (![line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            NSLog(@"STRATA_BRIDGE audit creation failed %@", error);
        }
        return;
    }
    NSError *error = nil;
    if (![file seekToEndReturningOffset:nullptr error:&error] ||
        ![file writeData:[line dataUsingEncoding:NSUTF8StringEncoding] error:&error]) {
        NSLog(@"STRATA_BRIDGE audit append failed %@", error);
    }
    [file closeAndReturnError:nil];
}

BOOL ExportBridgePublicKey(void) {
    BridgeAudit(@"Public-key export requested");
    auto key = clientKey(true);
    if (!key) return NO;
    NSData *bytes = publicBytes(key.get());
    if (!bytes) {
        BridgeAudit(@"FAIL client public key export format");
        return NO;
    }
    NSError *error = nil;
    if (![bytes writeToFile:documents(@"auth-client-public.bin") options:NSDataWritingAtomic error:&error]) {
        BridgeAudit([NSString stringWithFormat:@"FAIL client public key file %@", error]);
        return NO;
    }
    BridgeAudit(@"Exported 65-byte X9.63 P-256 public key to auth-client-public.bin");
    return YES;
}

struct IPhoneTlsBridge::Listener {
    Socket socket;
    std::shared_ptr<RunState> run = std::make_shared<RunState>();
    std::shared_ptr<std::remove_pointer_t<SecKeyRef>> key;
    std::thread thread;

    Listener(OwnedCF<SecKeyRef> clientKey)
        : socket(::socket(AF_INET, SOCK_STREAM, 0)), key(std::move(clientKey)) {}

    void acceptConnections() {
        // Workers own their local sockets, and the shared state outlives them.
        while (run->active()) {
            @autoreleasepool {
                pollfd events{socket.fd, POLLIN, 0};
                const int ready = waitReady(*run, &events, 1, run->expires);
                if (ready <= 0 || !(events.revents & POLLIN)) {
                    if (run->active()) BridgeAudit(@"FAIL RPC listener poll");
                    break;
                }
                int fd = accept(socket.fd, nullptr, nullptr);
                if (fd < 0) {
                    if (retryable()) continue;
                    BridgeAudit(@"FAIL RPC listener accept");
                    break;
                }
                if (run->connections.load() >= maxConnections || !configureSocket(fd)) {
                    close(fd);
                    BridgeAudit(@"FAIL RPC connection rejected (capacity or socket configuration)");
                    continue;
                }
                ++run->connections;
                try {
                    std::thread([state = run, clientKey = key, fd] {
                        @autoreleasepool {
                            Socket local(fd);
                            serve(*state, local.fd, clientKey.get());
                        }
                        --state->connections;
                    }).detach();
                } catch (const std::system_error &) {
                    close(fd);
                    --run->connections;
                    BridgeAudit(@"FAIL RPC worker creation");
                }
            }
        }
        run->stopping = true;
        close(socket.fd);
        socket.fd = -1;
        @autoreleasepool {
            BridgeAudit(Clock::now() >= run->expires ? @"RPC listener expired after 8 minutes" : @"RPC listener stopped");
        }
    }
};

bool IPhoneTlsBridge::start() {
    if (listener_) return false;
    auto key = clientKey(false);
    if (!key) return false;
    NSData *exported = [NSData dataWithContentsOfFile:documents(@"auth-client-public.bin")];
    if (!exported || ![exported isEqualToData:publicBytes(key.get())]) {
        BridgeAudit(@"FAIL current client key has no matching exported public key");
        return false;
    }
    auto listener = std::make_unique<Listener>(std::move(key));
    const auto address = endpoint(INADDR_LOOPBACK, 55155);
    const int fd = listener->socket.fd;
    if (fd < 0 || !configureSocket(fd) ||
        bind(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0 ||
        listen(fd, maxConnections) != 0) {
        BridgeAudit([NSString stringWithFormat:@"FAIL RPC listener setup errno=%d", errno]);
        return false;
    }
    try {
        listener->thread = std::thread([ptr = listener.get()] { ptr->acceptConnections(); });
    } catch (const std::system_error &) {
        BridgeAudit(@"FAIL RPC listener thread creation");
        return false;
    }
    listener_ = listener.release();
    BridgeAudit(@"RPC listener bound to 127.0.0.1:55155");
    return true;
}

IPhoneTlsBridge::~IPhoneTlsBridge() {
    std::unique_ptr<Listener> listener(listener_);
    if (!listener) return;
    listener->run->stopping = true;
    listener->thread.join();
}
#pragma clang diagnostic pop
