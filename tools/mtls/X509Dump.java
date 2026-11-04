// Test-only: reads the certificates `zig build x509-format` made and checks them with the JDK's own
// X.509 code (CertificateFactory), which is an implementation independent of src/x509.zig.
// Usage: java X509Dump.java <ca.der> <workload.der> <server.der>
// Prints one "ok: ..." line per check and exits 1 on the first failure.
import java.io.FileInputStream;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.Date;
import java.util.List;

public class X509Dump {
    static final String IDENTITY_OID = "2.25.192541954756406065736426278304158759968";

    static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("FAIL: " + what);
            System.exit(1);
        }
        System.out.println("ok: " + what);
    }

    static X509Certificate load(String path) throws Exception {
        try (FileInputStream in = new FileInputStream(path)) {
            return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(in);
        }
    }

    static boolean has_name(X509Certificate c, int type, String value) throws Exception {
        for (List<?> entry : c.getSubjectAlternativeNames()) {
            if (((Integer) entry.get(0)) == type && value.equals(entry.get(1))) return true;
        }
        return false;
    }

    public static void main(String[] args) throws Exception {
        X509Certificate ca = load(args[0]);
        X509Certificate workload = load(args[1]);
        X509Certificate server = load(args[2]);
        Date when = Date.from(Instant.parse("2023-11-14T22:13:20Z"));

        check(ca.getSigAlgName().equalsIgnoreCase("Ed25519"), "CA signature algorithm is Ed25519");
        ca.verify(ca.getPublicKey());
        check(true, "CA certificate verifies with its own key");
        check(ca.getBasicConstraints() == 0, "CA: basicConstraints cA with path length 0");
        check(ca.getKeyUsage()[5], "CA: keyUsage keyCertSign");
        ca.checkValidity(when);
        check(ca.getCriticalExtensionOIDs().size() == 2, "CA: exactly two critical extensions");

        workload.verify(ca.getPublicKey());
        check(true, "workload certificate verifies with the CA key");
        check(workload.getBasicConstraints() == -1, "workload: not a CA");
        check(workload.getKeyUsage()[0], "workload: keyUsage digitalSignature");
        check(workload.getExtendedKeyUsage().contains("1.3.6.1.5.5.7.3.2"), "workload: clientAuth");
        check(!workload.getExtendedKeyUsage().contains("1.3.6.1.5.5.7.3.1"), "workload: not serverAuth");
        check(has_name(workload, 6, "spiffe://prod.example/job/broker-1"), "workload: SPIFFE URI SAN");
        check(workload.getSubjectX500Principal().getName().equals("CN=broker-1"), "workload: subject CN");
        check(workload.getNonCriticalExtensionOIDs().contains(IDENTITY_OID), "workload: identity ext");
        workload.checkValidity(when);

        server.verify(ca.getPublicKey());
        check(true, "server certificate verifies with the CA key");
        check(server.getExtendedKeyUsage().contains("1.3.6.1.5.5.7.3.1"), "server: serverAuth");
        check(has_name(server, 2, "broker.botpike.com"), "server: dNSName SAN");
        check(server.getNonCriticalExtensionOIDs().contains(IDENTITY_OID) == false, "server: no identity ext");
        server.checkValidity(when);

        boolean refused = false;
        try {
            server.verify(workload.getPublicKey());
        } catch (Exception e) {
            refused = true;
        }
        check(refused, "server certificate does not verify under another key");
    }
}
