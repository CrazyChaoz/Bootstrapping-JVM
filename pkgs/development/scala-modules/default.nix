# Scala 2.13 libraries compiled from source with the chain's scalac 2.13.18 (stage s230):
# Zinc 1.12.0 (sbt's incremental compiler, which Gradle's `scala` plugin drives) and what it
# needs, and Scala 2.13.18's own jars as Maven publishes them (library, reflect, compiler).
#
# `mavenRepo` lays them out as a Maven repository with POMs written from the dependencies
# below, so that a Gradle build can resolve Scala and Zinc offline:
#   repositories { maven { url = uri("file://${mavenRepo}") } }
#
# Not built: the JNI libraries (swoval's file-tree-views and jline's native code ship
# prebuilt ones, which are dropped; both fall back to pure Java), and log4j-core's optional
# integrations (Kafka, JMS, mail, ZeroMQ, Jackson layouts, ...).
{
  lib,
  stdenv,
  fetchzip,
  runCommand,
  writeShellScript,
  writeText,
  jdk,
  python3,
  stripJavaArchivesHook,
  classpathOf,
  closureOf,
  protobuf_25,
  # scalac 2.13.18, the chain's stage s230
  s230,
  jansi,
  jsr305,
  # compile-only for log4j-core (its optional dependencies that are built: Jackson, commons-compress,
  # JCTools)
  log4jOptional ? [ ],
  jetbrainsAnnotations,
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };
  srcs = {
    zinc = gh "sbt" "zinc" "v1.12.0" "sha256-SlmoL1y3qJm3ntM8rIAZQFuIEcBfqieo8dWd8x0+7/U=";
    sbt = gh "sbt" "sbt" "v1.11.5" "sha256-/wffpY1Ttm/xCsp8Qn9JA4F2/yzAcj2+kd10ocAbzJA=";
    io = gh "sbt" "io" "v1.10.5" "sha256-dgvMYYJhgYp9YbJ3C3msoxN08yxNvL1wCDIeV9pIcKI=";
    launcher = gh "sbt" "launcher" "v1.4.4" "sha256-FvjY+es/osiYcOIR4lhNykx6JgrNMwiDA2v3I3Wv/0Q=";
    sjsonnew = gh "eed3si9n" "sjson-new" "v0.10.1" "sha256-vr/4AzDy5Hrsd0LCCK6eQDEetTx09hZ3oALVOficI08=";
    scalajson = gh "mdedetrich" "scalajson" "v1.0.0-M4" "sha256-fNSvXXZIWaon0Q00JF12L/AmrDvWQu4dwrXJOjmvfNQ=";
    jawn = gh "typelevel" "jawn" "v1.3.2" "sha256-54sD0AfzMtQ02AtRP3Czj5A4xiKVmmO/xEFUpgbIgp0=";
    scalaXml = gh "scala" "scala-xml" "v2.3.0" "sha256-M8U0ki62YgadEz4ZtVtR7BWwvnyzKZSdoGHGBrSckn4=";
    parallelCollections =
      gh "scala" "scala-parallel-collections" "v0.2.0"
        "sha256-spkWtSHMo9iaieAEYWB0kHb7GorwEk8VzZFaCsEF070=";
    parserCombinators =
      gh "scala" "scala-parser-combinators" "v1.1.2"
        "sha256-ZyceQbIQa08elM/HZaUS0GRbUN+FszOSwLXgOCus+mY=";
    sbinary = gh "sbt" "sbinary" "v0.5.1" "sha256-rFPTKoh5lZxD24jLvpzTBsoKHLHCFPK2rGCKZgcSsD8=";
    zeroAllocationHashing =
      gh "OpenHFT" "Zero-Allocation-Hashing" "zero-allocation-hashing-0.16"
        "sha256-xcQQJM/YfjZDiAmqCJrxkhrJxlV2bq2G5N6uDXP6zIM=";
    swoval = gh "swoval" "swoval" "v2.1.12" "sha256-QEj/lElk67emDqZQTSCU6ILXWrBo/KSX4/Aneh8pqgc=";
    jline3 = gh "jline" "jline3" "jline-3.27.1" "sha256-+g+TaAVdK5WoQ1/8VGX/BJh34lGXKeLiLCJJypaXOwk=";
    jline2 =
      gh "sbt" "jline2" "9a88bc413e2b34a4580c001c654d1a7f4f65bf18"
        "sha256-rgpMYWTkdTGuZRqSpYhh8JL30hnfD9xYZz+7iOE+8lw=";
    log4j = gh "apache" "logging-log4j2" "rel/2.17.1" "sha256-JpLYc/MM6fp9INWbKqVOkBFyaqJqxFZ3fTn7P4sMLzc=";
    disruptor = gh "LMAX-Exchange" "disruptor" "3.4.2" "sha256-7hIL+wvIp/JxRePNeSprx+4mOxNvWgLD4mAK90hoUFs=";
    protobuf = gh "protocolbuffers" "protobuf" "v25.8" "sha256-UUUblMKN1xFknFtanq5MRVQ57dzhOV9sPqlw1J37aNE=";
    kindProjector =
      gh "typelevel" "kind-projector" "v0.13.3"
        "sha256-JA9pE1kBhIHrP/240AuYugbZAaRtCe62poFxRrgAPmk=";
  };

  scalaVersion = "2.13.18";

  # --- Scala 2.13.18's jars, split out of the chain's stage s230 ----------------------
  # s230's out2/ holds library and compiler, quick/lib/ the library alone; reflect is what
  # src/reflect compiles to (scala/reflect/{api,internal,io,macros,runtime}), and the compiler
  # jar carries scala-asm, as upstream's does.  The chain compiles the compiler proper only;
  # src/{interactive,repl,repl-frontend,scaladoc}, which upstream's compiler jar also holds
  # (Zinc's console, Gradle's scaladoc task), are compiled here, the REPL's frontend against
  # jline 3.27.1 (upstream: 3.29.0, an optional dependency).  Scaladoc's fonts and images
  # are binaries and left out.  The *.properties as the release build writes them
  # (project/VersionUtil.scala; the chain's say 2.13.18-bootstrap).
  scalaProps = ''
    version.number=${scalaVersion}
    maven.version.number=${scalaVersion}
    osgi.version.number=${scalaVersion}.v20251115-142856-VFINAL-98f40d0
    copyright.string=Copyright 2002-2025, LAMP/EPFL and Lightbend, Inc. dba Akka
  '';
  scala2Split = stdenv.mkDerivation {
    name = "scala-${scalaVersion}-jars";
    dontUnpack = true;
    nativeBuildInputs = [
      jdk
      python3
      stripJavaArchivesHook
    ];
    buildPhase = ''
      runHook preBuild
      python3 - ${s230} <<'EOF'
      import os, shutil, sys
      s = sys.argv[1]
      reflect = ("scala/reflect/api/", "scala/reflect/internal/", "scala/reflect/io/",
                 "scala/reflect/macros/", "scala/reflect/runtime/")
      shutil.copytree(f"{s}/quick/lib", "library")
      os.makedirs("reflect"); os.makedirs("compiler")
      for d, _, fs in os.walk(f"{s}/out2"):
          for f in fs:
              rel = os.path.relpath(os.path.join(d, f), f"{s}/out2")
              if rel.endswith(".properties") and "/" not in rel:
                  continue
              if os.path.exists(f"{s}/quick/lib/{rel}"):
                  continue
              dest = "reflect" if rel.startswith(reflect) else "compiler"
              os.makedirs(os.path.dirname(f"{dest}/{rel}"), exist_ok=True)
              shutil.copy(os.path.join(d, f), f"{dest}/{rel}")
      shutil.copytree(f"{s}/classes/scala/tools/asm", "compiler/scala/tools/asm")
      EOF
      chmod -R u+w library reflect compiler
      cp=library:reflect:compiler
      jl=${lib.concatMapStringsSep ":" (d: "${d}/share/java/${d.pname}.jar") jlineForRepl}
      mkdir extra
      for t in interactive repl repl-frontend scaladoc; do cp -r ${s230}/src/$t extra/; done
      chmod -R u+w extra
      # scaladoc copies its fonts, images and the jQuery webjar into each site and asserts
      # they are there: copy those it has (not the binaries left out, nor jQuery's minified
      # build), so the site works without them (system fonts, no icons, no search)
      python3 - extra/scaladoc/scala/tools/nsc/doc/html/HtmlFactory.scala <<'EOF'
      import sys
      p = sys.argv[1]
      s = open(p, encoding="utf-8").read()
      for old, new in [
          ("def copyResource(subPath: String): Unit = {",
           'def copyResource(subPath: String): Unit = if (getClass.getResource("/scala/tools/nsc/doc/html/resource/" + subPath) != null) {'),
          ("def copyWebjarResource(resourceName: String, expectedSRI: String): Unit = {",
           'def copyWebjarResource(resourceName: String, expectedSRI: String): Unit = if (getClass.getResource("/" + resourceName) != null) {'),
      ]:
          assert s.count(old) == 1, old
          s = s.replace(old, new)
      open(p, "w", encoding="utf-8").write(s)
      EOF
      find extra \( -name '*.scala' -o -name '*.java' \) | LC_ALL=C sort > extra-sources
      java -Xss16m -Xmx3g -cp $cp scala.tools.nsc.Main -nowarn -release:8 -encoding UTF-8 \
        -classpath $cp:$jl -d compiler @extra-sources
      grep '\.java$' extra-sources > extra-jsources
      javac -nowarn --release 8 -encoding UTF-8 -cp compiler:$cp:$jl -d compiler @extra-jsources
      (cd ${s230}/src/scaladoc && find . -type f \( -name '*.css' -o -name '*.js' -o -name '*.svg' \) \
        -exec install -Dm644 {} $NIX_BUILD_TOP/compiler/{} \;)
      for p in library reflect compiler; do
        cat > $p/$p.properties <<'EOF'
      ${scalaProps}
      EOF
        sed -i 's/^ *//' $p/$p.properties
      done
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out
      for p in library reflect compiler; do
        printf 'Manifest-Version: 1.0\nImplementation-Title: scala-%s\nImplementation-Version: ${scalaVersion}\nImplementation-Vendor: LAMP/EPFL\n' $p > manifest
        jar cfm $out/scala-$p.jar manifest -C $p .
      done
    '';
  };
  jlineForRepl = with self; [
    jline-terminal
    jline-reader
    jline-style
    jline-builtins
  ];
  scalaJar =
    name: deps:
    runCommand "${name}-${scalaVersion}"
      {
        passthru = {
          javaDeps = closureOf deps;
          pname = name;
          version = scalaVersion;
          maven = {
            group = "org.scala-lang";
            artifact = name;
            version = scalaVersion;
            inherit deps;
          };
        };
      }
      ''
        mkdir -p $out/share/java
        ln -s ${scala2Split}/${name}.jar $out/share/java/${name}.jar
      '';

  scalaCp = "${scala2Split}/scala-library.jar:${scala2Split}/scala-reflect.jar:${scala2Split}/scala-compiler.jar";
  scalac = writeShellScript "scalac" ''
    exec ${jdk}/bin/java -Xss16m -Xmx3g -cp ${scalaCp} scala.tools.nsc.Main "$@"
  '';

  # --- one jar from Java and/or Scala sources -----------------------------------------
  # Scala sources go through scalac (with the Java sources, for their types), then javac
  # compiles the Java sources against the result: sbt's Mixed order.
  mkLib =
    {
      pname,
      version,
      group,
      artifact ? if scala then "${pname}_2.13" else pname,
      src,
      sourceDirs,
      scala ? true,
      deps ? [ ],
      buildDeps ? [ ], # compile only (Maven's "provided")
      resourceDirs ? [ ],
      # extended regex: sources matching it are dropped (optional integrations), and then the
      # Java sources javac fails on, until it succeeds
      dropSources ? null,
      scalacFlags ? [ ],
      # scalac plugins (derivations with share/java/PNAME.jar)
      plugins ? [ ],
      javacFlags ? [ ],
      javaRelease ? "8",
      useRelease ? true,
      preBuild ? "",
      postBuild ? "",
      postInstall ? "",
      passthru ? { },
    }:
    let
      allDeps = deps ++ lib.optional scala self.scala-library;
    in
    stdenv.mkDerivation {
      inherit pname version src;
      nativeBuildInputs = [
        jdk
        python3
        stripJavaArchivesHook
      ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${preBuild}
        CP="${classpathOf (allDeps ++ buildDeps)}"
        mkdir -p .b/classes
        for d in ${lib.escapeShellArgs sourceDirs}; do
          find "$d" \( -name '*.scala' -o -name '*.java' \) -not -name module-info.java
        done | LC_ALL=C sort > .b/sources
        ${lib.optionalString (dropSources != null) ''
          xargs -r grep -lE ${lib.escapeShellArg dropSources} < .b/sources > .b/dropped || true
          echo "dropping $(wc -l < .b/dropped) sources (optional integrations)"
          grep -vxFf .b/dropped .b/sources > .b/kept || true
          mv .b/kept .b/sources
        ''}
        ${
          if scala then
            ''
              echo "scalac: $(grep -c '\.scala$' .b/sources) Scala sources"
              ${scalac} -nowarn ${
                if useRelease then "-release:${javaRelease}" else "-target:${javaRelease}"
              } -encoding UTF-8 -classpath "$CP" -d .b/classes \
                ${
                  lib.concatMapStrings (p: "-Xplugin:${p}/share/java/${p.pname}.jar ") plugins
                }${lib.escapeShellArgs scalacFlags} @.b/sources
            ''
          else
            ''
              if grep -q '\.scala$' .b/sources; then echo "Scala sources in a Java library"; exit 1; fi
            ''
        }
        grep '\.java$' .b/sources > .b/jsources || true
        if [ -s .b/jsources ]; then
          echo "javac: $(wc -l < .b/jsources) Java sources"
          javacRun() {
            javac -nowarn -Xmaxerrs 100000 -encoding UTF-8 ${
              if useRelease then "--release ${javaRelease}" else "-source ${javaRelease} -target ${javaRelease}"
            } -cp ".b/classes:$CP" -d .b/classes ${lib.escapeShellArgs javacFlags} @.b/jsources
          }
          ${
            if dropSources == null then
              "javacRun"
            else
              ''
                until javacRun 2> .b/javac.log; do
                  sed -n 's/^\([^ :]*\.java\):[0-9]*: error:.*/\1/p' .b/javac.log | sort -u > .b/failed
                  if [ ! -s .b/failed ]; then cat .b/javac.log; exit 1; fi
                  echo "dropping $(wc -l < .b/failed) sources that need the dropped ones"
                  cat .b/failed >> .b/dropped
                  grep -vxFf .b/failed .b/jsources > .b/kept || true
                  mv .b/kept .b/jsources
                  rm -rf .b/classes; mkdir -p .b/classes
                done
                cp .b/jsources .b/sources
              ''
          }
        fi
        for d in ${lib.escapeShellArgs resourceDirs}; do cp -r "$d"/. .b/classes/; done
        chmod -R u+w .b/classes
        # no prebuilt native code
        find .b/classes \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' -o -name '*.jnilib' \) -print -delete
        ${postBuild}
        runHook postBuild
      '';
      installPhase = ''
        mkdir -p $out/share/java
        printf 'Manifest-Version: 1.0\nImplementation-Title: %s\nImplementation-Version: %s\nImplementation-Vendor-Id: %s\n' \
          ${artifact} ${version} ${group} > manifest
        jar cfm $out/share/java/${pname}.jar manifest -C .b/classes .
        ${postInstall}
      '';
      passthru = {
        javaDeps = closureOf allDeps;
        maven = {
          inherit group artifact version;
          deps = allDeps;
        };
      }
      // passthru;
    };

  # shade a Scala package by prefixing it (sjson-new's shaded scalajson and jawn)
  shadeScala = from: to: ''
    python3 - ${from} ${to} <<'EOF'
    import os, re, sys
    frm, to = sys.argv[1:]
    pat = re.compile(r"(?<![\w.])" + re.escape(frm) + r"(?=[.\s{])")
    for d, _, fs in os.walk("."):
        for f in fs:
            if f.endswith(".scala"):
                p = os.path.join(d, f)
                s = open(p, encoding="utf-8").read()
                t = pat.sub(to, s)
                if t != s:
                    os.chmod(p, 0o644)
                    open(p, "w", encoding="utf-8").write(t)
    EOF
  '';

  # [ [ file regex replacement ] ... ]: each must match
  edit =
    edits:
    lib.concatMapStrings (e: ''
      python3 - ${lib.escapeShellArgs e} <<'EOF'
      import os, re, sys
      p, pat, rep = sys.argv[1:]
      s = open(p, encoding="utf-8").read()
      t, n = re.subn(pat, rep, s, flags=re.M)
      if n == 0:
          sys.exit(f"edit: no match for {pat!r} in {p}")
      os.chmod(p, 0o644)
      open(p, "w", encoding="utf-8").write(t)
      EOF
    '') edits;

  # (Gradle's jansi, with its Maven coordinates for the repository below)
  jansiM = jansi // {
    maven = {
      group = "org.fusesource.jansi";
      artifact = "jansi";
      inherit (jansi) version;
      deps = [ ];
    };
  };

  sbtUtil = "1.11.5";
  zincVersion = "1.12.0";
  zincMod =
    pname: dirs: deps:
    mkLib {
      inherit pname deps;
      version = zincVersion;
      group = "org.scala-sbt";
      src = srcs.zinc;
      sourceDirs = dirs;
    };

  self = {
    inherit srcs scalac scala2Split;

    scala-library = scalaJar "scala-library" [ ];
    scala-reflect = scalaJar "scala-reflect" [ self.scala-library ];
    scala-compiler = scalaJar "scala-compiler" [
      self.scala-library
      self.scala-reflect
    ];

    # the scalac plugin of sbt's sources (type lambdas, polymorphic lambdas)
    kind-projector = mkLib {
      pname = "kind-projector";
      version = "0.13.3";
      group = "org.typelevel";
      artifact = "kind-projector_${scalaVersion}";
      src = srcs.kindProjector;
      sourceDirs = [
        "src/main/scala"
        "src/main/scala-newParser"
        "src/main/scala-newReporting"
      ];
      resourceDirs = [ "src/main/resources" ];
      buildDeps = [ self.scala-compiler ];
    };

    # --- Java libraries -----------------------------------------------------------------
    launcher-interface = mkLib {
      pname = "launcher-interface";
      version = "1.4.4";
      group = "org.scala-sbt";
      src = srcs.launcher;
      scala = false;
      sourceDirs = [ "launcher-interface/src/main/java" ];
    };

    util-interface = mkLib {
      pname = "util-interface";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      scala = false;
      sourceDirs = [ "internal/util-interface/src/main/java" ];
    };

    compiler-interface = mkLib {
      pname = "compiler-interface";
      version = zincVersion;
      group = "org.scala-sbt";
      src = srcs.zinc;
      scala = false;
      sourceDirs = [
        "internal/compiler-interface/src/main/java"
        "internal/compiler-interface/src/main/contraband-java"
      ];
      deps = [ self.util-interface ];
      # ZincBuildUtil.generateVersionFile (its timestamp: the release's)
      postBuild = ''
        printf 'version=${zincVersion}\ntimestamp=20251214T000000' > .b/classes/incrementalcompiler.version.properties
      '';
    };

    zero-allocation-hashing = mkLib {
      pname = "zero-allocation-hashing";
      version = "0.16";
      group = "net.openhft";
      src = srcs.zeroAllocationHashing;
      scala = false;
      sourceDirs = [ "src/main/java" ];
      buildDeps = [
        jsr305
        jetbrainsAnnotations
      ];
      # Java 8 bytecode that calls Java 9+ methods where present (upstream compiles against
      # stubs of them, src/main/java-stub): compile against the JDK's own classes instead
      useRelease = false;
    };

    file-tree-views = mkLib {
      pname = "file-tree-views";
      version = "2.1.12";
      group = "com.swoval";
      src = srcs.swoval;
      scala = false;
      sourceDirs = [ "files/jvm/src/main/java" ];
    };

    disruptor = mkLib {
      pname = "disruptor";
      version = "3.4.2";
      group = "com.lmax";
      src = srcs.disruptor;
      scala = false;
      sourceDirs = [ "src/main/java" ];
      useRelease = false; # sun.misc.Unsafe
    };

    log4j-api = mkLib {
      pname = "log4j-api";
      version = "2.17.1";
      group = "org.apache.logging.log4j";
      src = srcs.log4j;
      scala = false;
      sourceDirs = [ "log4j-api/src/main/java" ];
      resourceDirs = [ "log4j-api/src/main/resources" ];
      dropSources = "^import org\\.osgi\\.";
    };

    # log4j-core without its optional integrations; its plugin processor writes the plugin
    # index (Log4j2Plugins.dat) in a second javac pass
    log4j-core = mkLib {
      pname = "log4j-core";
      version = "2.17.1";
      group = "org.apache.logging.log4j";
      src = srcs.log4j;
      scala = false;
      sourceDirs = [ "log4j-core/src/main/java" ];
      resourceDirs = [ "log4j-core/src/main/resources" ];
      deps = [ self.log4j-api ];
      buildDeps = [
        self.disruptor
        jansi
      ]
      ++ log4jOptional;
      dropSources = "^import (static )?(org\\.osgi|javax\\.mail|javax\\.jms|javax\\.activation|org\\.zeromq|com\\.conversantmedia|com\\.fasterxml\\.jackson\\.dataformat|org\\.codehaus|org\\.apache\\.kafka|org\\.apache\\.commons\\.csv|javax\\.persistence|org\\.apache\\.cassandra)";
      # ResolverUtil scans OSGi bundles (bundleresource: URLs, only inside an OSGi framework)
      preBuild = edit [
        [
          "log4j-core/src/main/java/org/apache/logging/log4j/core/config/plugins/util/ResolverUtil.java"
          "^import org\\.osgi\\.framework\\.(FrameworkUtil|wiring\\.BundleWiring);$"
          ""
        ]
        [
          "log4j-core/src/main/java/org/apache/logging/log4j/core/config/plugins/util/ResolverUtil.java"
          "final BundleWiring wiring = FrameworkUtil(.|\\n)*?addIfMatching\\(test, name\\);\\s*\\}"
          "throw new UnsupportedOperationException(\"OSGi bundles: log4j-core is built without OSGi\");"
        ]
      ];
      javacFlags = [ "-proc:none" ];
      postBuild = ''
        mkdir -p .b/proc-out
        javac -nowarn -encoding UTF-8 --release 8 -cp ".b/classes:$CP" -d .b/proc-out \
          -proc:only -processor org.apache.logging.log4j.core.config.plugins.processor.PluginProcessor \
          -processorpath ".b/classes:$CP" @.b/jsources
        cp -r .b/proc-out/META-INF .b/classes/
      '';
    };

    jline-native = mkLib {
      pname = "jline-native";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "native/src/main/java" ];
      resourceDirs = [ "native/src/main/resources" ];
    };
    jline-terminal = mkLib {
      pname = "jline-terminal";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "terminal/src/main/java" ];
      resourceDirs = [ "terminal/src/main/resources" ];
      deps = [ self.jline-native ];
    };
    jline-terminal-jni = mkLib {
      pname = "jline-terminal-jni";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "terminal-jni/src/main/java" ];
      resourceDirs = [ "terminal-jni/src/main/resources" ];
      deps = [
        self.jline-native
        self.jline-terminal
      ];
    };
    jline-reader = mkLib {
      pname = "jline-reader";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "reader/src/main/java" ];
      deps = [ self.jline-terminal ];
    };
    jline-style = mkLib {
      pname = "jline-style";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "style/src/main/java" ];
      deps = [ self.jline-terminal ];
      buildDeps = [ jsr305 ];
    };
    jline-builtins = mkLib {
      pname = "jline-builtins";
      version = "3.27.1";
      group = "org.jline";
      src = srcs.jline3;
      scala = false;
      sourceDirs = [ "builtins/src/main/java" ];
      resourceDirs = [ "builtins/src/main/resources" ];
      # Nano's charset detection uses the optional juniversalchardet (and ignores its
      # absence at runtime): without it, as when it is not on the classpath
      preBuild = edit [
        [
          "builtins/src/main/java/org/jline/builtins/Nano.java"
          "^import org\\.mozilla\\.universalchardet\\.UniversalDetector;$"
          ""
        ]
        [
          "builtins/src/main/java/org/jline/builtins/Nano.java"
          "UniversalDetector detector = new UniversalDetector\\(null\\);(.|\\n)*?charset = Charset\\.forName\\(detector\\.getDetectedCharset\\(\\)\\);\\s*\\}"
          "// (juniversalchardet not built)"
        ]
      ];
      deps = [
        self.jline-reader
        self.jline-style
      ];
    };
    # sbt's fork of jline 2
    jline2 = mkLib {
      pname = "jline";
      version = "2.14.7-sbt-9a88bc413e2b34a4580c001c654d1a7f4f65bf18";
      group = "org.scala-sbt.jline";
      src = srcs.jline2;
      scala = false;
      sourceDirs = [ "src/main/java" ];
      resourceDirs = [ "src/main/resources" ];
      deps = [ jansiM ];
    };

    # Zinc's persistence schema (protobuf), with the protobuf runtime, shaded into
    # sbt.internal.shaded.com.google.protobuf as zinc's assembly does
    zinc-persist-core-assembly = mkLib {
      pname = "zinc-persist-core-assembly";
      version = zincVersion;
      group = "org.scala-sbt";
      src = srcs.zinc;
      scala = false;
      sourceDirs = [ "gen" ];
      useRelease = false; # sun.misc.Unsafe
      preBuild = ''
        mkdir gen
        pb=${srcs.protobuf}
        cp -r $pb/java/core/src/main/java/. gen/
        chmod -R u+w gen
        ${protobuf_25}/bin/protoc --java_out=gen --proto_path=$pb/src \
          ${
            lib.concatMapStringsSep " " (p: "$pb/src/google/protobuf/${p}.proto") [
              "any"
              "api"
              "descriptor"
              "duration"
              "empty"
              "field_mask"
              "source_context"
              "struct"
              "timestamp"
              "type"
              "wrappers"
              "compiler/plugin"
            ]
          }
        ${protobuf_25}/bin/protoc --java_out=gen --proto_path=$pb/src --proto_path=$pb/java/core/src/main/java \
          $pb/java/core/src/main/java/com/google/protobuf/java_features.proto
        ${protobuf_25}/bin/protoc --java_out=gen --proto_path=internal/zinc-persist-core/src/main/protobuf \
          internal/zinc-persist-core/src/main/protobuf/*.proto
        find gen -name '*.proto' -delete
        chmod -R u+w gen
        python3 - <<'EOF'
        import os, re
        pat = re.compile(r"(?<![\w.])com\.google\.protobuf(?=[.;\s])")
        for d, _, fs in os.walk("gen"):
            for f in fs:
                p = os.path.join(d, f)
                s = open(p, encoding="utf-8").read()
                t = pat.sub("sbt.internal.shaded.com.google.protobuf", s)
                if t != s:
                    open(p, "w", encoding="utf-8").write(t)
        EOF
      '';
    };

    # --- Scala libraries ----------------------------------------------------------------
    scala-xml = mkLib {
      pname = "scala-xml";
      version = "2.3.0";
      group = "org.scala-lang.modules";
      src = srcs.scalaXml;
      sourceDirs = [
        "shared/src/main/scala"
        "shared/src/main/scala-2"
        "shared/src/main/scala-2.13+"
      ];
    };
    scala-parallel-collections = mkLib {
      pname = "scala-parallel-collections";
      version = "0.2.0";
      group = "org.scala-lang.modules";
      src = srcs.parallelCollections;
      sourceDirs = [ "core/src/main/scala" ];
      # (written against 2.13.0; IterableOnce.knownSize and Growable.knownSize became
      # concrete since: the overrides of 1.0.0)
      preBuild = ''
        python3 - <<'EOF'
        import os, re
        root = "core/src/main/scala/scala/collection/parallel"
        for d, _, fs in os.walk(root):
            for f in fs:
                p = os.path.join(d, f)
                s = open(p, encoding="utf-8").read()
                t = re.sub(r"(?m)^(\s*(?:@inline\s+)?(?:final\s+)?)def knownSize\b", r"\1override def knownSize", s)
                if p.endswith(tuple("/parallel/mutable/" + n + ".scala"
                                    for n in ("ParMap", "ParMapLike", "ParSet", "ParSetLike"))):
                    name = os.path.basename(p)[:-6]
                    m = re.search(r"(?ms)^trait " + name + r"\b.*?\{\n(\s*\w+(\s*:[^\n]*)?\s*=>\s*\n)?", t)
                    assert m, p
                    t = t[:m.end()] + "  override def knownSize: Int = -1\n" + t[m.end():]
                if t != s:
                    os.chmod(p, 0o644)
                    open(p, "w", encoding="utf-8").write(t)
        EOF
      '';
    };
    scala-parser-combinators = mkLib {
      pname = "scala-parser-combinators";
      version = "1.1.2";
      group = "org.scala-lang.modules";
      src = srcs.parserCombinators;
      sourceDirs = [
        "shared/src/main/scala"
        "shared/src/main/scala-2.13"
        "jvm/src/main/scala"
      ];
      # (written against 2.13.0, whose Predef converted Array[Char] and IndexedSeq[Char] to
      # CharSequence implicitly; 2.13.18's ArrayCharSequence/SeqCharSequence are explicit)
      preBuild = edit [
        [
          "shared/src/main/scala/scala/util/parsing/input/CharArrayReader.scala"
          "extends CharSequenceReader\\(chars, index\\)"
          "extends CharSequenceReader(ArrayCharSequence(chars), index)"
        ]
        [
          "shared/src/main/scala/scala/util/parsing/input/PagedSeqReader.scala"
          "java.lang.CharSequence = seq$"
          "java.lang.CharSequence = SeqCharSequence(seq)"
        ]
      ];
    };
    shaded-scalajson = mkLib {
      pname = "shaded-scalajson";
      version = "1.0.0-M4";
      group = "com.eed3si9n";
      src = srcs.scalajson;
      sourceDirs = [
        "shared/src/main/scala"
        "jvm/src/main/scala"
      ];
      preBuild = shadeScala "scalajson" "sjsonnew.shaded.scalajson";
    };
    shaded-jawn-parser = mkLib {
      pname = "shaded-jawn-parser";
      version = "1.3.2";
      group = "com.eed3si9n";
      src = srcs.jawn;
      sourceDirs = [
        "parser/shared/src/main/scala"
        "parser/jvm/src/main/scala"
      ];
      preBuild = shadeScala "org.typelevel.jawn" "sjsonnew.shaded.org.typelevel.jawn";
    };
    sjson-new-core = mkLib {
      pname = "sjson-new-core";
      version = "0.10.1";
      group = "com.eed3si9n";
      src = srcs.sjsonnew;
      sourceDirs = [
        "core/src/main/scala"
        "gen"
      ];
      # sbt-boilerplate's templates (TupleFormats, CaseClassFormats, ...)
      preBuild = ''
        mkdir gen
        for f in core/src/main/boilerplate/sjsonnew/*.template; do
          python3 ${./boilerplate.py} $f > gen/$(basename $f .template)
        done
      '';
    };
    sjson-new-scalajson = mkLib {
      pname = "sjson-new-scalajson";
      version = "0.10.1";
      group = "com.eed3si9n";
      src = srcs.sjsonnew;
      sourceDirs = [ "support/scalajson/src/main/scala" ];
      deps = [
        self.sjson-new-core
        self.shaded-scalajson
        self.shaded-jawn-parser
      ];
    };
    sbinary = mkLib {
      pname = "sbinary";
      version = "0.5.1";
      group = "org.scala-sbt";
      src = srcs.sbinary;
      sourceDirs = [
        "core/src/main/scala"
        "core/src/main/scala-2.13+"
        "gen"
      ];
      deps = [ self.scala-xml ];
      preBuild = ''
        mkdir gen
        for f in core/src/main/fmpp/*.scala; do
          python3 ${./fmpp-lite.py} $f > gen/$(basename $f)
        done
      '';
    };

    io = mkLib {
      pname = "io";
      version = "1.10.5";
      group = "org.scala-sbt";
      src = srcs.io;
      sourceDirs = [
        "io/src/main/scala"
        "io/src/main/contraband-scala"
      ];
      deps = [ self.file-tree-views ];
    };

    util-control = mkLib {
      plugins = [ self.kind-projector ];
      pname = "util-control";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [ "internal/util-control/src/main/scala" ];
    };
    util-relation = mkLib {
      plugins = [ self.kind-projector ];
      pname = "util-relation";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [ "internal/util-relation/src/main/scala" ];
    };
    util-position = mkLib {
      plugins = [ self.kind-projector ];
      pname = "util-position";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [
        "internal/util-position/src/main/scala"
        "internal/util-position/src/main/scala-2"
      ];
      deps = [ self.scala-reflect ];
    };
    collections = mkLib {
      plugins = [ self.kind-projector ];
      useRelease = false; # sun.misc.Signal
      # project/Util.scala's ScalaKeywords: the compiler's nme.keywords
      preBuild = ''
        mkdir -p gen/sbt/internal/util kw
        echo 'object Kw { def main(a: Array[String]): Unit = { val g = new scala.tools.nsc.Global(new scala.tools.nsc.Settings); println(g.nme.keywords.map(_.toString).toList.sorted.map("\"" + _ + "\"").mkString("Set(", ", ", ")")) } }' > kw/Kw.scala
        ${scalac} -nowarn -classpath ${scalaCp} -d kw kw/Kw.scala
        printf 'package sbt.internal.util\nobject ScalaKeywords {\n  val values = %s\n}\n' \
          "$(${jdk}/bin/java -cp ${scalaCp}:kw Kw)" > gen/sbt/internal/util/ScalaKeywords.scala
        cat gen/sbt/internal/util/ScalaKeywords.scala
      '';
      pname = "collections";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [
        "internal/util-collection/src/main/scala"
        "internal/util-collection/src/main/scala-2.13"
        "gen"
      ];
      deps = [
        self.util-position
        self.sjson-new-scalajson
        self.scala-parallel-collections
      ];
    };
    core-macros = mkLib {
      plugins = [ self.kind-projector ];
      pname = "core-macros";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [ "core-macros/src/main/scala" ];
      deps = [
        self.scala-compiler
        self.collections
      ];
    };
    util-logging = mkLib {
      plugins = [ self.kind-projector ];
      pname = "util-logging";
      version = sbtUtil;
      group = "org.scala-sbt";
      src = srcs.sbt;
      sourceDirs = [
        "internal/util-logging/src/main/scala"
        "internal/util-logging/src/main/contraband-scala"
        "internal/util-logging/src/main/java"
      ];
      deps = [
        self.util-interface
        self.collections
        self.core-macros
        self.sjson-new-core
        self.jline2
        self.jline-terminal
        self.jline-terminal-jni
        self.jline-native
        self.log4j-api
        self.log4j-core
        self.disruptor
        self.sjson-new-scalajson
        self.scala-reflect
        self.io
      ];
    };

    # --- Zinc -----------------------------------------------------------------------------
    # the bridge for Scala 2.13: compiled (zinc-apiinfo builds on it) and as the sources jar
    # Gradle hands to Zinc, which compiles it for the Scala version of a build
    compiler-bridge = mkLib {
      pname = "compiler-bridge";
      version = zincVersion;
      group = "org.scala-sbt";
      src = srcs.zinc;
      sourceDirs = [
        "internal/compiler-bridge/src/main/scala"
        "internal/compiler-bridge/src/main/scala_2.13"
      ];
      resourceDirs = [ "internal/compiler-bridge/src/main/resources" ];
      deps = [ self.compiler-interface ];
      buildDeps = [ self.scala-compiler ];
      postBuild = ''
        mkdir -p .b/sources-jar
        for d in internal/compiler-bridge/src/main/scala internal/compiler-bridge/src/main/scala_2.13 \
                 internal/compiler-bridge/src/main/resources; do
          cp -r $d/. .b/sources-jar/
        done
      '';
      # (not in share/java: scalac would read the sources of a classpath entry)
      passthru.sourcesJar = "share/sources/compiler-bridge-sources.jar";
      postInstall = ''
        mkdir -p $out/share/sources
        jar cf $out/share/sources/compiler-bridge-sources.jar -C .b/sources-jar .
      '';
    };

    zinc-classfile = zincMod "zinc-classfile" [
      "internal/zinc-classfile/src/main/scala"
      "internal/zinc-classfile/src/main/java"
    ] [ self.compiler-interface self.io self.util-logging ];
    zinc-classpath = zincMod "zinc-classpath" [ "internal/zinc-classpath/src/main/scala" ] [
      self.scala-compiler
      self.compiler-interface
      self.launcher-interface
      self.io
    ];
    zinc-apiinfo = zincMod "zinc-apiinfo" [ "internal/zinc-apiinfo/src/main/scala" ] [
      self.compiler-interface
      self.compiler-bridge
      self.zinc-classfile
    ];
    zinc-compile-core =
      zincMod "zinc-compile-core"
        [
          "internal/zinc-compile-core/src/main/scala"
          "internal/zinc-compile-core/src/main/java"
          "internal/zinc-compile-core/src/main/contraband-java"
        ]
        [
          self.compiler-interface
          self.zinc-classpath
          self.zinc-apiinfo
          self.zinc-classfile
          self.launcher-interface
          self.scala-parser-combinators
          self.zero-allocation-hashing
          self.util-logging
          self.io
          self.util-control
        ];
    zinc-core =
      zincMod "zinc-core"
        [
          "internal/zinc-core/src/main/scala"
          "internal/zinc-core/src/main/scala-2.13"
          "internal/zinc-core/src/main/java"
        ]
        [
          self.zinc-compile-core
          self.zinc-apiinfo
          self.zinc-classpath
          self.compiler-interface
          self.zinc-persist-core-assembly
          self.scala-parallel-collections
          self.io
          self.util-logging
          self.util-relation
        ];
    zinc-persist =
      zincMod "zinc-persist"
        [
          "internal/zinc-persist/src/main/scala"
          "internal/zinc-persist/src/main/scala-2.13"
          "internal/zinc-persist/src/main/java"
        ]
        [
          self.zinc-core
          self.zinc-compile-core
          self.zinc-persist-core-assembly
          self.sbinary
          self.scala-xml
        ];
    zinc =
      zincMod "zinc"
        [
          "zinc/src/main/scala"
          "zinc/src/main/java"
        ]
        [
          self.zinc-core
          self.zinc-persist
          self.zinc-compile-core
          self.zinc-classfile
        ];
  };
  # --- a Maven repository of the jars above, for Gradle's `scala` plugin ------------------
  # It resolves scala-library, scala-compiler (+ scala-reflect), compiler-bridge_2.13:sources,
  # compiler-interface and zinc_2.13; the POMs are written from the dependencies declared here.
  mavenRepo =
    let
      roots = with self; [
        scala-library
        scala-reflect
        scala-compiler
        compiler-interface
        compiler-bridge
        zinc
      ];
      all = builtins.genericClosure {
        startSet = map (d: {
          key = d.outPath;
          drv = d;
        }) roots;
        operator =
          n:
          map (d: {
            key = d.outPath;
            drv = d;
          }) n.drv.maven.deps;
      };
      entry = n: {
        inherit (n.drv.maven) group artifact version;
        jar = "${n.drv}/share/java/${n.drv.pname}.jar";
        sources =
          if n.drv ? sourcesJar then "${n.drv}/${n.drv.sourcesJar}" else null;
        deps = map (d: { inherit (d.maven) group artifact version; }) n.drv.maven.deps;
      };
      index = writeText "scala-maven-repo.json" (builtins.toJSON (map entry all));
    in
    runCommand "scala-${scalaVersion}-zinc-${zincVersion}-maven-repo" { nativeBuildInputs = [ python3 ]; } ''
      python3 ${./maven-repo.py} ${index} $out
    '';
in
self // { inherit mavenRepo; }
