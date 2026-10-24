{ pkgs }:

pkgs.lib.makeScope pkgs.newScope (self: {
  # The JDK used by all stages.  For now this is nixpkgs' openjdk8, which is
  # itself built from source but seeded with a temurin binary; it is meant to be
  # replaced by a JDK bootstrapped from jamvm/classpath (see nix/jdk).
  jdk8 = pkgs.openjdk8;
  jdk = self.jdk8;

  # Helpers
  javaLib = self.callPackage ./lib/mk-jar.nix { };
  inherit (self.javaLib) mkJar classpathOf;

  fetchIntellij = self.callPackage ./lib/fetch-intellij.nix { };
  intellijSources = self.callPackage ./intellij/sources.nix { };
  intellij = self.callPackage ./intellij { };

  fetchKotlin = self.callPackage ./lib/fetch-kotlin.nix { };
  kotlinSources = self.callPackage ./kotlin/sources.nix { };
  kotlin = self.callPackage ./kotlin { };
  kotlinLibs = self.callPackage ./kotlin/libs.nix { };

  jdkBootstrap = self.callPackage ./jdk/bootstrap.nix { };
  icedtea7 = self.callPackage ./jdk/icedtea7.nix { };
  jdks = self.callPackage ./jdk { inherit pkgs; };

  # Scala from source, see nix/scala: `nix build .#scala.latest`
  scala = self.callPackage ./scala { };

  # Build tools
  ant = self.callPackage ./java/ant.nix { };
  ant_1_10 = self.callPackage ./java/ant.nix {
    version = "1.10.15";
    hash = "sha256-oitJW5wFSChB+RnTRA0rOCE64iPgOYWbc6q83kRBmbE=";
  };
  java = self.callPackage ./java { };
  antlr = self.callPackage ./java/antlr.nix { };
  # Groovy needs JDK >= 9 to build.
  # TODO: use the JDK from nix/jdk once the chain is complete.
  jdk11 = pkgs.openjdk11;
  javaLib11 = self.callPackage ./lib/mk-jar.nix { jdk = self.jdk11; };
  # Gradle: JDK 21 from the chain (nix/jdk).
  jdk21 = self.jdks.openjdk21;
  javaLib21 = self.callPackage ./lib/mk-jar.nix { jdk = self.jdk21; };
  gradleLibs = self.callPackage ./gradle/libs.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) mkJar classpathOf;
  };

  gradleLibs8 = self.callPackage ./gradle/libs.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) mkJar classpathOf;
    slf4jLegacy = true;
  };

  gradleSrc = self.callPackage ./gradle/source.nix { };
  gradleSrc8 = self.callPackage ./gradle/source.nix {
    version = "8.14.3";
    hash = "sha256-fyKRoK9AlZzoURvx3aMK4H1AV8M/KszLQtvo3rTSbUk=";
  };

  gradleGroovy = self.callPackage ./gradle/groovy.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    inherit (self.gradleLibs) mk gh;
    inherit (self.groovy) javacc qdox-1_12;
  };

  gradleGroovy3 = self.callPackage ./gradle/groovy3.nix {
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

  kotlinEmbeddable = self.callPackage ./gradle/kotlin-embeddable.nix {
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
    jars = map (a: "${a}/share/java/${a.pname}.jar") (with self.gradleLibs; [ asm-lenient asm-tree asm-commons asm-util asm-analysis ]);
  };

  kotlinPlugins = self.callPackage ./gradle/kotlin-plugins.nix {
    jdk = self.jdk21;
    kotlinSrc = self.kotlinSources."2.4.0";
    kotlinSrc17 = self.kotlinSources."1.7.0";
    jetbrainsAnnotations = self.gradleLibs.jetbrains-annotations;
    inherit (self) kotlinAsm;
    kotlinCompiler = self.kotlin."2.4.0";
  };

  # embeddable (relocated) variants of the Kotlin compiler plugins and scripting libraries
  kotlinRelocated =
    let
      jarOf = d: "${d}/share/java/${d.pname}.jar";
      relocate =
        name: ds:
        self.kotlinEmbeddable.relocate {
          inherit name;
          jars = map jarOf ds;
        };
      p = self.kotlinPlugins;
    in
    {
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
        name = "kotlin-metadata-jvm";
        jars = [ (jarOf p.metadataJvmUnshaded) ];
        packages = [ "org.jetbrains.kotlin=kotlin.metadata.internal" ];
        keep = [ ];
      };
      kotlinBuildToolsImpl = self.kotlinEmbeddable.relocate {
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
          ++ [ (jarOf self.kotlinRelocated.kotlinMetadataJvm) ];
        packages = [
          "org.jetbrains.kotlin.scripting=org.jetbrains.kotlin.buildtools.internal.scripting"
          "kotlin.script.experimental=org.jetbrains.kotlin.buildtools.internal.scripting"
          "kotlinx.serialization=org.jetbrains.kotlin.buildtools.internal.serialization"
          "difflib=org.jetbrains.kotlin.buildtools.internal.difflib"
          "com.github.difflib=org.jetbrains.kotlin.buildtools.internal.difflib"
        ] ++ [
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
        name = "kotlinx-metadata-jvm";
        jars = [ (jarOf p.metadataJvm050Unshaded) ];
        packages = [ "org.jetbrains.kotlin=kotlinx.metadata.internal" ];
        keep = [ ];
      };
      kotlinScriptingCommon = p.scriptingCommon;
      kotlinScriptingJvm = p.scriptingJvm;
      kotlinBuildToolsApi = p.buildToolsApi;
    };

  # the Kotlin 2.1.0 stack (for Gradle 8.x, whose Kotlin DSL needs the older compiler API)
  kotlinPlugins21 = self.callPackage ./gradle/kotlin-plugins.nix {
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
      kotlinScriptingCompilerEmbeddable = relocate "kotlin-scripting-compiler-embeddable" [ p.scriptingCompiler ];
      kotlinScriptingCompilerImplEmbeddable = relocate "kotlin-scripting-compiler-impl-embeddable" [ p.scriptingCompilerImpl ];
      kotlinSamWithReceiverCompilerPlugin = relocate "kotlin-sam-with-receiver-compiler-plugin" [ p.samWithReceiver ];
      kotlinAssignmentCompilerEmbeddable = relocate "kotlin-assignment-compiler-plugin-embeddable" [ p.assignment ];
      inherit (self.kotlinRelocated) kotlinxMetadataJvm;
      kotlinScriptingCommon = p.scriptingCommon;
      kotlinScriptingJvm = p.scriptingJvm;
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
    }:
    let
      kdist = self.kotlin.${kotlinVersion};
      kjar =
        name:
        pkgs.runCommand name { } ''
          mkdir -p $out/share/java
          ln -s ${kdist}/lib/${name}.jar $out/share/java/${name}.jar
        '';
      kemb = if kotlinVersion == "2.4.0" then self.kotlinCompilerEmbeddable else self.kotlinCompilerEmbeddable21;
      krel = if kotlinVersion == "2.4.0" then self.kotlinRelocated else self.kotlinRelocated21;
      kplug = if kotlinVersion == "2.4.0" then self.kotlinPlugins else self.kotlinPlugins21;
      modules = self.callPackage ./gradle/modules.nix {
        jdk = self.jdk21;
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
        } // krel;
        gradleVersion = version;
        inherit modulesJson embeddedKotlin kotlinDslPlugins extraNotBuilt libOverrides patches jdkInternalsModules extraKotlinArgs;
      };
      distBase = self.callPackage ./gradle/dist.nix {
        jdk = self.jdk21;
        inherit (self.javaLib21) classpathOf;
        gradleSrc = src;
        gradleLibs = libs;
        gradleModules = modules;
        inherit version modulesJson registryStyle embeddedKotlin;
      };
      extensions = self.callPackage ./gradle/kotlin-extensions.nix {
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
    {
      inherit modules distBase extensions;
      dist = distBase.override { kotlinDslExtensions = extensions; };
    };

  gradle = {
    "9.8.0" = self.gradleFor {
      version = "9.8.0";
      src = self.gradleSrc;
      modulesJson = ./gradle/modules.json;
    };
    "8.14.3" = self.gradleFor {
      version = "8.14.3";
      src = self.gradleSrc8;
      modulesJson = ./gradle/modules-8.14.3.json;
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
    };
  };

  gradleModules = self.gradle."9.8.0".modules;
  gradleDistBase = self.gradle."9.8.0".distBase;
  gradleKotlinExtensions = self.gradle."9.8.0".extensions;
  gradleDist = self.gradle."9.8.0".dist;

  groovy = self.callPackage ./java/groovy.nix {
    jdk = self.jdk11;
    inherit (self.javaLib11) mkJar;
    ant = self.ant_1_10;
  };
})
