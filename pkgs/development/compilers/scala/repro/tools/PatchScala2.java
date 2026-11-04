// PatchScala2 CLASSDIR SCALA2DIR FILESTOCOPY: ScalaLibraryPlugin's manipulateBytecode (scala3
// project/ScalaLibraryPlugin.scala) and StripScala2Annotations.patchFile, with ASM.
// 1. every class (and .sjsir) of SCALA2DIR whose path is one of FILESTOCOPY or starts with it plus '$'
//    replaces the compiled one in CLASSDIR; 2. every other SCALA2DIR file CLASSDIR lacks is added.
// Both go through patchFile: ScalaSig/ScalaInlineInfo attributes and ScalaSignature/ScalaLongSignature
// annotations dropped, a TASTY attribute (UUID of the .tasty) on the primary class, a "Scala"
// attribute where missing (unless Java-sourced).
import org.objectweb.asm.*;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class PatchScala2 {
  static final Set<String> PICKLE_ANNOTS = Set.of("Lscala/reflect/ScalaSignature;", "Lscala/reflect/ScalaLongSignature;");
  static final Set<String> PICKLE_ATTRS = Set.of("ScalaSig", "ScalaInlineInfo");

  public static void main(String[] a) throws IOException {
    Path classDir = Paths.get(a[0]), ref = Paths.get(a[1]);
    List<String> copy = Files.readAllLines(Paths.get(a[2])).stream().map(String::trim)
        .filter(s -> !s.isEmpty() && !s.startsWith("#")).collect(Collectors.toList());
    List<Path> files;
    try (Stream<Path> s = Files.walk(ref)) {
      files = s.filter(p -> p.toString().endsWith(".class") || p.toString().endsWith(".sjsir"))
          .sorted().collect(Collectors.toList());
    }
    int replaced = 0, added = 0;
    for (Path f : files) {
      String id = ref.relativize(f).toString();
      String path = id.replace('\\', '/');
      if (path.endsWith(".class")) path = path.substring(0, path.length() - 6);
      if (path.endsWith(".sjsir")) path = path.substring(0, path.length() - 6);
      final String p = path;
      if (copy.stream().anyMatch(s -> p.equals(s) || p.startsWith(s + "$"))) {
        patchFile(f, classDir.resolve(id), classDir); replaced++;
      }
    }
    Set<String> present;
    try (Stream<Path> s = Files.walk(classDir)) {
      present = s.map(p -> classDir.relativize(p).toString()).collect(Collectors.toSet());
    }
    for (Path f : files) {
      String id = ref.relativize(f).toString();
      if (!present.contains(id)) { patchFile(f, classDir.resolve(id), classDir); added++; }
    }
    System.err.println("PatchScala2: replaced " + replaced + ", added " + added);
  }

  static byte[] uuidOfTasty(byte[] t) {
    // header: magic (4), major/minor/experimental (3 nats), tooling string (nat length + bytes), UUID (16)
    int[] pos = {4};
    for (int i = 0; i < 3; i++) readNat(t, pos);
    int len = readNat(t, pos);
    pos[0] += len;
    return Arrays.copyOfRange(t, pos[0], pos[0] + 16);
  }
  static int readNat(byte[] b, int[] pos) {
    int x = 0, c;
    do { c = b[pos[0]++] & 0xff; x = (x << 7) | (c & 0x7f); } while ((c & 0x80) == 0);
    return x;
  }

  static byte[] tastyOfClass(byte[] bytes) {
    byte[][] result = {null};
    Attribute proto = new Attribute("TASTY") {
      @Override protected Attribute read(ClassReader cr, int off, int len, char[] buf, int codeOff, Label[] labels) {
        if (len == 16) { byte[] u = new byte[16]; for (int i = 0; i < 16; i++) u[i] = (byte) cr.readByte(off + i); result[0] = u; }
        return this;
      }
    };
    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {}, new Attribute[]{proto}, 0);
    return result[0];
  }

  static String sourceFile(byte[] bytes) {
    String[] r = {null};
    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
      @Override public void visitSource(String source, String debug) { r[0] = source; }
    }, ClassReader.SKIP_CODE | ClassReader.SKIP_FRAMES);
    return r[0];
  }

  static boolean hasScalaAttribute(byte[] bytes) {
    boolean[] r = {false};
    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
      @Override public void visitAttribute(Attribute attr) { if (attr.type.equals("Scala")) r[0] = true; }
    }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
    return r[0];
  }

  static class Raw extends Attribute {
    final byte[] content;
    Raw(String type, byte[] content) { super(type); this.content = content; }
    @Override protected ByteVector write(ClassWriter cw, byte[] code, int codeLength, int maxStack, int maxLocals) {
      ByteVector bv = new ByteVector(content.length); bv.putByteArray(content, 0, content.length); return bv;
    }
  }

  static byte[] patchClassFile(byte[] bytes, byte[] uuid) {
    ClassReader reader = new ClassReader(bytes);
    ClassWriter writer = new ClassWriter(0);
    reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
      @Override public void visitAttribute(Attribute attr) { if (!PICKLE_ATTRS.contains(attr.type)) super.visitAttribute(attr); }
      @Override public AnnotationVisitor visitAnnotation(String desc, boolean visible) {
        return PICKLE_ANNOTS.contains(desc) ? null : super.visitAnnotation(desc, visible);
      }
    }, 0);
    if (uuid != null) writer.visitAttribute(new Raw("TASTY", uuid));
    String sf = sourceFile(bytes);
    boolean javaSourced = sf != null && sf.endsWith(".java");
    if (!hasScalaAttribute(bytes) && !javaSourced) writer.visitAttribute(new Raw("Scala", new byte[0]));
    return writer.toByteArray();
  }

  static void patchFile(Path input, Path output, Path classDir) throws IOException {
    Files.createDirectories(output.getParent());
    if (input.toString().endsWith(".sjsir")) { Files.copy(input, output, StandardCopyOption.REPLACE_EXISTING); return; }
    byte[] original = Files.exists(output) ? tastyOfClass(Files.readAllBytes(output)) : null;
    String rel = classDir.relativize(output).toString();
    String classPath = rel.substring(0, rel.length() - 6);
    String basePath = classPath.split("\\$")[0];
    byte[] bytes = Files.readAllBytes(input);
    String sf = sourceFile(bytes);
    byte[] uuid = null;
    if (!(sf != null && sf.endsWith(".java"))) {
      Path tasty = classDir.resolve(basePath + ".tasty");
      if (!Files.exists(tasty)) throw new AssertionError("TASTY file " + tasty + " does not exist for " + rel);
      if (classPath.equals(basePath)) uuid = uuidOfTasty(Files.readAllBytes(tasty));
    }
    if ((uuid == null) != (original == null) || (uuid != null && !Arrays.equals(uuid, original)))
      throw new AssertionError("TASTY attribute mismatch for " + rel);
    Files.write(output, patchClassFile(bytes, uuid));
  }
}
