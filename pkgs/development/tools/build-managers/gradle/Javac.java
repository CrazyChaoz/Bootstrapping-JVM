// javac the way Gradle's in-process compiler (JdkJavaCompiler) runs it: through javax.tools with
// a DiagnosticListener (so that javac keeps end positions, as it does with one: the line numbers
// of some synthesized code depend on them) and the options JavaCompilerArgumentsBuilder adds.
//
//   Javac ARG... (javac's options and source files; @FILE arguments are expanded, one per line)
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import javax.tools.Diagnostic;
import javax.tools.DiagnosticListener;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

public class Javac {
    public static void main(String[] args) throws IOException {
        List<String> options = new ArrayList<>();
        List<String> sources = new ArrayList<>();
        List<String> expanded = new ArrayList<>();
        for (String a : args) {
            if (a.startsWith("@")) {
                for (String l : Files.readAllLines(Paths.get(a.substring(1)), StandardCharsets.UTF_8)) {
                    if (!l.isEmpty()) expanded.add(l);
                }
            } else {
                expanded.add(a);
            }
        }
        boolean processors = false;
        for (String a : expanded) {
            if (a.endsWith(".java") && !a.startsWith("-")) {
                sources.add(a);
            } else {
                if (a.equals("-processorpath")) processors = true;
                options.add(a);
            }
        }
        if (!processors) options.add("-proc:none");
        options.add("-XDuseUnsharedTable=true");
        options.add("-sourcepath");
        options.add("");
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        int[] errors = {0};
        DiagnosticListener<JavaFileObject> listener = d -> {
            if (d.getKind() == Diagnostic.Kind.ERROR) {
                errors[0]++;
                System.err.println(d);
            }
        };
        StandardJavaFileManager fm = compiler.getStandardFileManager(listener, null, StandardCharsets.UTF_8);
        Iterable<? extends JavaFileObject> units = fm.getJavaFileObjectsFromStrings(sources);
        boolean ok = compiler.getTask(null, fm, listener, options, null, units).call();
        fm.close();
        System.exit(ok && errors[0] == 0 ? 0 : 1);
    }
}
