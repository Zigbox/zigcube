// Test tooling for `zig build mtls-interop` (src/mtls_interop.zig), never part of a product: a
// stock JVM TLS 1.3 server that asks for a client certificate, trusts one CA, and reports what it
// read from the certificate. Run as `java InteropServer.java <ca.pem> <cert.pem> <key.pem>
// [--no-client-auth] [--allow <spiffe uri>] [--mode echo|sse|bulk]`; the harness reads the lines
// this prints to stdout: LISTENING <port>, CONN ..., FAILED ..., CLOSED ....
//
// The extension is decoded here with a reader of its own, not with the Zig code under test.
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.*;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.*;
import javax.net.ssl.*;

public class InteropServer {
    static final String EXTENSION_OID = "2.25.192541954756406065736426278304158759968";
    static final int SSE_EVENTS = 20;
    static final int SSE_GAP_MS = 100;
    static final int BULK_BYTES = 3 * 1024 * 1024;

    static byte[] pemBody(String file) throws IOException {
        StringBuilder body = new StringBuilder();
        for (String line : Files.readAllLines(Paths.get(file))) {
            if (!line.startsWith("-----")) body.append(line.trim());
        }
        return Base64.getDecoder().decode(body.toString());
    }

    static Collection<? extends Certificate> certificates(String file) throws Exception {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        try (InputStream in = new FileInputStream(file)) {
            return factory.generateCertificates(in);
        }
    }

    /** Trusts one CA and, when an allow-list is given, only the SPIFFE ids on it. */
    static class AllowList extends X509ExtendedTrustManager {
        final X509ExtendedTrustManager inner;
        final Set<String> allowed;

        AllowList(X509ExtendedTrustManager inner, Set<String> allowed) {
            this.inner = inner;
            this.allowed = allowed;
        }

        public void checkClientTrusted(X509Certificate[] chain, String type, Socket socket)
                throws CertificateException {
            inner.checkClientTrusted(chain, type, socket);
            if (allowed.isEmpty()) return;
            String id = spiffe(chain[0]);
            if (id == null || !allowed.contains(id)) {
                throw new CertificateException("identity " + id + " is not on the allow-list");
            }
        }

        public void checkClientTrusted(X509Certificate[] c, String t, SSLEngine e)
                throws CertificateException { inner.checkClientTrusted(c, t, e); }
        public void checkClientTrusted(X509Certificate[] c, String t)
                throws CertificateException { inner.checkClientTrusted(c, t); }
        public void checkServerTrusted(X509Certificate[] c, String t, Socket s)
                throws CertificateException { inner.checkServerTrusted(c, t, s); }
        public void checkServerTrusted(X509Certificate[] c, String t, SSLEngine e)
                throws CertificateException { inner.checkServerTrusted(c, t, e); }
        public void checkServerTrusted(X509Certificate[] c, String t)
                throws CertificateException { inner.checkServerTrusted(c, t); }
        public X509Certificate[] getAcceptedIssuers() { return inner.getAcceptedIssuers(); }
    }

    static String spiffe(X509Certificate certificate) throws CertificateParsingException {
        Collection<List<?>> names = certificate.getSubjectAlternativeNames();
        if (names == null) return null;
        for (List<?> name : names) {
            if ((Integer) name.get(0) == 6) return (String) name.get(1);
        }
        return null;
    }

    // ---- A small DER reader, independent of the Zig one ----

    static final class Reader {
        final byte[] bytes;
        int position;

        Reader(byte[] bytes, int position) { this.bytes = bytes; this.position = position; }

        /** Reads one TLV with the expected tag and returns a reader over its content. */
        Reader expect(int tag) {
            if ((bytes[position++] & 0xFF) != tag) throw new IllegalStateException("tag");
            int length = bytes[position++] & 0xFF;
            if (length >= 0x80) {
                int count = length & 0x7F;
                length = 0;
                for (int i = 0; i < count; i++) length = (length << 8) | (bytes[position++] & 0xFF);
            }
            Reader inner = new Reader(Arrays.copyOfRange(bytes, position, position + length), 0);
            position += length;
            return inner;
        }

        boolean more() { return position < bytes.length; }
        byte[] rest() { return Arrays.copyOfRange(bytes, position, bytes.length); }
    }

    static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte b : bytes) text.append(String.format("%02x", b));
        return text.toString();
    }

    static String identity(X509Certificate certificate) {
        byte[] wrapped = certificate.getExtensionValue(EXTENSION_OID);
        if (wrapped == null) return "extension=absent";
        Reader value = new Reader(wrapped, 0).expect(0x04); // extnValue as an OCTET STRING.
        Reader sequence = value.expect(0x30);
        long version = new java.math.BigInteger(sequence.expect(0x02).rest()).longValue();
        String digest = hex(sequence.expect(0x04).rest());
        long epoch = new java.math.BigInteger(sequence.expect(0x02).rest()).longValue();
        StringBuilder labels = new StringBuilder();
        Reader list = sequence.expect(0x30);
        while (list.more()) {
            Reader pair = list.expect(0x30);
            String key = new String(pair.expect(0x0C).rest(), java.nio.charset.StandardCharsets.UTF_8);
            String text = new String(pair.expect(0x0C).rest(), java.nio.charset.StandardCharsets.UTF_8);
            if (labels.length() > 0) labels.append(';');
            labels.append(key).append('=').append(text);
        }
        return "version=" + version + " digest=" + digest + " epoch=" + epoch + " labels=" + labels;
    }

    // ---- The server ----

    static void say(String line) {
        System.out.println(line);
        System.out.flush();
    }

    static SSLServerSocket listen(String[] args, boolean needClientAuth, Set<String> allowed)
            throws Exception {
        KeyStore keys = KeyStore.getInstance("PKCS12");
        keys.load(null, null);
        PrivateKey key = KeyFactory.getInstance("Ed25519")
            .generatePrivate(new PKCS8EncodedKeySpec(pemBody(args[2])));
        List<Certificate> chain = new ArrayList<>(certificates(args[1]));
        keys.setKeyEntry("server", key, new char[0], chain.toArray(new Certificate[0]));
        KeyManagerFactory keyManagers = KeyManagerFactory.getInstance("SunX509");
        keyManagers.init(keys, new char[0]);
        KeyStore trust = KeyStore.getInstance("PKCS12");
        trust.load(null, null);
        trust.setCertificateEntry("ca", certificates(args[0]).iterator().next());
        TrustManagerFactory trustManagers = TrustManagerFactory.getInstance("PKIX");
        trustManagers.init(trust);
        TrustManager[] wrapped = {
            new AllowList((X509ExtendedTrustManager) trustManagers.getTrustManagers()[0], allowed)
        };
        SSLContext context = SSLContext.getInstance("TLSv1.3");
        context.init(keyManagers.getKeyManagers(), wrapped, null);
        SSLServerSocket server = (SSLServerSocket) context.getServerSocketFactory()
            .createServerSocket(0, 8, InetAddress.getLoopbackAddress());
        server.setEnabledProtocols(new String[] {"TLSv1.3"});
        server.setEnabledCipherSuites(new String[] {"TLS_AES_128_GCM_SHA256"});
        server.setNeedClientAuth(needClientAuth);
        return server;
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("--decode")) { // The harness checks a PEM.
            X509Certificate decoded = (X509Certificate) certificates(args[1]).iterator().next();
            say("CERT spiffe=" + spiffe(decoded) + " " + identity(decoded));
            return;
        }
        boolean needClientAuth = true;
        String mode = "echo";
        Set<String> allowed = new HashSet<>();
        for (int i = 3; i < args.length; i++) {
            if (args[i].equals("--no-client-auth")) needClientAuth = false;
            else if (args[i].equals("--allow")) allowed.add(args[++i]);
            else if (args[i].equals("--mode")) mode = args[++i];
            else throw new IllegalArgumentException(args[i]);
        }
        SSLServerSocket server = listen(args, needClientAuth, allowed);
        say("LISTENING " + server.getLocalPort());
        while (true) {
            SSLSocket socket = (SSLSocket) server.accept();
            try {
                socket.startHandshake();
                X509Certificate[] peer = needClientAuth
                    ? (X509Certificate[]) socket.getSession().getPeerCertificates() : null;
                say("CONN " + (peer == null ? "no-client-certificate"
                    : "spiffe=" + spiffe(peer[0]) + " " + identity(peer[0])));
                serve(socket, mode);
                say("CLOSED clean");
            } catch (Exception failure) {
                say("FAILED " + failure.getClass().getSimpleName() + ": "
                    + String.valueOf(failure.getMessage()).replace('\n', ' '));
            } finally {
                try { socket.close(); } catch (IOException ignored) { }
            }
        }
    }

    static void serve(SSLSocket socket, String mode) throws Exception {
        InputStream in = socket.getInputStream();
        OutputStream out = socket.getOutputStream();
        byte[] buffer = new byte[4096];
        if (mode.equals("sse")) {
            if (in.read(buffer) <= 0) return; // The client says go.
            for (int i = 0; i < SSE_EVENTS; i++) {
                out.write(("data: " + i + " " + System.currentTimeMillis() + "\n\n").getBytes());
                out.flush();
                Thread.sleep(SSE_GAP_MS);
            }
        } else if (mode.equals("bulk")) {
            if (in.read(buffer) <= 0) return;
            byte[] chunk = new byte[16384];
            for (int sent = 0; sent < BULK_BYTES; sent += chunk.length) {
                for (int i = 0; i < chunk.length; i++) chunk[i] = (byte) ((sent + i) % 251);
                out.write(chunk);
            }
            out.flush();
            if (in.read(buffer) > 0) { // The client's proof that it read it all.
                say("BULK client sent after the key update");
                out.write("bulk done\n".getBytes());
                out.flush();
            }
        } else {
            int count;
            while ((count = in.read(buffer)) > 0) {
                say("DATA " + new String(buffer, 0, count).trim());
                out.write("echo:".getBytes());
                out.write(buffer, 0, count);
                out.flush();
            }
        }
    }
}
