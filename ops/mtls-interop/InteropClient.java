import java.io.InputStream;
import java.io.OutputStream;
import java.io.PushbackInputStream;
import java.net.SocketTimeoutException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.List;
import javax.net.ssl.KeyManager;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;

/**
 * A stock JDK 21 TLS 1.3 client for `zig build mtls-interop` (src/mtls_interop_server.zig, B7
 * slice 4): it connects to `zcube-server --listen`, presents a client certificate when given one,
 * sends one HTTP request and prints the reply's status line. A test tool only: nothing here ships
 * (docs/decisions/2026-11-05-interop-tools-are-test-only.md).
 *
 * Usage: InteropClient CA.pem PORT SERVER-NAME PATH [CERT.pem KEY.pem]
 *
 * It prints one line: `STATUS <status line>` when a reply came, or `FAILED <exception>: <message>`.
 * The server's certificate must chain to CA.pem and name SERVER-NAME (endpoint identification).
 *
 * With `-Dinterop.eager=true` it writes its request at once after its Finished, without waiting
 * for an alert, and a failed write is reported, not ignored: a server that refuses the certificate
 * must still deliver its alert (it lingers, reading, before it closes) and not reset the
 * connection under the request (src/server_http.zig, `linger_refused`).
 */
public final class InteropClient {
    public static void main(String[] args) throws Exception {
        if (args.length != 4 && args.length != 6) {
            throw new IllegalArgumentException("usage: InteropClient CA PORT NAME PATH [CERT KEY]");
        }
        int port = Integer.parseInt(args[1]);
        String name = args[2];
        String path = args[3];
        boolean eager = Boolean.getBoolean("interop.eager");
        try {
            SSLContext context = SSLContext.getInstance("TLSv1.3");
            KeyManager[] keys = args.length == 6 ? keyManagers(args[4], args[5]) : null;
            context.init(keys, trustManagers(args[0]).getTrustManagers(), null);
            Socket plain = new Socket();
            plain.connect(new InetSocketAddress("127.0.0.1", port), 5000);
            plain.setSoTimeout(5000);
            SSLSocket socket = (SSLSocket) context.getSocketFactory()
                .createSocket(plain, name, port, true);
            SSLParameters parameters = socket.getSSLParameters();
            parameters.setProtocols(new String[] {"TLSv1.3"});
            parameters.setCipherSuites(new String[] {"TLS_AES_128_GCM_SHA256"});
            parameters.setServerNames(List.of(new SNIHostName(name)));
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            socket.setSSLParameters(parameters);
            socket.startHandshake();
            // In TLS 1.3 the server judges our certificate after our Finished, so a refusal comes
            // as an alert after the handshake "completed". Wait briefly for one before writing:
            // a write into a closed connection fails with a broken pipe that hides the alert.
            PushbackInputStream in = new PushbackInputStream(socket.getInputStream());
            if (!eager) {
                socket.setSoTimeout(500);
                try {
                    int first = in.read();
                    if (first >= 0) in.unread(first);
                } catch (SocketTimeoutException quiet) {
                    // No alert: the server accepted the certificate.
                }
                socket.setSoTimeout(5000);
            }
            OutputStream out = socket.getOutputStream();
            String request = "GET " + path + " HTTP/1.1\r\nHost: " + name
                + "\r\nConnection: close\r\n\r\n";
            try {
                out.write(request.getBytes(StandardCharsets.US_ASCII));
                out.flush();
            } catch (java.io.IOException failed) {
                // A server that refused our certificate sent its alert and closed: the write
                // fails, and the read below reports the alert, which says why. An eager client
                // writes before the alert can have come, so its write must not fail.
                if (eager) throw failed;
            }
            String line = statusLine(in);
            socket.close();
            InteropServer.say("STATUS " + line);
        } catch (Exception failure) {
            InteropServer.say("FAILED " + failure.getClass().getSimpleName() + ": "
                + String.valueOf(failure.getMessage()).replace('\n', ' '));
        }
    }

    static TrustManagerFactory trustManagers(String ca) throws Exception {
        KeyStore trust = KeyStore.getInstance("PKCS12");
        trust.load(null, null);
        trust.setCertificateEntry("ca", InteropServer.certificates(ca).iterator().next());
        TrustManagerFactory factory = TrustManagerFactory.getInstance("PKIX");
        factory.init(trust);
        return factory;
    }

    static KeyManager[] keyManagers(String cert, String key) throws Exception {
        KeyStore keys = KeyStore.getInstance("PKCS12");
        keys.load(null, null);
        PrivateKey privateKey = KeyFactory.getInstance("Ed25519")
            .generatePrivate(new PKCS8EncodedKeySpec(InteropServer.pemBody(key)));
        List<Certificate> chain = new ArrayList<>(InteropServer.certificates(cert));
        keys.setKeyEntry("client", privateKey, new char[0], chain.toArray(new Certificate[0]));
        KeyManagerFactory factory = KeyManagerFactory.getInstance("SunX509");
        factory.init(keys, new char[0]);
        return factory.getKeyManagers();
    }

    /** The first line of the reply; a server that refused the certificate fails the read. */
    static String statusLine(InputStream in) throws Exception {
        StringBuilder line = new StringBuilder();
        while (true) {
            int b = in.read();
            if (b < 0 || b == '\n') break;
            if (b != '\r') line.append((char) b);
        }
        if (line.length() == 0) throw new java.io.EOFException("no reply");
        return line.toString();
    }
}
