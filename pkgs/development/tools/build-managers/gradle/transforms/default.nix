# The artifact transforms Gradle's build applies to third-party jars of the distribution
# (Transforms.kt): `minify` (fastutil-*-min.jar, jnr-constants-*-min.jar; the classes to keep
# are gradlebuild.minify's keepPatterns, read from the source tree) and `noModuleAnnotation`
# (jspecify-*-no-module-annotation.jar).
{
  lib,
  stdenv,
  jdk,
  python3,
  writeShellScript,
  gradleSrc,
  kotlinCompiler,
  kotlinAsm,
  asm,
  asm-commons,
  asm-tree,
}:

let
  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx2g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  asmJars = lib.concatMapStringsSep ":" (d: "${d}/share/java/${d.pname}.jar") [
    asm
    asm-commons
    asm-tree
  ];
  basics = "build-logic-commons/basics/src/main/kotlin/gradlebuild";

  tool = stdenv.mkDerivation {
    pname = "gradle-build-transforms";
    version = "0";
    src = gradleSrc;
    nativeBuildInputs = [
      jdk
      python3
    ];
    dontConfigure = true;
    buildPhase = ''
      mkdir -p build/src build/classes
      cp ${basics}/basics/classanalysis/*.kt build/src/
      cp ${./Transforms.kt} build/src/Transforms.kt
      # (the Gradle API they use only declares attributes and an exception annotation)
      python3 - build/src/AnalyzeAndShade.kt build/src/ClassAnalysisException.kt <<'EOF'
      import re, sys
      def edit(path, pattern, repl):
          s = open(path).read()
          s, n = re.subn(pattern, repl, s, flags=re.S | re.M)
          if n == 0:
              sys.exit(f"no match for {pattern} in {path}")
          open(path, "w").write(s)
      a, e = sys.argv[1:]
      edit(a, r"^import org\.gradle\.api\.attributes\.Attribute\n", "")
      edit(a, r"^object Attributes \{.*?\n\}\n", "")
      edit(e, r"^import org\.gradle\.internal\.exceptions\.Contextual\n", "")
      edit(e, r"^@Contextual\n", "")
      EOF
      ${kotlinRun} -no-reflect -nowarn -jvm-target 17 -cp ${asmJars} -d build/classes build/src/*.kt
    '';
    installPhase = ''
      mkdir -p $out/share/java $out/bin
      jar cf $out/share/java/gradle-build-transforms.jar -C build/classes .
      cat > $out/bin/gradle-build-transforms <<EOF
      #!/bin/sh
      exec ${jdk}/bin/java -cp $out/share/java/gradle-build-transforms.jar:${asmJars}:${kotlinCompiler}/lib/kotlin-stdlib.jar gradlebuild.transforms.TransformsKt "\$@"
      EOF
      chmod +x $out/bin/gradle-build-transforms
    '';
  };

  # a transformed jar, as `pname` (the name of the lock's jarFile without the version)
  transformed =
    {
      pname,
      version,
      script,
      jar,
    }:
    stdenv.mkDerivation {
      inherit pname version;
      dontUnpack = true;
      nativeBuildInputs = [ python3 ];
      buildPhase = ''
        mkdir -p $out/share/java
        export TZ=UTC
        ${script}
      '';
      passthru = {
        javaDeps = jar.javaDeps or [ ];
        original = jar;
      };
    };
in
{
  inherit tool;

  # Minify: `coordinates` ("group:name") selects the keepPatterns
  minify =
    {
      jar,
      coordinates,
      pname ? jar.pname,
    }:
    transformed {
      inherit pname jar;
      inherit (jar) version;
      script = ''
        python3 - ${gradleSrc}/${basics}.minify.gradle.kts ${lib.escapeShellArg coordinates} > keep <<'EOF'
        import re, sys
        s = open(sys.argv[1]).read()
        m = re.search(r'"' + re.escape(sys.argv[2]) + r'" to setOf\((.*?)\n    \)', s, re.S)
        if not m:
            sys.exit(f"no keepPatterns for {sys.argv[2]}")
        print("\n".join(re.findall(r'^\s*"([^"]+)",', m.group(1), re.M)))
        EOF
        ${tool}/bin/gradle-build-transforms minify ${jar}/share/java/${jar.pname}.jar $out/share/java/${pname}.jar $(cat keep)
      '';
    };

  # NoModuleAnnotation; `time`: the entries' time ("YYYY-MM-DD hh:mm:ss", UTC)
  noModuleAnnotation =
    {
      jar,
      time,
      pname ? jar.pname,
    }:
    transformed {
      inherit pname jar;
      inherit (jar) version;
      script = ''
        t=$(python3 -c 'import calendar, sys, time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")) * 1000)' ${lib.escapeShellArg time})
        ${tool}/bin/gradle-build-transforms no-module-annotation ${jar}/share/java/${jar.pname}.jar $out/share/java/${pname}.jar $t
      '';
    };
}
