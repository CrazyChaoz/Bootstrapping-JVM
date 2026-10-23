# Gradle's own modules (platforms/* and subprojects/*), compiled directly with
# javac / kotlinc instead of Gradle.  The module graph (nix/gradle/modules.json)
# is extracted from the build scripts by tools/gradle-modules.
{
  lib,
  stdenv,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  writeShellScript,
  runCommand,
  classpathOf,
  closureOf,
  gradleSrc,
  gradleLibs,
  gradleGroovy,
  kotlinCompiler, # a built Kotlin distribution (lib/kotlin-compiler.jar, ...)
  extraLibs ? { },
}:

let
  modules = builtins.fromJSON (builtins.readFile ./modules.json);

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
      tomlj = tomlj;
      antlr = antlr2;
      jsch = jsch;
      plexusClassworlds = plexus-classworlds;
      maven3Artifact = maven-artifact;
      maven3PluginApi = maven-plugin-api;
      mavenResolverApi = maven-resolver-api;
    }
    // (with gradleGroovy; {
      groovy = groovy-core;
      groovyAnt = groovy-ant;
      groovyAstbuilder = groovy-astbuilder;
      groovyDateUtil = groovy-dateutil;
      groovyDatetime = groovy-datetime;
      groovyDoc = groovy-groovydoc;
      groovyJson = groovy-json;
      groovyNio = groovy-nio;
      groovyTemplates = groovy-templates;
      groovyXml = groovy-xml;
    })
    // extraLibs;

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
      -cp $k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
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

  self = lib.mapAttrs (n: _: mkModule n) modules;

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
      ];
      projects = map (d: self.${lib.removePrefix "project:" d}) (
        lib.filter (d: lib.hasPrefix "project:" d) ds
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
      useRelease = !(m.main.usesJdkInternals or false) && !(m.main.usesFutureStdlib or false);
      processors = lib.filter (d: d == "project:internal-instrumentation-processor") (
        depsOf n [ "annotationProcessor" ]
      );
      hasKotlin = hasDir n "src/main/kotlin";
      hasJava = hasDir n "src/main/java";
      hasResources = hasDir n "src/main/resources";
      kotlinStdlib = "${kotlinCompiler}/lib/kotlin-stdlib.jar";
    in
    stdenv.mkDerivation {
      pname = "gradle-${n}";
      version = "9.8.0";
      src = gradleSrc;
      nativeBuildInputs = [
        jdk
        zip
        unzip
        stripJavaArchivesHook
      ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        d=${dirOf n}
        export CLASSPATH="${classpathOf deps}${lib.optionalString hasKotlin kotlinStdlib}"
        mkdir -p build/classes
        ${lib.optionalString hasKotlin ''
          find $d/src/main/kotlin ${lib.optionalString hasJava "$d/src/main/java"} \( -name '*.kt' -o -name '*.java' \) > build/ksources
          ${kotlinRun} -no-stdlib -no-reflect -nowarn \
            -language-version 2.2 -api-version 2.2 -jvm-target ${if release < 9 then "1.${toString release}" else toString release} \
            -Xjsr305=strict -Xjspecify-annotations=strict -java-parameters -Xsam-conversions=class \
            -opt-in=kotlin.contracts.ExperimentalContracts \
            -module-name gradle-${n} -cp "$CLASSPATH" -d build/classes @build/ksources
          export CLASSPATH="build/classes:$CLASSPATH"
        ''}
        ${lib.optionalString hasJava ''
          find $d/src/main/java -name '*.java' > build/jsources
          if [ -s build/jsources ]; then
            javac -d build/classes -encoding utf-8 -parameters -nowarn -Xlint:-options -Xlint:-path \
              ${if useRelease then "--release ${toString release}" else "-source ${toString release} -target ${toString release}"} \
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
