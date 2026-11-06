// bin/gradle and bin/gradle.bat as Gradle's build writes them (build-logic's
// GradleStartScriptGenerator): the application plugin's templates, rendered by its own start
// script generator, then the -javaagent options appended to DEFAULT_JVM_OPTS.
//
// usage: StartScripts UNIX_TEMPLATE WINDOWS_TEMPLATE GIT_REF LAUNCHER_JAR OUT_DIR AGENT_JAR...
import com.google.common.io.Files;
import org.gradle.api.internal.plugins.DefaultTemplateBasedStartScriptGenerator;
import org.gradle.api.internal.plugins.ExecutableJar;
import org.gradle.api.internal.plugins.StartScriptGenerator;
import org.gradle.api.internal.plugins.StartScriptTemplateBindingFactory;
import org.gradle.api.internal.resources.CharSourceBackedTextResource;
import org.gradle.util.internal.TextUtil;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class StartScripts {
    public static void main(String[] args) throws Exception {
        List<String> agents = Arrays.asList(args).subList(5, args.length);
        StartScriptGenerator generator = new StartScriptGenerator(
            new DefaultTemplateBasedStartScriptGenerator(TextUtil.getUnixLineSeparator(), StartScriptTemplateBindingFactory.unix(),
                new CharSourceBackedTextResource("unix template", Files.asCharSource(new File(args[0]), StandardCharsets.UTF_8))),
            new DefaultTemplateBasedStartScriptGenerator(TextUtil.getWindowsLineSeparator(), StartScriptTemplateBindingFactory.windows(),
                new CharSourceBackedTextResource("windows template", Files.asCharSource(new File(args[1]), StandardCharsets.UTF_8))));
        generator.setApplicationName("Gradle");
        generator.setGitRef(args[2]);
        generator.setOptsEnvironmentVar("GRADLE_OPTS");
        generator.setEntryPoint(new ExecutableJar("lib/" + args[3]));
        generator.setScriptRelPath("bin/gradle");
        generator.setClasspath(new ArrayList<>());
        generator.setAppNameSystemProperty("org.gradle.appname");
        generator.setDefaultJvmOpts(Arrays.asList("-Xmx64m", "-Xms64m"));

        File unix = new File(args[4], "gradle");
        generator.generateUnixScript(unix);
        injectAgentOptions(unix, "\n", agents);
        File windows = new File(args[4], "gradle.bat");
        generator.generateWindowsScript(windows);
        injectAgentOptions(windows, "\r\n", agents);
    }

    // GradleStartScriptGenerator.injectAgentOptions (Kotlin's readLines: \n, \r\n and \r end a line)
    static void injectAgentOptions(File file, String separator, List<String> agents) throws Exception {
        if (agents.isEmpty()) {
            return;
        }
        String text = new String(java.nio.file.Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
        List<String> lines = new ArrayList<>(Arrays.asList(text.split("\r\n|\n|\r", -1)));
        if (!lines.isEmpty() && lines.get(lines.size() - 1).isEmpty()) {
            lines.remove(lines.size() - 1);
        }
        int replacements = 0;
        StringBuilder out = new StringBuilder();
        for (String line : lines) {
            if (line.startsWith("DEFAULT_JVM_OPTS='") && line.endsWith("'")) {
                replacements++;
                List<String> opts = new ArrayList<>();
                for (String a : agents) {
                    opts.add("\\\"-javaagent:$APP_HOME/lib/agents/" + a + "\\\"");
                }
                line = line + "\" " + String.join(" ", opts) + "\"";
            } else if (line.startsWith("set DEFAULT_JVM_OPTS=")) {
                replacements++;
                List<String> opts = new ArrayList<>();
                for (String a : agents) {
                    opts.add("-javaagent:%APP_HOME%/lib/agents/" + a);
                }
                line = line + " \"" + String.join(" ", opts) + "\"";
            }
            out.append(line).append(separator);
        }
        if (replacements != 1) {
            throw new IllegalStateException("The script file produced by the default start script doesn't match expected layout");
        }
        java.nio.file.Files.write(file.toPath(), out.toString().getBytes(StandardCharsets.UTF_8));
    }
}
