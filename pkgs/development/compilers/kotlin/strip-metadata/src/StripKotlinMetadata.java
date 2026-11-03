import java.io.*;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;

/**
 * Copies a jar, removing the kotlin.Metadata annotation from the classes
 * whose name matches a regular expression (like upstream Kotlin's
 * generators/infrastructure/strip-kotlin-annotations.kts).
 *
 * usage: StripKotlinMetadata CLASS_REGEX IN.jar OUT.jar
 */
public class StripKotlinMetadata {
    public static void main(String[] args) throws IOException {
        String regex = args[0];
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(args[1]));
             ZipOutputStream out = new ZipOutputStream(new FileOutputStream(args[2]))) {
            ZipEntry e;
            int stripped = 0;
            while ((e = in.getNextEntry()) != null) {
                byte[] bytes = readAll(in);
                String name = e.getName();
                if (name.endsWith(".class") && name.substring(0, name.length() - 6).matches(regex)) {
                    ClassReader cr = new ClassReader(bytes);
                    ClassWriter cw = new ClassWriter(0);
                    cr.accept(new ClassVisitor(Opcodes.ASM6, cw) {
                        @Override
                        public AnnotationVisitor visitAnnotation(String desc, boolean visible) {
                            if ("Lkotlin/Metadata;".equals(desc)) return null;
                            return super.visitAnnotation(desc, visible);
                        }
                    }, 0);
                    bytes = cw.toByteArray();
                    stripped++;
                }
                ZipEntry n = new ZipEntry(name);
                n.setTime(0);
                out.putNextEntry(n);
                out.write(bytes);
                out.closeEntry();
            }
            System.out.println("stripped kotlin.Metadata from " + stripped + " classes");
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toByteArray();
    }
}
