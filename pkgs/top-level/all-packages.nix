{ pkgs }:

let
  inherit (pkgs) lib;
in
pkgs.lib.makeScope pkgs.newScope (self: {
  # The JDK used by all stages: the JDK chain of pkgs/development/compilers/openjdk, bootstrapped from
  # jikes/classpath/jamvm without any binary seed.
  jdk8 = self.jdks.openjdk8;
  jdk = self.jdk8;

  # Helpers
  javaLib = self.callPackage ../build-support/java/mk-jar.nix { };
  regexEdit = self.callPackage ../build-support/regex-edit { };
  inherit (self.javaLib) mkJar classpathOf;

  fetchIntellij = self.callPackage ../build-support/fetchintellij { };
  intellijSources = self.callPackage ../development/java-modules/intellij-sdk/sources.nix { };
  intellij = self.callPackage ../development/java-modules/intellij-sdk { };

  fetchKotlin = self.callPackage ../build-support/fetchkotlin { };
  kotlinSources = self.callPackage ../development/compilers/kotlin/sources.nix { };
  kotlin = self.callPackage ../development/compilers/kotlin { } // {
    # published runtime jars, bit for bit (kotlin/repro/README.md)
    repro = self.callPackage ../development/compilers/kotlin/repro { };
  };
  kotlinLibs = self.callPackage ../development/compilers/kotlin/libs.nix { };

  jdkBootstrap = self.callPackage ../development/compilers/openjdk/bootstrap.nix { };
  icedtea7 = self.callPackage ../development/compilers/openjdk/icedtea7.nix { };
  jdks = self.callPackage ../development/compilers/openjdk { inherit pkgs; };

  # Scala from source, see pkgs/development/compilers/scala: `nix build .#scala.latest`
  scala = self.callPackage ../development/compilers/scala { };

  # The Pizza compiler from source, see pkgs/development/compilers/pizza: `nix build .#pizza.latest`
  # (standalone: nothing else uses it; PiCo has its own boot translator)
  pizza = self.callPackage ../development/compilers/pizza { };

  # PiCo, the compiler Scala's 2004 boot compiler was written for, see pkgs/development/compilers/pico
  pico = self.callPackage ../development/compilers/pico { };

  # Build tools
  ant = self.callPackage ../development/tools/build-managers/apache-ant { };
  ant_1_10 = self.callPackage ../development/tools/build-managers/apache-ant {
    version = "1.10.15";
    hash = "sha256-oitJW5wFSChB+RnTRA0rOCE64iPgOYWbc6q83kRBmbE=";
  };
  java = self.callPackage ../development/java-modules { };
  # ICU4J's data, built from the Unicode data text files (for antlr's icu4j).
  icuData = self.callPackage ../development/java-modules/icu { };
  antlr = self.callPackage ../development/tools/parsing/antlr { };
  # Groovy needs JDK >= 9 to build.
  jdk11 = self.jdks.openjdk11;
  javaLib11 = self.callPackage ../build-support/java/mk-jar.nix { jdk = self.jdk11; };
  # Gradle: JDK 21 from the chain (pkgs/development/compilers/openjdk).
  jdk21 = self.jdks.openjdk21;
  javaLib21 = self.callPackage ../build-support/java/mk-jar.nix { jdk = self.jdk21; };
  gradleLibs = self.callPackage ../development/tools/build-managers/gradle/libs.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) mkJar classpathOf;
  };

  gradleLibs8 = self.callPackage ../development/tools/build-managers/gradle/libs.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) mkJar classpathOf;
    slf4jLegacy = true;
  };

  # Gradle source trees by version (gradle/versions.nix)
  gradleVersions = import ../development/tools/build-managers/gradle/versions.nix;
  gradleSources = lib.mapAttrs (
    version: v:
    self.callPackage ../development/tools/build-managers/gradle/source.nix { inherit version; inherit (v) hash; }
  ) self.gradleVersions;
  gradleSrc = self.gradleSources.${self.gradleLatest};
  gradleSrc8 = self.gradleSources."8.14.3";

  gradleGroovy = self.callPackage ../development/tools/build-managers/gradle/groovy.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    inherit (self.gradleLibs) mk gh;
    inherit (self.groovy) javacc qdox-1_12;
  };

  gradleGroovy3 = self.callPackage ../development/tools/build-managers/gradle/groovy3.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    inherit (self.gradleLibs) mk gh;
    inherit (self.groovy) javacc qdox-1_12;
  };

  # a jar of the Kotlin 2.4.0 distribution, in the share/java layout used by classpathOf
  kotlinJar =
    name:
    pkgs.runCommand name { } ''
      mkdir -p $out/share/java
      ln -s ${self.kotlin."2.4.0"}/lib/${name}.jar $out/share/java/${name}.jar
    '';

  kotlinEmbeddable =
    self.callPackage ../development/tools/build-managers/gradle/kotlin-embeddable.nix
      {
        jdk = self.jdk21;
        inherit (self) gradleLibs;
        inherit (self.javaLib21) classpathOf;
      };

  kotlinCompilerEmbeddable = self.kotlinEmbeddable.relocate {
    name = "kotlin-compiler-embeddable";
    # (the modern ASM first: it replaces the compiler's bundled one)
    jars = [
      "${self.kotlinAsm}/share/java/kotlin-asm.jar"
      "${self.kotlin."2.4.0"}/lib/kotlin-compiler.jar"
    ];
    exclude = [
      "com/sun/jna/"
      "org/jetbrains/annotations/"
      "build/"
    ];
  };

  # a newer ASM than the one bundled in the compiler (which cannot read sealed classes), under the compiler's package names
  kotlinAsm = self.kotlinEmbeddable.relocate {
    name = "kotlin-asm";
    prefix = "org.jetbrains";
    packages = [ "org.objectweb" ];
    keep = [ ];
    jars = map (a: "${a}/share/java/${a.pname}.jar") (
      with self.gradleLibs;
      [
        asm-lenient
        asm-tree
        asm-commons
        asm-util
        asm-analysis
      ]
    );
  };

  kotlinPlugins = self.callPackage ../development/tools/build-managers/gradle/kotlin-plugins.nix {
    jdk = self.jdk21;
    kotlinSrc = self.kotlinSources."2.4.0";
    kotlinSrc17 = self.kotlinSources."1.7.0";
    jetbrainsAnnotations = self.gradleLibs.jetbrains-annotations;
    inherit (self) kotlinAsm;
    kotlinCompiler = self.kotlin."2.4.0";
  };

  # embeddable (relocated) variants of the Kotlin compiler plugins and scripting libraries
  kotlinRelocated = self.kotlinRelocatedFor self.kotlinPlugins "2.4.0";
  kotlinRelocatedFor =
    p: version:
    let
      jarOf = d: "${d}/share/java/${d.pname}.jar";
      relocate =
        name: ds:
        self.kotlinEmbeddable.relocate {
          inherit name version;
          jars = map jarOf ds;
        };
    in
    lib.fix (r: {
      kotlinScriptingJvmHost = relocate "kotlin-scripting-jvm-host" [ p.scriptingJvmHost ];
      kotlinScriptingCompilerEmbeddable = relocate "kotlin-scripting-compiler-embeddable" [
        p.scriptingCompiler
        p.powerAssert
      ];
      kotlinScriptingCompilerImplEmbeddable = relocate "kotlin-scripting-compiler-impl-embeddable" [
        p.scriptingCompilerImpl
      ];
      kotlinSamWithReceiverCompilerPlugin = relocate "kotlin-sam-with-receiver-compiler-plugin" [
        p.samWithReceiver
      ];
      kotlinAssignmentCompilerEmbeddable = relocate "kotlin-assignment-compiler-plugin-embeddable" [
        p.assignment
      ];
      kotlinMetadataJvm = self.kotlinEmbeddable.relocate {
        inherit version;
        name = "kotlin-metadata-jvm";
        jars = [ (jarOf p.metadataJvmUnshaded) ];
        packages = [ "org.jetbrains.kotlin=kotlin.metadata.internal" ];
        keep = [ ];
      };
      kotlinBuildToolsImpl = self.kotlinEmbeddable.relocate {
        inherit version;
        name = "kotlin-build-tools-impl";
        jars =
          map jarOf [
            p.buildToolsImpl
            p.scriptingCompilerImpl
            p.scriptingCompiler
            p.scriptingCommon
            p.scriptingJvm
            p.kotlinx-serialization-core
            p.kotlinx-serialization-protobuf
            p.diff-utils
          ]
          ++ [ (jarOf r.kotlinMetadataJvm) ];
        packages = [
          "org.jetbrains.kotlin.scripting=org.jetbrains.kotlin.buildtools.internal.scripting"
          "kotlin.script.experimental=org.jetbrains.kotlin.buildtools.internal.scripting"
          "kotlinx.serialization=org.jetbrains.kotlin.buildtools.internal.serialization"
          "difflib=org.jetbrains.kotlin.buildtools.internal.difflib"
          "com.github.difflib=org.jetbrains.kotlin.buildtools.internal.difflib"
        ]
        ++ [
          "com.google"
          "com.sampullara"
          "org.apache"
          "org.jdom"
          "org.picocontainer"
          "org.jline"
          "org.fusesource"
          "net.jpountz"
          "one.util.streamex"
          "it.unimi.dsi.fastutil"
          "kotlinx.collections.immutable"
          "com.fasterxml"
          "org.codehaus"
          "io.opentelemetry"
          "io.vavr"
          "org.antlr"
          "javax.inject"
          "com.intellij"
        ];
        exclude = [
          "META-INF/services/org.jetbrains.kotlin.compiler.plugin."
        ];
      };
      kotlinxMetadataJvm = self.kotlinEmbeddable.relocate {
        inherit version;
        name = "kotlinx-metadata-jvm";
        jars = [ (jarOf p.metadataJvm050Unshaded) ];
        packages = [ "org.jetbrains.kotlin=kotlinx.metadata.internal" ];
        keep = [ ];
      };
      kotlinScriptingCommon = p.scriptingCommon;
      kotlinScriptingJvm = p.scriptingJvm;
      kotlinBuildToolsApi = p.buildToolsApi;
    }
    // lib.optionalAttrs (version != "2.4.0") {
      kotlinDaemonEmbeddable = relocate "kotlin-daemon-embeddable" [ p.daemon ];
    });

  # the Kotlin 2.4.10 stack (Gradle 9.8.2's embedded Kotlin, also the compiler of its own build)
  kotlinPlugins2410 = self.kotlinPlugins.override {
    version = "2.4.10";
    kxCompilerArgs = [
      "-P"
      "plugin:org.jetbrains.kotlinx.serialization:disableIntrinsic=false"
      "-Xreturn-value-checker=full"
      "-Xjdk-release=1.8"
    ];
    kotlinSrc = self.kotlinSources."2.4.10";
    kotlinCompiler = self.kotlin."2.4.10";
  };
  kotlinCompilerEmbeddable2410 = self.kotlinEmbeddable.relocate {
    name = "kotlin-compiler-embeddable";
    version = "2.4.10";
    jars = [
      "${self.kotlinAsm}/share/java/kotlin-asm.jar"
      "${self.kotlin."2.4.10"}/lib/kotlin-compiler.jar"
    ];
    exclude = [
      "com/sun/jna/"
      "org/jetbrains/annotations/"
      "build/"
    ];
  };
  kotlinRelocated2410 = self.kotlinRelocatedFor self.kotlinPlugins2410 "2.4.10";

  # the Kotlin 2.1.0 stack (for Gradle 8.x, whose Kotlin DSL needs the older compiler API)
  kotlinPlugins21 = self.callPackage ../development/tools/build-managers/gradle/kotlin-plugins.nix {
    jdk = self.jdk21;
    kotlinSrc = self.kotlinSources."2.1.0";
    kotlinSrc17 = self.kotlinSources."1.7.0";
    jetbrainsAnnotations = self.gradleLibs.jetbrains-annotations;
    inherit (self) kotlinAsm;
    kotlinCompiler = self.kotlin."2.1.0";
    withPowerAssert = false;
    kxVersion = "1.6.2";
    kxHash = "sha256-v6hOOPDN11TaQMDsIiMvkZfBxy6ouRSrIaR+qpQ+O54=";
  };
  kotlinCompilerEmbeddable21 = self.kotlinEmbeddable.relocate {
    name = "kotlin-compiler-embeddable";
    jars = [
      "${self.kotlinAsm}/share/java/kotlin-asm.jar"
      "${self.kotlin."2.1.0"}/lib/kotlin-compiler.jar"
    ];
    exclude = [
      "com/sun/jna/"
      "org/jetbrains/annotations/"
      "build/"
    ];
  };
  kotlinRelocated21 =
    let
      jarOf = d: "${d}/share/java/${d.pname}.jar";
      relocate =
        name: ds:
        self.kotlinEmbeddable.relocate {
          inherit name;
          jars = map jarOf ds;
        };
      p = self.kotlinPlugins21;
    in
    {
      kotlinScriptingJvmHost = relocate "kotlin-scripting-jvm-host" [ p.scriptingJvmHost ];
      kotlinScriptingCompilerEmbeddable = relocate "kotlin-scripting-compiler-embeddable" [
        p.scriptingCompiler
      ];
      kotlinScriptingCompilerImplEmbeddable = relocate "kotlin-scripting-compiler-impl-embeddable" [
        p.scriptingCompilerImpl
      ];
      kotlinSamWithReceiverCompilerPlugin = relocate "kotlin-sam-with-receiver-compiler-plugin" [
        p.samWithReceiver
      ];
      kotlinAssignmentCompilerEmbeddable = relocate "kotlin-assignment-compiler-plugin-embeddable" [
        p.assignment
      ];
      inherit (self.kotlinRelocated) kotlinxMetadataJvm;
      kotlinScriptingCommon = p.scriptingCommon;
      kotlinScriptingJvm = p.scriptingJvm;
    };

  # Zinc 1.12.0 and Scala 2.13.18's jars, compiled by the chain's scalac 2.13.18; as a Maven
  # repository for Gradle's `scala` plugin: scalaModules.mavenRepo
  scalaModules = self.callPackage ../development/scala-modules {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    s230 = self.scala."2.13.18";
    inherit (self.gradleLibs) jansi jsr305;
    jetbrainsAnnotations = self.gradleLibs.jetbrains-annotations;
    log4jOptional = with self.gradleLibs; [
      jackson-core
      jackson-databind
      jackson-annotations
      commons-compress
      jctools-core
    ];
    inherit (pkgs) protobuf_25;
  };

  # Gradle 9.9's libs.configurationCacheReport (1.36): its JVM half, with a plain JSON page as viewer
  gradleConfigurationCacheReport =
    self.callPackage ../development/tools/build-managers/gradle/configuration-cache-report.nix
      {
        jdk = self.jdk21;
        kotlinCompiler = self.kotlin."2.4.0";
        inherit (self) kotlinAsm kotlinPlugins;
      };

  # Gradle `version` from its sources: modules, distribution, generated Kotlin extensions
  gradleFor =
    {
      version,
      src,
      modulesJson,
      embeddedKotlin ? "2.4.0",
      kotlinDslPlugins ? "6.7.6",
      extraNotBuilt ? [ ],
      libOverrides ? { },
      patches ? { },
      jdkInternalsModules ? [ ],
      kotlinVersion ? "2.4.0",
      extraKotlinArgs ? [ ],
      registryStyle ? "sidecar",
      libs ? self.gradleLibs,
      groovy ? self.gradleGroovy,
      # gradle/dists/VERSION.json (scripts/gradle-dist-lock): build the release's jars and layout
      # like Gradle's own build, to compare with the published distribution
      upstreamLock ? null,
      # (upstreamLock) jars of the lock's components that are no Gradle dependency of ours
      extraLockJars ? { },
    }:
    let
      kdist = self.kotlin.${kotlinVersion};
      kjar =
        name:
        pkgs.runCommand name (lib.optionalAttrs (upstreamLock != null) { version = kotlinVersion; }) ''
          mkdir -p $out/share/java
          ln -s ${kdist}/lib/${name}.jar $out/share/java/${name}.jar
        '';
      stacks = {
        "2.4.0" = [ self.kotlinCompilerEmbeddable self.kotlinRelocated self.kotlinPlugins ];
        "2.4.10" = [ self.kotlinCompilerEmbeddable2410 self.kotlinRelocated2410 self.kotlinPlugins2410 ];
      };
      stack = stacks.${kotlinVersion} or [ self.kotlinCompilerEmbeddable21 self.kotlinRelocated21 self.kotlinPlugins21 ];
      kemb = lib.elemAt stack 0;
      krel = lib.elemAt stack 1;
      kplug = lib.elemAt stack 2;
      # (Gradle's release builds compile with JDK 25: gradle/gradle-daemon-jvm.properties)
      buildJdk = if upstreamLock != null then self.jdks.openjdk25 else self.jdk21;
      modules = self.callPackage ../development/tools/build-managers/gradle/modules.nix ({
        jdk = buildJdk;
        kotlinHostJdk = self.jdk21;
        inherit (self.javaLib21) classpathOf closureOf;
        gradleSrc = src;
        gradleLibs = libs;
        gradleGroovy = groovy;
        kotlinCompiler = kdist;
        kotlinPlugins = kplug;
        inherit (self) kotlinAsm;
        extraLibs = {
          fastutil = self.java.fastutil;
          kotlinStdlib = kjar "kotlin-stdlib";
          kotlinReflect = kjar "kotlin-reflect";
          kotlinScriptRuntime = kjar "kotlin-script-runtime";
          kotlinCompilerEmbeddable = kemb;
          # Zinc 1.12.0, compiled by the chain's Scala 2.13.18 (compileOnly: the Scala plugin
          # resolves Zinc for a build, scalaModules.mavenRepo)
          zinc = self.scalaModules.zinc;
        }
        // krel;
        gradleVersion = version;
        inherit
          modulesJson
          embeddedKotlin
          kotlinDslPlugins
          extraNotBuilt
          libOverrides
          patches
          jdkInternalsModules
          extraKotlinArgs
          ;
      }
      // lib.optionalAttrs (upstreamLock != null) { upstreamJars = true; });
      distBase = self.callPackage ../development/tools/build-managers/gradle/dist.nix ({
        jdk = self.jdk21;
        inherit (self.javaLib21) classpathOf;
        gradleSrc = src;
        gradleLibs = libs;
        gradleModules = modules;
        inherit
          version
          modulesJson
          registryStyle
          embeddedKotlin
          upstreamLock
          ;
      }
      // lib.optionalAttrs (upstreamLock != null) { inherit extraLockJars; });
      extensions = self.callPackage ../development/tools/build-managers/gradle/kotlin-extensions.nix {
        jdk = self.jdk21;
        inherit (self.javaLib21) classpathOf;
        gradleDistBase = distBase;
        gradleModules = modules;
        gradleLibs = libs;
        inherit (self) kotlinAsm;
        kotlinCompiler = kdist;
        inherit version;
      };
    in
    rec {
      inherit modules distBase extensions;
      dist = distBase.override { kotlinDslExtensions = extensions; };
      # the distribution builds and runs a small project offline (gradle/tests/smoke)
      smoke = self.callPackage ../development/tools/build-managers/gradle/smoke.nix {
        jdk = self.jdk21;
        gradleDist = dist;
      };
      # and compiles Scala with Zinc (gradle/tests/scala; Scala and Zinc from scalaModules)
      scalaSmoke = self.callPackage ../development/tools/build-managers/gradle/scala-smoke.nix {
        jdk = self.jdk21;
        gradleDist = dist;
        scalaRepo = self.scalaModules.mavenRepo;
      };
    };

  # The settings of a Gradle release line; a version's own (gradle/versions.nix) go on top
  gradleLine =
    version:
    if lib.hasPrefix "8." version then
      {
        embeddedKotlin = "2.0.21";
        kotlinVersion = "2.1.0";
        registryStyle = "embedded";
        libs = self.gradleLibs8;
        groovy = self.gradleGroovy3;
        extraKotlinArgs = [ "-Xconsistent-data-class-copy-visibility" ];
        kotlinDslPlugins = "5.2.0";
        libOverrides = {
          commonsLang = self.gradleLibs.commons-lang2;
          jansi = self.gradleLibs.jansi118;
          jsoup = self.gradleLibs.jsoup;
        };
        jdkInternalsModules = [ "language-java" ];
        patches = {
          kotlin-dsl = ''
            sed -i 's|^operator fun <T> Action<in T>.invoke(target: T) = execute(target)|operator fun <T> Action<in T>.invoke(target: T) = execute(target as (T \& Any))|' platforms/core-configuration/kotlin-dsl/src/main/kotlin/org/gradle/kotlin/dsl/ActionExtensions.kt
          '';
          core = ''
            sed -i 's|super(specHolder.getSpecs().toArray(Cast.uncheckedCast(new Spec\[0\])));|super(Cast.<Spec<? super T>[]>uncheckedCast(specHolder.getSpecs().toArray(new Spec[0])));|' subprojects/core/src/main/java/org/gradle/api/internal/tasks/execution/DescribingAndSpec.java
          '';
          # (javac 9+ adds the module as the outermost enclosing element of a package)
          internal-instrumentation-processor = ''
            sed -i 's|if (element instanceof PackageElement) {|if (element instanceof javax.lang.model.element.ModuleElement) { return; } if (element instanceof PackageElement) {|' platforms/core-runtime/internal-instrumentation-processor/src/main/java/org/gradle/internal/instrumentation/processor/modelreader/impl/TypeMirrorToType.java
          '';
        };
      }
    else if lib.versionAtLeast (lib.versions.majorMinor version) "9.9" then
      {
        # 9.9 compiles against the report model (it was only the HTML viewer before)
        libOverrides = {
          configurationCacheReport = self.gradleConfigurationCacheReport;
          nativePlatform = self.gradleLibs.native-platform-30;
        };
      }
    else
      { };

  kotlinxCoroutinesCore = self.callPackage ../development/tools/build-managers/gradle/kotlinx-coroutines.nix {
    jdk = self.jdk21;
    moduleInfoJdk = self.jdks.openjdk11;
    kotlinCompiler = self.kotlin."2.1.0";
    inherit (self) kotlinAsm;
    atomicfuPlugin = self.kotlinPlugins21.atomicfu;
  };

  # What a release's published distribution has where it differs from its line (gradleLine):
  # the versions of its third-party modules (gradle/dists/VERSION.json) and the artifact
  # transforms of Gradle's build (gradle/transforms)
  gradleRelease = {
    "9.8.2" =
      let
        l = self.gradleLibs;
        lock = lib.importJSON ../development/tools/build-managers/gradle/dists/9.8.2.json;
        tr = self.callPackage ../development/tools/build-managers/gradle/transforms {
          jdk = self.jdk21;
          gradleSrc = self.gradleSources."9.8.2";
          kotlinCompiler = self.kotlin."2.4.10";
          inherit (self) kotlinAsm;
          inherit (l) asm asm-commons asm-tree;
        };
        jar = d: "${d}/share/java/${d.pname}.jar";
      in
      {
        groovy = self.gradleGroovy.override {
          javacDebug = true;
          javaparser = {
            version = "3.27.1";
            hash = "sha256-xuUMHCSxuVb+GYqO428jPDWk922EDpOJUe8IKMzYy24=";
          };
        };
        libOverrides = {
          guava = l.guava-parameters;
          jacksonCore = l.jackson_2_22_3.jackson-core;
          jacksonDatabind = l.jackson_2_22_3.jackson-databind;
          jacksonDatatypeJdk8 = l.jackson_2_22_3.jackson-datatype-jdk8;
          jacksonDatatypeJsr310 = l.jackson_2_22_3.jackson-datatype-jsr310;
          tomlj = l.tomlj-antlr472;
          fastutil = tr.minify {
            jar = self.java.fastutil_8_5_2;
            coordinates = "it.unimi.dsi:fastutil";
          };
          jnrConstants = tr.minify {
            jar = l.jnr-constants;
            coordinates = "com.github.jnr:jnr-constants";
          };
          jspecify = tr.noModuleAnnotation {
            jar = l.jspecify;
            time = lock.transformTimes.jspecify;
          };
          # configuration-cache-report(-jvm) 1.34: only the report viewer, compiled with Kotlin/JS
          # upstream; in its place the page of gradleConfigurationCacheReport
          configurationCacheReport =
            pkgs.runCommand "configuration-cache-report-1.34"
              {
                pname = "configuration-cache-report";
                version = "1.34";
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                d=r/org/gradle/internal/configuration/problems
                mkdir -p $d $out/share/java
                cp ${../development/tools/build-managers/gradle/configuration-cache-report/report-template.html} $d/configuration-cache-report.html
                python3 ${../development/tools/build-managers/gradle/gradle-jar.py} $out/share/java/configuration-cache-report.jar --root r
              '';
        };
        extraLockJars = {
          ant-antlr = "${self.ant_1_10}/share/ant/lib/ant-antlr.jar";
          kotlin-daemon-embeddable = jar self.kotlinRelocated2410.kotlinDaemonEmbeddable;
          kotlinx-coroutines-core-jvm = jar self.kotlinxCoroutinesCore;
        };
      };
  };

  # every version of gradle/versions.nix: `nix build .#gradle."9.8.0".dist`
  gradle = lib.mapAttrs (
    version: v:
    self.gradleFor (
      {
        inherit version;
        src = self.gradleSources.${version};
        modulesJson = ../development/tools/build-managers/gradle/modules + "/${version}.json";
      }
      // self.gradleLine version
      // self.gradleRelease.${version} or { }
      // removeAttrs v [ "hash" ]
    )
  ) self.gradleVersions;
  # the newest release (not a milestone or release candidate)
  gradleLatest = lib.last (
    lib.sort lib.versionOlder (lib.filter (v: builtins.match ".*-(M|RC).*" v == null) (lib.attrNames self.gradleVersions))
  );

  gradleModules = self.gradle.${self.gradleLatest}.modules;
  gradleDistBase = self.gradle.${self.gradleLatest}.distBase;
  gradleKotlinExtensions = self.gradle.${self.gradleLatest}.extensions;
  gradleDist = self.gradle.${self.gradleLatest}.dist;

  groovy = self.callPackage ../development/interpreters/groovy {
    jdk = self.jdk11;
    inherit (self.javaLib11) mkJar;
    ant = self.ant_1_10;
  };
})
