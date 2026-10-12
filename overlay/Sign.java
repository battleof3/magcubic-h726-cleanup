import com.android.apksig.ApkSigner;
import java.io.*;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.List;

public class Sign {
    public static void main(String[] a) throws Exception {
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (InputStream in = new FileInputStream(a[0])) { ks.load(in, a[1].toCharArray()); }
        PrivateKey key = (PrivateKey) ks.getKey("hy300", a[1].toCharArray());
        X509Certificate cert = (X509Certificate) ks.getCertificate("hy300");
        ApkSigner.SignerConfig sc = new ApkSigner.SignerConfig.Builder("hy300", key, List.of(cert)).build();
        new ApkSigner.Builder(List.of(sc))
            .setInputApk(new File(a[2])).setOutputApk(new File(a[3]))
            .setV1SigningEnabled(false).setAlignmentPreserved(true).setV2SigningEnabled(true).setV3SigningEnabled(true)
            .setMinSdkVersion(34).build().sign();
    }
}
