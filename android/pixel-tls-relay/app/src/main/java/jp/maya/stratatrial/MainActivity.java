package jp.maya.stratatrial;

import android.app.Activity;
import android.os.Bundle;
import android.os.SystemClock;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Log;
import android.widget.TextView;

import java.io.*;
import java.math.BigInteger;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import javax.security.auth.x500.X500Principal;
import java.security.spec.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import javax.net.ssl.*;

public class MainActivity extends Activity {
  private static final String TAG = "StrataTlsTrial";
  private static final String RSA_ALIAS = "strata-pixel6pro-experimental-rsa-tls-nodigest-v3";
  private static final String RSA_SUBJECT = "CN=Strata-Pixel6Pro-Experimental-Keystore";
  private static final long CERT_VALIDITY_MS = 86_400_000L;
  private static final String BIND_IP = "192.0.2.1";
  private static final int PORT = 55443, RPC_PORT = 50054, MAX_SESSIONS = 12;
  private static final long UPTIME_MS = 1_800_000, UPTIME_5MIN_MS = 300_000, AUTH_MS = 12_000;
  private static final byte[] SERVER_PIN = hexBytes("0000000000000000000000000000000000000000000000000000000000000000");
  private static final byte[] CHALLENGE = "STRATA1!".getBytes(StandardCharsets.US_ASCII);
  private static final byte[] DOMAIN = "STRATA-CLIENT-AUTH-v1:".getBytes(StandardCharsets.UTF_8);
  private static final byte[] OK = "AUTHOK1!".getBytes(StandardCharsets.US_ASCII);
  private static final ExecutorService EXEC = Executors.newCachedThreadPool();
  private static final ScheduledExecutorService TIMER = Executors.newSingleThreadScheduledExecutor();
  private static boolean running;
  private TextView label;

  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    label = new TextView(this);
    label.setTextSize(17);
    label.setPadding(24, 80, 24, 32);
    label.setText("Jujube TLS Test\nIdle. Start only by explicit ADB test command.");
    setContentView(label);
    String mode = getIntent().getStringExtra("mode");
    if ("start".equals(mode) || "start-keystore".equals(mode) || "start-keystore-5min".equals(mode) || "generate-keystore-public".equals(mode)) {
      synchronized (MainActivity.class) {
        if (running) { status("TLS trial already running"); return; }
        running = true;
      }
      EXEC.execute(() -> {
        try {
          if ("generate-keystore-public".equals(mode)) generateKeystorePublic();
          else runTrial("start-keystore".equals(mode) || "start-keystore-5min".equals(mode),
                        "start-keystore-5min".equals(mode) ? UPTIME_5MIN_MS : UPTIME_MS);
        }
        catch (Exception e) { status("FAILED: " + failure(e) + (e instanceof RenewalNeededException ? ": renewal needed; supervisor intervention required" : "")); }
        finally { synchronized (MainActivity.class) { running = false; } }
      });
    }
  }

  private void status(String message) {
    Log.i(TAG, message);
    runOnUiThread(() -> label.setText(message));
  }
  private static String failure(Exception e) { return e.getClass().getSimpleName(); }
  private static byte[] hexBytes(String s) {
    byte[] result = new byte[s.length() / 2];
    for (int i = 0; i < result.length; i++) result[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
    return result;
  }
  private SSLContext loadIdentity() throws Exception {
    KeyStore ks = KeyStore.getInstance("PKCS12");
    char[] password = new char[0];
    try (InputStream in = new FileInputStream(new File(getFilesDir(), "pixel-temp.p12"))) { ks.load(in, password); }
    int keyCount = 0;
    Enumeration<String> aliases = ks.aliases();
    while (aliases.hasMoreElements()) {
      String alias = aliases.nextElement();
      if (!ks.isKeyEntry(alias)) continue;
      keyCount++;
      Certificate cert = ks.getCertificate(alias);
      if (!(cert instanceof X509Certificate) || !(ks.getKey(alias, password) instanceof PrivateKey))
        throw new GeneralSecurityException("invalid server identity");
      ((X509Certificate) cert).checkValidity();
      if (!MessageDigest.isEqual(SERVER_PIN, MessageDigest.getInstance("SHA-256").digest(cert.getEncoded())))
        throw new GeneralSecurityException("server certificate pin mismatch");
    }
    if (keyCount != 1) throw new GeneralSecurityException("expected one server identity");
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(ks, password);
    SSLContext context = SSLContext.getInstance("TLSv1.2");
    context.init(kmf.getKeyManagers(), null, new SecureRandom());
    return context;
  }
  private static class RenewalNeededException extends GeneralSecurityException { }

  private KeyStore androidKeyStore() throws Exception {
    KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
    ks.load(null);
    return ks;
  }

  private X509Certificate validateKeystoreIdentity(KeyStore ks) throws Exception {
    if (!ks.isKeyEntry(RSA_ALIAS)) throw new GeneralSecurityException("keystore identity missing");
    Certificate cert = ks.getCertificate(RSA_ALIAS);
    if (!(cert instanceof X509Certificate) || !(cert.getPublicKey() instanceof RSAPublicKey) ||
        ((RSAPublicKey) cert.getPublicKey()).getModulus().bitLength() != 2048 ||
        !((X509Certificate) cert).getSubjectX500Principal().equals(new X500Principal(RSA_SUBJECT)) ||
        !(ks.getKey(RSA_ALIAS, null) instanceof PrivateKey))
      throw new GeneralSecurityException("invalid keystore identity");
    X509Certificate x509 = (X509Certificate) cert;
    if (x509.getNotAfter().getTime() - x509.getNotBefore().getTime() > CERT_VALIDITY_MS)
      throw new GeneralSecurityException("invalid certificate validity period");
    try { x509.checkValidity(); }
    catch (java.security.cert.CertificateExpiredException e) { throw new RenewalNeededException(); }
    return x509;
  }

  private void generateKeystorePublic() throws Exception {
    KeyStore ks = androidKeyStore();
    if (!ks.containsAlias(RSA_ALIAS)) {
      Date from = new Date();
      Date until = new Date(from.getTime() + CERT_VALIDITY_MS);
      KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
      generator.initialize(new KeyGenParameterSpec.Builder(RSA_ALIAS,
          KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY | KeyProperties.PURPOSE_DECRYPT)
          .setKeySize(2048).setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
          .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE, KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
          .setCertificateSubject(new X500Principal(RSA_SUBJECT))
          .setCertificateNotBefore(from).setCertificateNotAfter(until).build());
      generator.generateKeyPair();
    }
    X509Certificate cert = validateKeystoreIdentity(ks);
    try (FileOutputStream out = openFileOutput("server-public.der", MODE_PRIVATE)) {
      out.write(cert.getEncoded());
    }
    status("Public certificate saved to " + new File(getFilesDir(), "server-public.der").getAbsolutePath());
  }

  private SSLContext loadKeystoreIdentity() throws Exception {
    KeyStore ks = androidKeyStore();
    validateKeystoreIdentity(ks);
    X509ExtendedKeyManager manager = new X509ExtendedKeyManager() {
      private boolean rsa(String keyType) {
        return keyType != null && keyType.toUpperCase(Locale.ROOT).contains("RSA");
      }
      @Override public String[] getServerAliases(String keyType, Principal[] issuers) {
        return rsa(keyType) ? new String[]{RSA_ALIAS} : null;
      }
      @Override public String chooseServerAlias(String keyType, Principal[] issuers, Socket socket) {
        Log.i(TAG, "TLS requested hardware server key type=" + keyType + " RSA eligible=" + rsa(keyType));
        return rsa(keyType) ? RSA_ALIAS : null;
      }
      @Override public String chooseEngineServerAlias(String keyType, Principal[] issuers, SSLEngine engine) {
        Log.i(TAG, "TLS requested hardware server key type=" + keyType + " RSA eligible=" + rsa(keyType));
        return rsa(keyType) ? RSA_ALIAS : null;
      }
      @Override public String[] getClientAliases(String keyType, Principal[] issuers) { return null; }
      @Override public String chooseClientAlias(String[] keyTypes, Principal[] issuers, Socket socket) { return null; }
      @Override public String chooseEngineClientAlias(String[] keyTypes, Principal[] issuers, SSLEngine engine) { return null; }
      @Override public X509Certificate[] getCertificateChain(String alias) {
        if (!RSA_ALIAS.equals(alias)) return null;
        try {
          Certificate[] chain = ks.getCertificateChain(alias);
          if (chain == null) return null;
          X509Certificate[] result = new X509Certificate[chain.length];
          for (int i = 0; i < chain.length; i++) result[i] = (X509Certificate) chain[i];
          return result;
        } catch (GeneralSecurityException | ClassCastException e) { return null; }
      }
      @Override public PrivateKey getPrivateKey(String alias) {
        if (!RSA_ALIAS.equals(alias)) return null;
        try {
          Key key = ks.getKey(alias, null);
          return key instanceof PrivateKey ? (PrivateKey) key : null;
        } catch (GeneralSecurityException e) { return null; }
      }
    };
    SSLContext context = SSLContext.getInstance("TLSv1.2");
    context.init(new KeyManager[]{manager}, null, new SecureRandom());
    return context;
  }
  private ECPublicKey loadClientKey() throws Exception {
    byte[] raw = new byte[65];
    try (InputStream in = new FileInputStream(new File(getFilesDir(), "iphone-client-public.bin"))) {
      new DataInputStream(in).readFully(raw);
      if (in.read() != -1 || raw[0] != 4) throw new GeneralSecurityException("invalid client key encoding");
    }
    AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
    parameters.init(new ECGenParameterSpec("secp256r1"));
    ECParameterSpec spec = parameters.getParameterSpec(ECParameterSpec.class);
    BigInteger x = new BigInteger(1, Arrays.copyOfRange(raw, 1, 33));
    BigInteger y = new BigInteger(1, Arrays.copyOfRange(raw, 33, 65));
    BigInteger p = ((ECFieldFp) spec.getCurve().getField()).getP();
    if (x.compareTo(p) >= 0 || y.compareTo(p) >= 0 ||
        !y.multiply(y).mod(p).equals(x.multiply(x).multiply(x).add(spec.getCurve().getA().multiply(x)).add(spec.getCurve().getB()).mod(p)))
      throw new GeneralSecurityException("client point not on P-256");
    return (ECPublicKey) KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(x, y), spec));
  }
  private static void close(Socket s) { try { s.close(); } catch (IOException ignored) { } }
  private static void pipe(InputStream in, OutputStream out, Socket tls, Socket rpc, AtomicLong count) {
    byte[] buffer = new byte[32768];
    try {
      int n;
      while ((n = in.read(buffer)) != -1) if (n > 0) { out.write(buffer, 0, n); if (count != null) count.addAndGet(n); }
    } catch (IOException e) { Log.i(TAG, "Relay closed: " + failure(e)); }
    finally { close(tls); close(rpc); }
  }
  private void serve(SSLSocket tls, ECPublicKey key, SecureRandom random, long deadline) {
    AtomicLong toPixel = new AtomicLong();
    String stage = "TLS handshake";
    ScheduledFuture<?> authTimer = TIMER.schedule(() -> close(tls), AUTH_MS, TimeUnit.MILLISECONDS);
    ScheduledFuture<?> stopTimer = TIMER.schedule(() -> close(tls), Math.max(0, deadline - SystemClock.elapsedRealtime()), TimeUnit.MILLISECONDS);
    try (SSLSocket client = tls) {
      client.setUseClientMode(false);
      client.setEnabledProtocols(new String[]{"TLSv1.2"});
      client.setSoTimeout((int) AUTH_MS);
      client.startHandshake();
      stage = "client authentication";
      byte[] nonce = new byte[32];
      random.nextBytes(nonce);
      OutputStream out = client.getOutputStream();
      out.write(CHALLENGE); out.write(nonce); out.flush();
      DataInputStream in = new DataInputStream(client.getInputStream());
      int length = in.readUnsignedShort();
      if (length < 1 || length > 256) throw new GeneralSecurityException("invalid signature length");
      byte[] signature = new byte[length];
      in.readFully(signature);
      Signature verifier = Signature.getInstance("SHA256withECDSA");
      verifier.initVerify(key); verifier.update(DOMAIN); verifier.update(nonce);
      if (!verifier.verify(signature)) throw new GeneralSecurityException("signature rejected");
      if (SystemClock.elapsedRealtime() >= deadline || client.isClosed()) throw new IOException("expired");
      authTimer.cancel(false);
      out.write(OK); out.flush();
      Log.i(TAG, "Client authentication approved");
      stage = "loopback RPC";
      try (Socket rpc = new Socket()) {
        rpc.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), RPC_PORT), 12000);
        // Inkling transfers 4.82 GiB of quantized tensors on a single authenticated RPC
        // session. Client->Pixel writes can last several minutes before a reply.
        // Keep the absolute 30-minute scheduled session expiry as the hard limit.
        rpc.setSoTimeout(420000); rpc.setTcpNoDelay(true); client.setSoTimeout(420000);
        InputStream tlsIn = client.getInputStream(); OutputStream rpcOut = rpc.getOutputStream();
        Future<?> upload = EXEC.submit(() -> pipe(tlsIn, rpcOut, client, rpc, toPixel));
        pipe(rpc.getInputStream(), out, client, rpc, null);
        try { upload.get(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        catch (ExecutionException e) { Log.w(TAG, "Upload failed: " + failure(e)); }
      }
    } catch (Exception e) {
      Log.w(TAG, stage + " failed: " + failure(e) + ", message=" + e.getMessage(), e);
    }
    finally {
      authTimer.cancel(false); stopTimer.cancel(false);
      Log.i(TAG, "Session ended; bytes to Pixel RPC=" + toPixel.get());
    }
  }
  private void runTrial(boolean keystore, long maxDurationMs) throws Exception {
    SSLContext context = keystore ? loadKeystoreIdentity() : loadIdentity();
    ECPublicKey clientKey = loadClientKey();
    SecureRandom random = new SecureRandom();
    long deadline = SystemClock.elapsedRealtime() + maxDurationMs;
    // Bound concurrent sessions separately from total accepted sessions.
    // llama.cpp opens several *sequential* metadata/weight/compute RPC sockets.
    // Limiting the lifetime total to 12 broke the second independent split run.
    List<Future<?>> sessions = new ArrayList<>();
    Semaphore concurrentSlots = new Semaphore(MAX_SESSIONS);
    int totalAccepted = 0;
    final int maxTotalAccepted = 256;
    try (SSLServerSocket server = (SSLServerSocket) context.getServerSocketFactory().createServerSocket(PORT, MAX_SESSIONS, InetAddress.getByName(BIND_IP))) {
      server.setEnabledProtocols(new String[]{"TLSv1.2"});
      server.setNeedClientAuth(false);
      server.setSoTimeout(1000);
      status("TLS trial listening on " + BIND_IP + ":" + PORT + "; expires in " + (maxDurationMs / 60000) + " minutes");
      while (SystemClock.elapsedRealtime() < deadline && totalAccepted < maxTotalAccepted) {
        try {
          SSLSocket client = (SSLSocket) server.accept();
          if (!concurrentSlots.tryAcquire()) {
            close(client); // fail closed under resource pressure
            continue;
          }
          totalAccepted++;
          try {
            sessions.add(EXEC.submit(() -> {
              try { serve(client, clientKey, random, deadline); }
              finally { concurrentSlots.release(); }
            }));
          } catch (RejectedExecutionException e) {
            concurrentSlots.release();
            close(client);
            throw e;
          }
        } catch (SocketTimeoutException ignored) { }
      }
      Log.i(TAG, "TLS trial accepted sessions total=" + totalAccepted);
    }
    status("TLS listener stopped; waiting for active sessions to finish");
    for (Future<?> session : sessions) {
      try { session.get(); } catch (ExecutionException e) { Log.w(TAG, "Session failed: " + failure(e)); }
    }
    status("TLS trial stopped");
  }
}
