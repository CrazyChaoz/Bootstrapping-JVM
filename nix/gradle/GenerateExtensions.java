import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.function.Function;
import java.util.regex.Pattern;
import java.security.MessageDigest;

/**
 * Generates the Kotlin DSL extensions for the Gradle API (what build-logic's GenerateKotlinExtensionsForGradleApi does),
 * with the code generators of kotlin-dsl-shared-runtime.
 * usage: GenerateExtensions <out-dir> <runtime-classpath-file> <api-jars-file> <dependency-jars-file> <include,...> <exclude,...>
 */
public class GenerateExtensions {
  static List<File> files(String list) throws Exception {
    List<File> r = new ArrayList<>();
    for (String l : Files.readAllLines(Path.of(list))) if (!l.isBlank()) r.add(new File(l.trim()));
    return r;
  }

  static Pattern pattern(String ant) {
    if (ant.endsWith("/**")) return Pattern.compile(Pattern.quote(ant.substring(0, ant.length() - 3).replace('/', '.')) + "(\\..+)?");
    if (ant.endsWith("/*")) return Pattern.compile(Pattern.quote(ant.substring(0, ant.length() - 2).replace('/', '.')) + "\\.[^.]+");
    return Pattern.compile(Pattern.quote(ant.replace('/', '.')));
  }

  public static void main(String[] a) throws Exception {
    File out = new File(a[0]);
    List<File> runtime = files(a[1]), api = files(a[2]), deps = files(a[3]);
    List<Pattern> includes = new ArrayList<>(), excludes = new ArrayList<>();
    for (String s : a[4].split(",")) if (!s.isEmpty()) includes.add(pattern(s));
    for (String s : a[5].split(",")) if (!s.isEmpty()) excludes.add(pattern(s));
    URL[] urls = new URL[runtime.size()];
    for (int i = 0; i < urls.length; i++) urls[i] = runtime.get(i).toURI().toURL();
    try (URLClassLoader loader = new URLClassLoader(urls, ClassLoader.getPlatformClassLoader())) {
      Function<String, Boolean> apiSpec = sourceName -> {
        int dot = sourceName.lastIndexOf('.');
        String pkg = dot < 0 ? "" : sourceName.substring(0, dot);
        if (pkg.matches(".+\\.internal(\\..+)?")) return false;
        boolean in = false;
        for (Pattern p : includes) in |= p.matcher(pkg).matches();
        for (Pattern p : excludes) if (p.matcher(pkg).matches()) return false;
        return in;
      };
      Function<String, String> hash = n -> {
        try {
          byte[] d = MessageDigest.getInstance("SHA-256").digest(n.getBytes("UTF-8"));
          return new java.math.BigInteger(1, d).toString(36).substring(0, 20);
        } catch (Exception e) { throw new RuntimeException(e); }
      };
      Function<String, String> since = n -> null;
      File pluginIds = new File(out, "org/gradle/kotlin/dsl/BuiltinPluginIdExtensions.kt");
      pluginIds.getParentFile().mkdirs();
      Map<String, Object> p1 = new HashMap<>();
      p1.put("file", pluginIds);
      p1.put("gradleJars", api);
      p1.put("pluginDependenciesSpecQualifiedName", "org.gradle.plugin.use.PluginDependenciesSpec");
      p1.put("pluginDependencySpecQualifiedName", "org.gradle.plugin.use.PluginDependencySpec");
      invoke(loader, "org.gradle.kotlin.dsl.internal.sharedruntime.codegen.PluginIdExtensionsFacade", p1);
      Map<String, Object> p2 = new HashMap<>();
      p2.put("asmLevel", 9 << 16);
      p2.put("platformClassLoader", ClassLoader.getPlatformClassLoader());
      p2.put("incubatingAnnotationTypeDescriptor", "Lorg/gradle/api/Incubating;");
      p2.put("outputDirectory", out);
      p2.put("packageName", "org.gradle.kotlin.dsl");
      p2.put("sourceFilesBaseName", "GradleApiKotlinDslExtensions");
      p2.put("hashTypeSourceName", hash);
      p2.put("classPath", api);
      p2.put("classPathDependencies", deps);
      p2.put("apiSpec", apiSpec);
      p2.put("functionSinceSupplier", since);
      Function<String, List<String>> paramNames = n -> null;
      p2.put("parameterNamesSupplier", paramNames);
      invoke(loader, "org.gradle.kotlin.dsl.internal.sharedruntime.codegen.ApiExtensionGeneratorFacade", p2);
    }
  }

  static void invoke(ClassLoader loader, String cls, Map<String, Object> params) throws Exception {
    Class<?> c = loader.loadClass(cls);
    Object o = c.getConstructor().newInstance();
    Method m = null;
    for (Method x : c.getMethods()) if (x.getName().equals("generate")) m = x;
    try { m.invoke(o, params); } catch (java.lang.reflect.InvocationTargetException e) { throw (Exception) e.getTargetException(); }
  }
}
