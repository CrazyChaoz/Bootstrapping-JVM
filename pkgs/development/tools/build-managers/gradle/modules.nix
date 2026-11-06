# Gradle's own modules (platforms/* and subprojects/*), compiled directly with
# javac / kotlinc instead of Gradle.  The module graph (modules/VERSION.json)
# is extracted from the build scripts by scripts/gradle-modules.
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
  modulesJson ? ./modules/${gradleVersion}.json,
  embeddedKotlin ? "2.4.0",
  kotlinDslPlugins ? "6.7.6",
  extraNotBuilt ? [ ],
  libOverrides ? { },
  patches ? { },
  extraKotlinArgs ? [ ],
  jdkInternalsModules ? [ ], # modules using com.sun.tools.javac (not flagged in the 8.x build scripts) # module name -> shell snippet run in the source tree before compiling
  # compile and package like Gradle's release build (javac -g, the jars of its Jar task:
  # gradle-jar.py), for comparing with the published distribution
  upstreamJars ? false,
  # the JVM kotlinc runs on (the bootstrapped compiler's IntelliJ core takes no Java feature
  # version past 24); `jdk` stays the JDK compiled against (-jdk-home)
  kotlinHostJdk ? jdk,
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

  # the class and resource directories of a module (in this order in the jar)
  kotlinOut = if upstreamJars then "build/kotlin" else "build/classes";
  resourcesOut = if upstreamJars then "build/resources" else "build/classes";
  debugFlag = lib.optionalString upstreamJars "-g ";
  # (and generated sources out of the classes; Gradle's naming of the Kotlin module)
  apFlags = lib.optionalString upstreamJars "-s build/generated ";
  # Gradle's order of a source tree (its file system snapshots: each directory's children sorted
  # by name, files and directories alike), in which javac and kotlinc get the files
  sortSources = lib.optionalString upstreamJars " | python3 -c 'import sys; print(*sorted(sys.stdin.read().split(), key=lambda p: p.split(\"/\")), sep=\"\\n\")'";
  kotlinModuleName = n: if upstreamJars then "org.gradle:${n}" else "gradle-${n}";
  depsOf = n: confs: lib.concatMap (c: modules.${n}.deps.${c} or [ ]) confs;

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
    exec ${kotlinHostJdk}/bin/java -Xmx4g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler ${lib.optionalString upstreamJars "-jdk-home ${jdk.home} "}"$@"
  '';

  # javac as Gradle runs it (Javac.java) in upstream mode
  javacRun =
    if upstreamJars then
      "${jdk}/bin/java -cp ${
        runCommand "gradle-javac" { nativeBuildInputs = [ jdk ]; } ''
          mkdir -p src $out/share/java
          cp ${./Javac.java} src/Javac.java
          javac -d $out/share/java src/Javac.java
        ''
      }/share/java Javac"
    else
      "javac";

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
  ]
  ++ extraNotBuilt;

  # sources and resources generated by Gradle's build logic
  generated = {
    kotlin-dsl = ''
      python3 ${./gen-kotlin-dependency-extensions.py} . build/gen-src ${embeddedKotlin} ${kotlinDslPlugins}
      echo 'kotlin=${embeddedKotlin}' > ${resourcesOut}/gradle-kotlin-dsl-versions.properties
      printf 'org.jetbrains.kotlin\\:kotlin-reflect=${embeddedKotlin}\norg.jetbrains.kotlin\\:kotlin-stdlib=${embeddedKotlin}\norg.jetbrains\\:annotations=13.0\n' > ${resourcesOut}/gradle-kotlin-dsl-embedded-kotlin.properties
    '';
  };

  self = (lib.mapAttrs (n: _: mkModule n) modules) // {
    _libMap = libMap;
  };

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
        lib.filter (
          d: lib.hasPrefix "project:" d && !(lib.elem (lib.removePrefix "project:" d) notBuilt)
        ) ds
      );
      libs = map (d: libMap.${lib.removePrefix "lib:" d} or (missing d)) (
        lib.filter (d: lib.hasPrefix "lib:" d) ds
      );
    in
    projects ++ libs;

  # Gradle's compile classpath of a module (java-library): its own dependencies, of project
  # dependencies only what they export (api, compileOnlyApi; transitively), of libraries their
  # closure; in the order found.  (What else the runtime closure has can change the compilation:
  # e.g. a @NullMarked package-info of a split package from an implementation dependency.)
  gradleClasspathOf =
    n:
    let
      node =
        d:
        if lib.hasPrefix "project:" d then
          let
            p = lib.removePrefix "project:" d;
          in
          {
            key = d;
            drv = self.${p};
            next = lib.filter (e: !(lib.elem (lib.removePrefix "project:" e) notBuilt)) (
              depsOf p [
                "api"
                "compileOnlyApi"
              ]
            );
          }
        else
          let
            l = libMap.${lib.removePrefix "lib:" d} or (missing d);
          in
          {
            key = d;
            drv = l;
            next = map (x: "drv:${x}") (closureOf [ l ]);
          };
      nodeOf =
        d:
        if lib.hasPrefix "drv:" d then
          {
            key = d;
            drv = lib.removePrefix "drv:" d;
            next = [ ];
          }
        else
          node d;
      direct = lib.filter (
        d: !(lib.hasPrefix "project:" d && lib.elem (lib.removePrefix "project:" d) notBuilt)
      ) (
        depsOf n [
          "api"
          "implementation"
          "shadedImplementation"
          "compileOnly"
          "compileOnlyApi"
          "shadow"
        ]
      );
      all = builtins.genericClosure {
        startSet = map nodeOf direct;
        operator = x: map nodeOf x.next;
      };
      # (a library's closure is keyed by store path, so a jar reached both ways appears once)
      paths = lib.unique (map (x: toString x.drv) all);
    in
    if paths == [ ] then
      ""
    else
      "$(for d in ${lib.concatStringsSep " " paths}; do for j in $d/share/java/*.jar; do [ -e \"$j\" ] && printf '%s:' \"$j\"; done; done)";

  mkModule =
    n:
    let
      m = modules.${n};
      deps = compileDeps n;
      release = targetVersion n;
      useRelease =
        !(m.main.usesJdkInternals or false)
        && !(m.main.usesFutureStdlib or false)
        && !(lib.elem n jdkInternalsModules);
      processors = lib.filter (d: d == "project:internal-instrumentation-processor") (
        depsOf n [ "annotationProcessor" ]
      );
      hasKotlin = hasDir n "src/main/kotlin";
      hasJava = hasDir n "src/main/java";
      hasResources = hasDir n "src/main/resources";
      kotlinStdlib = "${kotlinCompiler}/lib/kotlin-stdlib.jar";
      serialization = lib.elem "kotlin.plugin.serialization" m.plugins;
      samWithReceiver = lib.elem "gradlebuild.kotlin-dsl-sam-with-receiver" m.plugins;
      # src/main/java<N>: classes for Java N+, into the jar's META-INF/versions/N (9.9's
      # addMultiReleaseVersion)
      multiRelease = map (lib.removePrefix "java") (
        lib.filter (k: builtins.match "java[0-9]+" k != null) (lib.attrNames (m.src or { }))
      );
    in
    stdenv.mkDerivation {
      pname = "gradle-${n}";
      version = gradleVersion;
      src = gradleSrc;
      nativeBuildInputs = [
        jdk
        zip
        unzip
      ]
      ++ lib.optional (!upstreamJars) stripJavaArchivesHook
      ++ lib.optional (generated ? ${n} || upstreamJars) python3;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        d=${dirOf n}
        export CLASSPATH="${if upstreamJars then gradleClasspathOf n else classpathOf deps}${lib.optionalString hasKotlin kotlinStdlib}"
        mkdir -p build/classes${lib.optionalString upstreamJars " ${kotlinOut} ${resourcesOut} build/generated"}${
          lib.optionalString (generated ? ${n}) "\nmkdir -p build/gen-src\n${generated.${n}}"
        }
        ${patches.${n} or ""}


        ${lib.optionalString hasKotlin ''
          find $d/src/main/kotlin${
            lib.optionalString (generated ? ${n}) " build/gen-src"
          } ${lib.optionalString hasJava "$d/src/main/java"} \( -name '*.kt' -o -name '*.java' \)${sortSources} > build/ksources
          ${kotlinRun} -no-stdlib -no-reflect -nowarn \
            ${
              # (build-logic's modules: gradlebuild.kotlin-shared-runtime sets only the JVM target,
              # not configureKotlinCompilerForGradleBuild's options)
              lib.optionalString (!(upstreamJars && lib.hasPrefix "build-logic/" m.dir)) "-language-version 2.2 -api-version 2.2 "
            }-jvm-target ${
              if release < 9 then "1.${toString release}" else toString release
            } \
            -Xskip-prerelease-check ${
              lib.optionalString (!(upstreamJars && lib.hasPrefix "build-logic/" m.dir)) "-Xjsr305=strict -Xjspecify-annotations=strict -java-parameters -Xsam-conversions=class "
            }\
            -opt-in=kotlin.contracts.ExperimentalContracts ${lib.escapeShellArgs extraKotlinArgs}${
              lib.optionalString (upstreamJars && useRelease) " -Xjdk-release=${if release < 9 then "1.${toString release}" else toString release}"
            } \
            ${lib.optionalString serialization "-Xplugin=${kotlinPlugins.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar"} \
            ${lib.optionalString samWithReceiver "-Xplugin=${kotlinPlugins.samWithReceiver}/share/java/kotlin-sam-with-receiver-compiler-plugin.jar -P plugin:org.jetbrains.kotlin.samWithReceiver:annotation=org.gradle.api.HasImplicitReceiver"} \
            -module-name ${kotlinModuleName n} -cp "$CLASSPATH" -d ${kotlinOut} @build/ksources
          export CLASSPATH="${kotlinOut}:$CLASSPATH"
        ''}
        ${lib.optionalString hasJava ''
          find $d/src/main/java -name '*.java'${sortSources} > build/jsources
          if [ -s build/jsources ]; then
            ${javacRun} -d build/classes -encoding utf-8 ${debugFlag}${apFlags}-parameters -nowarn -Xlint:-options -Xlint:-path \
              ${
                if useRelease then
                  "--release ${toString release}"
                else
                  "-source ${toString release} -target ${toString release}"
              } \
              ${
                lib.optionalString (lib.elem n jdkInternalsModules) (
                  lib.concatMapStringsSep " " (p: "--add-exports=jdk.compiler/com.sun.tools.javac.${p}=ALL-UNNAMED") [
                    "api"
                    "util"
                    "code"
                    "comp"
                    "file"
                    "main"
                    "model"
                    "parser"
                    "processing"
                    "tree"
                  ]
                )
              } \
              ${
                lib.optionalString (
                  processors != [ ]
                ) "-Aorg.gradle.annotation.processing.instrumented.project=${n}"
              } \
              ${
                lib.optionalString (processors != [ ])
                  "-processorpath ${
                    classpathOf [ self.internal-instrumentation-processor ]
                  }${self.internal-instrumentation-processor}/share/java/gradle-internal-instrumentation-processor.jar"
              } \
              -cp "$CLASSPATH" @build/jsources
          fi
        ''}
        ${lib.concatMapStrings (v: ''
          mkdir -p build/versions/${v}
          find $d/src/main/java${v} -name '*.java' > build/jsources${v}
          javac -d build/versions/${v} -encoding utf-8 ${debugFlag}-parameters -nowarn -Xlint:-options --release ${v} \
            -cp "build/classes:$CLASSPATH" @build/jsources${v}
        '') multiRelease}${lib.optionalString hasResources ''
          cp -r $d/src/main/resources/. ${resourcesOut}/
        ''}
        runHook postBuild
      '';
      installPhase =
        if upstreamJars then
          assert multiRelease == [ ];
          ''
            mkdir -p $out/share/java pom
            printf '#Generated by gradle-pom-properties\ngroupId=org.gradle\nartifactId=gradle-${n}\nversion=${gradleVersion}\n' > pom/pom.properties
            python3 ${./gradle-jar.py} $out/share/java/gradle-${n}.jar \
              --attr 'Implementation-Title: Gradle' --attr 'Implementation-Version: ${gradleVersion}' \
              --attr 'Implementation-Vendor: Gradle, Inc.' --attr 'Implementation-Vendor-Id: org.gradle' \
              --root build/classes --root ${kotlinOut} --root ${resourcesOut} \
              --append META-INF/maven/org.gradle/gradle-${n}/pom.properties=pom/pom.properties
          ''
        else
          ''
            mkdir -p $out/share/java
            jar cf $out/share/java/gradle-${n}.jar -C build/classes .${
              lib.concatMapStrings (v: " --release ${v} -C build/versions/${v} .") multiRelease
            }
          '';
      passthru.javaDeps = closureOf deps;
    };
in
self
