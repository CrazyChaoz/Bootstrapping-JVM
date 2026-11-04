// MkJar OUT DIR MANIFEST: a jar as sbt packages one: META-INF/MANIFEST.MF (the bytes of MANIFEST)
// first, then every directory of DIR (stored), then every file (deflated), each group sorted by
// name, all entries dated 2010-01-01 00:00 (sbt's fixed timestamp; run in UTC).
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.jar.*;
import java.util.stream.*;
import java.util.zip.*;

public class MkJar {
  static final long TIME = 1262304000000L;
  public static void main(String[] a) throws IOException {
    Path dir = Paths.get(a[1]);
    List<String> dirs = new ArrayList<>(), files = new ArrayList<>();
    try (Stream<Path> s = Files.walk(dir)) {
      for (Path p : (Iterable<Path>) s::iterator) {
        if (p.equals(dir)) continue;
        String n = dir.relativize(p).toString().replace('\\', '/');
        if (n.equals("META-INF/MANIFEST.MF") || n.equals("META-INF")) continue;
        if (Files.isDirectory(p)) dirs.add(n + "/"); else files.add(n);
      }
    }
    Collections.sort(dirs); Collections.sort(files);
    try (JarOutputStream out = new JarOutputStream(new BufferedOutputStream(new FileOutputStream(a[0])))) {
      JarEntry m = new JarEntry("META-INF/MANIFEST.MF"); m.setTime(TIME);
      out.putNextEntry(m); out.write(Files.readAllBytes(Paths.get(a[2]))); out.closeEntry();
      for (String d : dirs) {
        JarEntry e = new JarEntry(d); e.setTime(TIME); e.setMethod(ZipEntry.STORED); e.setSize(0); e.setCrc(0);
        out.putNextEntry(e); out.closeEntry();
      }
      for (String f : files) {
        JarEntry e = new JarEntry(f); e.setTime(TIME);
        out.putNextEntry(e); out.write(Files.readAllBytes(dir.resolve(f))); out.closeEntry();
      }
    }
  }
}
