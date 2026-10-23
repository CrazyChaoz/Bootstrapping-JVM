import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.commons.*;

/**
 * Merges jars and relocates packages like the shadow plugin does for the embeddable Kotlin compiler.
 * usage: Relocate <prefix> <pkg,pkg..> <keep,keep..> <exclude,exclude..> <out.jar> <in.jar>...
 *   pkg: dotted packages moved below prefix ("com.google.protobuf" is moved to prefix.protobuf)
 *   keep: dotted names that are not relocated; exclude: path prefixes dropped.
 */
public class Relocate {
  static String prefix;
  static List<String> pkgs = new ArrayList<>();
  static Set<String> keep = new HashSet<>();

  static String relocateSlash(String n) {
    String dotted = n.replace('/', '.');
    for (String k : keep) if (dotted.equals(k) || dotted.startsWith(k + ".")) return n;
    if (n.startsWith("com/google/protobuf/")) return prefix.replace('.', '/') + "/protobuf/" + n.substring("com/google/protobuf/".length());
    for (String p : pkgs) {
      String ps = p.replace('.', '/');
      if (n.startsWith(ps + "/") || n.equals(ps)) return prefix.replace('.', '/') + "/" + n;
    }
    return n;
  }

  static String relocateDotted(String n) {
    return relocateSlash(n.replace('.', '/')).replace('/', '.');
  }

  static final Remapper remapper = new Remapper() {
    @Override public String map(String internalName) { return relocateSlash(internalName); }
    @Override public Object mapValue(Object v) {
      if (v instanceof String) {
        String s = (String) v;
        if (s.indexOf(' ') >= 0 || s.isEmpty()) return super.mapValue(v);
        String r = s.indexOf('/') >= 0 ? relocateSlash(s) : relocateDotted(s);
        return r;
      }
      return super.mapValue(v);
    }
  };

  public static void main(String[] a) throws Exception {
    prefix = a[0];
    pkgs.addAll(Arrays.asList(a[1].split(",")));
    for (String k : a[2].split(",")) if (!k.isEmpty()) keep.add(k);
    List<String> excl = new ArrayList<>();
    for (String e : a[3].split(",")) if (!e.isEmpty()) excl.add(e);
    Set<String> seen = new HashSet<>();
    Map<String, List<String>> services = new LinkedHashMap<>();
    try (ZipOutputStream out = new ZipOutputStream(new FileOutputStream(a[4]))) {
      for (int i = 5; i < a.length; i++) {
        try (ZipFile zf = new ZipFile(a[i])) {
          for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
            ZipEntry e = en.nextElement();
            String n = e.getName();
            if (e.isDirectory()) continue;
            boolean skip = false;
            for (String x : excl) if (n.startsWith(x)) skip = true;
            if (skip) continue;
            if (n.equals("META-INF/MANIFEST.MF") || n.matches("META-INF/[^/]*\\.(SF|RSA|DSA)")) continue;
            byte[] data;
            try (InputStream in = zf.getInputStream(e)) { data = in.readAllBytes(); }
            String nn;
            if (n.startsWith("META-INF/services/")) {
              String svc = relocateDotted(n.substring("META-INF/services/".length()));
              List<String> l = services.computeIfAbsent(svc, k -> new ArrayList<>());
              for (String line : new String(data, StandardCharsets.UTF_8).split("\n")) {
                String t = line.trim();
                String r = t.isEmpty() || t.startsWith("#") ? line : relocateDotted(t);
                if (!l.contains(r)) l.add(r);
              }
              continue;
            } else if (n.endsWith(".class") && !n.equals("module-info.class") && !n.startsWith("META-INF/")) {
              ClassReader cr = new ClassReader(data);
              ClassWriter cw = new ClassWriter(0);
              cr.accept(new ClassRemapper(cw, remapper), 0);
              data = cw.toByteArray();
              nn = relocateSlash(n.substring(0, n.length() - 6)) + ".class";
            } else if (n.startsWith("META-INF/")) {
              nn = n;
            } else {
              int s = n.lastIndexOf('/');
              nn = s < 0 ? n : relocateSlash(n.substring(0, s)) + n.substring(s);
            }
            if (!seen.add(nn)) continue;
            ZipEntry ne = new ZipEntry(nn);
            ne.setTime(315532800000L);
            out.putNextEntry(ne);
            out.write(data);
            out.closeEntry();
          }
        }
      }
      for (Map.Entry<String, List<String>> s : services.entrySet()) {
        ZipEntry ne = new ZipEntry("META-INF/services/" + s.getKey());
        ne.setTime(315532800000L);
        out.putNextEntry(ne);
        out.write((String.join("\n", s.getValue()) + "\n").getBytes(StandardCharsets.UTF_8));
        out.closeEntry();
      }
    }
  }
}
