# Gradle's own modules (platforms/* and subprojects/*), compiled directly with
# javac / kotlinc instead of Gradle.  The module graph (nix/gradle/modules.json)
# is extracted from the build scripts by tools/gradle-modules.
{
  lib,
  stdenv,
  jdk,
  zip,
  python3,
  unzip,
  stripJavaArchivesHook,
  writeShellScript,
  runCommand,
  classpathOf,
  closureOf,
  gradleSrc,
  gradleLibs,
  gradleGroovy,
  kotlinPlugins,
  kotlinAsm,
  kotlinCompiler, # a built Kotlin distribution (lib/kotlin-compiler.jar, ...)
  extraLibs ? { },
  gradleVersion ? "9.8.0",
  modulesJson ? ./modules.json,
  embeddedKotlin ? "2.4.0",
  kotlinDslPlugins ? "6.7.6",
  extraNotBuilt ? [ ],
  libOverrides ? { },
  patches ? { },
  extraKotlinArgs ? [ ],
  jdkInternalsModules ? [ ], # modules using com.sun.tools.javac (not flagged in the 8.x build scripts) # module name -> shell snippet run in the source tree before compiling
}:

let
  modules = builtins.fromJSON (builtins.readFile modulesJson);

  # `libs.<alias>` of the version catalogs -> derivations.
  libMap =
    with gradleLibs;
    {
      ant = ant;
      asm = asm;
      asmCommons = asm-commons;
      asmTree = asm-tree;
      bouncycastlePgp = bcpg;
      bouncycastleProvider = bcprov;
      commonsCodec = commons-codec;
      commonsCompress = commons-compress;
      commonsHttpclient = httpclient;
      commonsIo = commons-io;
      commonsLang = commons-lang3;
      commonsLang3 = commons-lang3;
      errorProneAnnotations = error-prone-annotations;
      gradleFileEvents = gradle-fileevents;
      gson = gson;
      guava = guava;
      httpcore = httpcore;
      inject = javax-inject;
      ivy = ivy;
      jacksonAnnotations = jackson-annotations;
      jacksonCore = jackson-core;
      jacksonDatabind = jackson-databind;
      jacksonDatatypeJdk8 = jackson-datatype-jdk8;
      jacksonDatatypeJsr310 = jackson-datatype-jsr310;
      jansi = jansi;
      jsoup = jsoup;
      jatl = jatl;
      javaPoet = javapoet;
      jcifs = jcifs;
      jclToSlf4j = jcl-over-slf4j;
      jctools = jctools-core;
      jetbrainsAnnotations = jetbrains-annotations;
      jnrConstants = jnr-constants;
      jspecify = jspecify;
      jsr305 = jsr305;
      julToSlf4j = jul-to-slf4j;
      kryo = kryo;
      log4jToSlf4j = log4j-over-slf4j;
      maven3Model = maven-model;
      maven3RepositoryMetadata = maven-repository-metadata;
      maven3Settings = maven-settings;
      maven3SettingsBuilder = maven-settings-builder;
      nativePlatform = native-platform;
      plexusCipher = plexus-cipher;
      plexusSecDispatcher = plexus-sec-dispatcher;
      plexusUtils = plexus-utils;
      plist = dd-plist;
      slf4jApi = slf4j-api;
      snakeyaml = snakeyaml;
      junit = junit4;
      opentest4j = opentest4j;
      junitPlatform = junit-platform-launcher;
      junitPlatformEngine = junit-platform-engine;
      testng = testng;
      kotlinxSerializationCore = kotlinPlugins.kotlinx-serialization-core;
      kotlinxSerializationJson = kotlinPlugins.kotlinx-serialization-json;
      jgit = jgit;
      jgitSsh = jgit-ssh-apache;
      tomlj = tomlj;
      antlr = antlr2;
      jsch = jsch;
      plexusClassworlds = plexus-classworlds;
      maven3Artifact = maven-artifact;
      mavenResolverApi = maven-resolver-api;
    }
    // (with gradleGroovy; {
      groovy = groovy-core;
      groovyAnt = groovy-ant;
      groovyAstbuilder = groovy-astbuilder;
      groovyConsole = groovy-console;
      groovyDateUtil = groovy-dateutil;
      groovyDatetime = groovy-datetime;
      groovyDoc = groovy-groovydoc;
      groovyJson = groovy-json;
      groovyNio = groovy-nio;
      groovySql = groovy-sql;
      groovyTest = groovy-test;
      groovyTemplates = groovy-templates;
      groovyXml = groovy-xml;
    })
    // extraLibs
    // libOverrides;

  dirOf = n: modules.${n}.dir;
  depsOf =
    n: confs: lib.concatMap (c: modules.${n}.deps.${c} or [ ]) confs;

  hasDir = n: sub: builtins.pathExists "${gradleSrc}/${dirOf n}/${sub}";

  targetVersion =
    n:
    let
      m = modules.${n};
      rt = m.runtimes;
    in
    m.main.targetJvmVersion or (
      if rt == { } then
        17
      else
        lib.foldl' lib.min 99 (
          lib.optional (rt.client or false) 8
          ++ lib.optional (rt.worker or false) 8
          ++ lib.optional (rt.daemon or false) 17
        )
    );

  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx4g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';

  # a library that is not built (yet): fails when built, so that --keep-going builds the rest
  missing =
    d:
    runCommand "missing-${lib.removePrefix "lib:" d}" { nativeBuildInputs = [ jdk ]; } ''
      # an empty jar for now, so that the errors of the modules themselves show up
      mkdir -p $out/share/java x
      jar cf $out/share/java/missing-${lib.removePrefix "lib:" d}.jar -C x .
    '';

  # modules that do not build yet (missing third party libraries); the modules depending
  # on them are compiled without them (which fails for those really using their classes)
  notBuilt = [
    "resources-gcs"
    "resources-s3"
    "build-init"
  ] ++ extraNotBuilt;

  # sources and resources generated by Gradle's build logic
  generated = {
    kotlin-dsl = ''
      python3 ${./gen-kotlin-dependency-extensions.py} . build/gen-src ${embeddedKotlin} ${kotlinDslPlugins}
      echo 'kotlin=${embeddedKotlin}' > build/classes/gradle-kotlin-dsl-versions.properties
      printf 'org.jetbrains.kotlin\\:kotlin-reflect=${embeddedKotlin}\norg.jetbrains.kotlin\\:kotlin-stdlib=${embeddedKotlin}\norg.jetbrains\\:annotations=13.0\n' > build/classes/gradle-kotlin-dsl-embedded-kotlin.properties
    '';
  };

  # modules built without the sources needing libraries we cannot build (files importing these)
  partial = {
    # the Zinc based Scala compiler worker: the Scala compiler would need a binary seed
    scala-compiler-worker = "^import (sbt|xsbti|scala)\\.|xsbti\\.";
  }
  // lib.optionalAttrs (lib.hasPrefix "8." gradleVersion) {
    # (the 8.x Scala plugin uses the Zinc API directly)
    scala = "^import (sbt|xsbti|scala)\\.|xsbti\\.";
  };

  self = (lib.mapAttrs (n: _: mkModule n) modules) // { _libMap = libMap; };

  # Module and library dependencies of the compile classpath (compileOnly and
  # api/implementation alike; a superset is harmless for javac/kotlinc).
  compileDeps =
    n:
    let
      ds = depsOf n [
        "api"
        "implementation"
        "compileOnly"
        "compileOnlyApi"
        "shadow"
      ];
      projects = map (d: self.${lib.removePrefix "project:" d}) (
        lib.filter (d: lib.hasPrefix "project:" d && !(lib.elem (lib.removePrefix "project:" d) notBuilt)) ds
      );
      libs = map (d: libMap.${lib.removePrefix "lib:" d} or (missing d)) (
        lib.filter (d: lib.hasPrefix "lib:" d) ds
      );
    in
    projects ++ libs;

  mkModule =
    n:
    let
      m = modules.${n};
      deps = compileDeps n;
      release = targetVersion n;
      useRelease = !(m.main.usesJdkInternals or false) && !(m.main.usesFutureStdlib or false) && !(lib.elem n jdkInternalsModules);
      processors = lib.filter (d: d == "project:internal-instrumentation-processor") (
        depsOf n [ "annotationProcessor" ]
      );
      hasKotlin = hasDir n "src/main/kotlin";
      hasJava = hasDir n "src/main/java";
      hasResources = hasDir n "src/main/resources";
      kotlinStdlib = "${kotlinCompiler}/lib/kotlin-stdlib.jar";
      serialization = lib.elem "kotlin.plugin.serialization" m.plugins;
      samWithReceiver = lib.elem "gradlebuild.kotlin-dsl-sam-with-receiver" m.plugins;
    in
    stdenv.mkDerivation {
      pname = "gradle-${n}";
      version = gradleVersion;
      src = gradleSrc;
      nativeBuildInputs = [
        jdk
        zip
        unzip
        stripJavaArchivesHook
      ]
      ++ lib.optional (generated ? ${n}) python3;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        d=${dirOf n}
        export CLASSPATH="${classpathOf deps}${lib.optionalString hasKotlin kotlinStdlib}"
        mkdir -p build/classes${lib.optionalString (generated ? ${n}) "\nmkdir -p build/gen-src\n${generated.${n}}"}
        ${patches.${n} or ""}
        ${lib.optionalString (partial ? ${n}) "grep -rlE '${partial.${n}}' $d/src/main | xargs -r rm -v"}
        ${lib.optionalString (n == "scala-compiler-worker" || (n == "scala" && lib.hasPrefix "8." gradleVersion)) "sed -i 's|return ZincScalaCompilerFactory.getCompiler(.*|throw new UnsupportedOperationException(\"Scala compilation needs a Scala compiler (not bootstrapped yet)\");|' $d/src/main/java/org/gradle/api/internal/tasks/scala/ZincScalaCompilerFacade.java"}
        ${lib.optionalString hasKotlin ''
          find $d/src/main/kotlin${lib.optionalString (generated ? ${n}) " build/gen-src"} ${lib.optionalString hasJava "$d/src/main/java"} \( -name '*.kt' -o -name '*.java' \) > build/ksources
          ${kotlinRun} -no-stdlib -no-reflect -nowarn \
            -language-version 2.2 -api-version 2.2 -jvm-target ${if release < 9 then "1.${toString release}" else toString release} \
            -Xskip-prerelease-check -Xjsr305=strict -Xjspecify-annotations=strict -java-parameters -Xsam-conversions=class \
            -opt-in=kotlin.contracts.ExperimentalContracts ${lib.escapeShellArgs extraKotlinArgs} \
            ${lib.optionalString serialization "-Xplugin=${kotlinPlugins.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar"} \
            ${lib.optionalString samWithReceiver "-Xplugin=${kotlinPlugins.samWithReceiver}/share/java/kotlin-sam-with-receiver-compiler-plugin.jar -P plugin:org.jetbrains.kotlin.samWithReceiver:annotation=org.gradle.api.HasImplicitReceiver"} \
            -module-name gradle-${n} -cp "$CLASSPATH" -d build/classes @build/ksources
          export CLASSPATH="build/classes:$CLASSPATH"
        ''}
        ${lib.optionalString hasJava ''
          find $d/src/main/java -name '*.java' > build/jsources
          if [ -s build/jsources ]; then
            javac -d build/classes -encoding utf-8 -parameters -nowarn -Xlint:-options -Xlint:-path \
              ${if useRelease then "--release ${toString release}" else "-source ${toString release} -target ${toString release}"} \
              ${lib.optionalString (lib.elem n jdkInternalsModules) (lib.concatMapStringsSep " " (p: "--add-exports=jdk.compiler/com.sun.tools.javac.${p}=ALL-UNNAMED") [ "api" "util" "code" "comp" "file" "main" "model" "parser" "processing" "tree" ])} \
              ${lib.optionalString (processors != [ ]) "-Aorg.gradle.annotation.processing.instrumented.project=${n}"} \
              ${lib.optionalString (processors != [ ]) "-processorpath ${classpathOf [ self.internal-instrumentation-processor ]}${self.internal-instrumentation-processor}/share/java/gradle-internal-instrumentation-processor.jar"} \
              -cp "$CLASSPATH" @build/jsources
          fi
        ''}
        ${lib.optionalString hasResources ''
          cp -r $d/src/main/resources/. build/classes/
        ''}
        runHook postBuild
      '';
      installPhase = ''
        mkdir -p $out/share/java
        jar cf $out/share/java/gradle-${n}.jar -C build/classes .
      '';
      passthru.javaDeps = closureOf deps;
    };
in
self
