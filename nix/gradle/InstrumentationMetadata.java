import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.ClassReader;

/**
 * Merges the instrumentation metadata of Gradle's module jars into the files of gradle-runtime-api-info.jar
 * (what InstrumentedSuperTypesMergeTask and UpgradedPropertiesMergeTask do in Gradle's own build).
 * usage: InstrumentationMetadata <outDir> <jar>...
 */
public class InstrumentationMetadata {
  public static void main(String[] a) throws Exception {
    File out = new File(a[0]);
    Map<String, Set<String>> direct = new TreeMap<>();
    Set<String> instrumented = new HashSet<>();
    List<String> upgraded = new ArrayList<>();
    List<String> jars = new ArrayList<>(Arrays.asList(a).subList(1, a.length));
    Collections.sort(jars);
    for (String j : jars) {
      try (ZipFile zf = new ZipFile(j)) {
        for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
          ZipEntry e = en.nextElement();
          String n = e.getName();
          if (n.endsWith(".class") && !n.equals("module-info.class") && !n.startsWith("META-INF/")) {
            try (InputStream in = zf.getInputStream(e)) {
              ClassReader r = new ClassReader(in);
              String cn = n.substring(0, n.length() - 6);
              Set<String> s = new LinkedHashSet<>();
              if (r.getSuperName() != null) s.add(r.getSuperName());
              s.addAll(Arrays.asList(r.getInterfaces()));
              s.add(cn);
              s.removeIf(x -> !x.startsWith("org/gradle"));
              direct.computeIfAbsent(cn, k -> new LinkedHashSet<>()).addAll(s);
            }
          } else if (n.endsWith("/instrumented-classes.txt") || n.equals("instrumented-classes.txt")) {
            try (BufferedReader br = new BufferedReader(new InputStreamReader(zf.getInputStream(e), StandardCharsets.UTF_8))) {
              for (String l; (l = br.readLine()) != null; ) if (!l.isEmpty()) instrumented.add(l);
            }
          } else if (n.endsWith("/upgraded-properties.json") || n.equals("upgraded-properties.json")) {
            String t = new String(zf.getInputStream(e).readAllBytes(), StandardCharsets.UTF_8).trim();
            t = t.substring(t.indexOf('[') + 1, t.lastIndexOf(']')).trim();
            if (!t.isEmpty()) upgraded.add(t);
          }
        }
      }
    }
    // all transitive super types, keeping only instrumented ones
    TreeMap<String, TreeSet<String>> result = new TreeMap<>();
    for (String c : direct.keySet()) {
      Set<String> collected = new LinkedHashSet<>();
      collected.add(c);
      ArrayDeque<String> q = new ArrayDeque<>(direct.get(c));
      while (!q.isEmpty()) {
        String s = q.poll();
        if (collected.add(s)) q.addAll(direct.getOrDefault(s, Set.of()));
      }
      TreeSet<String> keep = new TreeSet<>();
      for (String s : collected) if (instrumented.contains(s)) keep.add(s);
      if (!keep.isEmpty()) result.put(c, keep);
    }
    out.mkdirs();
    if (!result.isEmpty()) {
      try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(out, "instrumented-super-types.properties")), StandardCharsets.UTF_8)) {
        for (Map.Entry<String, TreeSet<String>> e : result.entrySet())
          w.write(e.getKey() + "=" + String.join(",", e.getValue()) + "\n");
      }
    }
    if (!upgraded.isEmpty()) {
      try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(out, "upgraded-properties.json")), StandardCharsets.UTF_8)) {
        w.write("[" + String.join(",", upgraded) + "]");
      }
    }
  }
}
