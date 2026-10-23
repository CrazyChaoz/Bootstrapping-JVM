# Libraries needed by later Kotlin compilers, compiled with Kotlin compilers
# from our own chain.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  mkJar,
  java,
  javaLib,
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };

  # Compile Kotlin (and Java) sources with a kotlinc distribution from the
  # chain.
  mkKotlinJar =
    {
      pname,
      version,
      src,
      kotlin,
      sourceDirs,
      deps ? [ ],
      kotlincFlags ? [ ],
      resourceDirs ? [ ],
      ...
    }@args:
    stdenv.mkDerivation (
      removeAttrs args [
        "kotlin"
        "sourceDirs"
        "deps"
        "kotlincFlags"
        "resourceDirs"
      ]
      // {
        nativeBuildInputs = [
          jdk
          zip
          unzip
          stripJavaArchivesHook
        ];
        buildPhase = ''
          runHook preBuild
          export CLASSPATH="${javaLib.classpathOf deps}"
          mkdir -p build/classes
          java -Xmx4g -cp ${kotlin}/lib/kotlin-compiler.jar org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
            -d build/classes -no-stdlib \
            -cp "${kotlin}/lib/kotlin-stdlib.jar:$CLASSPATH" \
            -module-name ${pname} ${lib.escapeShellArgs kotlincFlags} \
            ${lib.escapeShellArgs sourceDirs}
          find ${lib.escapeShellArgs sourceDirs} -name '*.java' > build/java-sources
          if [ -s build/java-sources ]; then
            javac -nowarn -d build/classes -cp "build/classes:${kotlin}/lib/kotlin-stdlib.jar:$CLASSPATH" @build/java-sources
          fi
          for d in ${lib.escapeShellArgs resourceDirs}; do cp -r "$d"/. build/classes/; done
          runHook postBuild
        '';
        installPhase = ''
          mkdir -p $out/share/java
          jar cf $out/share/java/${pname}.jar -C build/classes .
        '';
        passthru = {
          javaDeps = javaLib.closureOf deps;
        };
      }
    );
in
{
  inherit mkKotlinJar;

  strip-kotlin-metadata = mkJar {
    pname = "strip-kotlin-metadata";
    version = "1";
    src = ../../tools/strip-metadata;
    deps = [ java.asm-6 ];
  };

  jline3 = mkJar {
    pname = "jline3";
    version = "3.3.1";
    src = gh "jline" "jline3" "jline-3.3.1" "sha256-8ibXYbEIN45fI3u6wD1gxdr8u2zS05NcsoLpEQ7sXBM=";
    sourceDirs = [
      "terminal/src/main/java"
      "terminal-jna/src/main/java"
      "terminal-jansi/src/main/java"
      "reader/src/main/java"
    ];
    resourceDirs = [
      "terminal/src/main/resources"
    ];
    # a shell script, in the way of mkJar's build directory
    preBuild = "rm build";
    deps = [
      java.jna
      java.jansi-1
    ];
    javaRelease = "1.8";
  };

  streamex = mkJar {
    pname = "streamex";
    version = "0.6.2";
    src = gh "amaembo" "streamex" "streamex-0.6.2" "sha256-x1384g7ssZoCxdtUXoz5UbZD+qxyg7snTbgu+JIPe1A=";
    sourceDirs = [ "src/main/java" ];
    javaRelease = "1.8";
  };

  json-org = mkJar {
    pname = "json-org";
    version = "20160807";
    src = gh "stleary" "JSON-java" "20160807" "sha256-IEQxBZ3JcQIbPbDSrVZN0dGC2OotqAe6qjXjK3rNDd0=";
    preBuild = ''
      mkdir -p jsrc/org/json
      cp *.java jsrc/org/json/
    '';
    sourceDirs = [ "jsrc" ];
    javaRelease = "1.8";
  };

  # kotlinx.coroutines 0.14 (Kotlin 1.1.4 wants 0.14.1, which is not tagged).
  kotlinx-coroutines-core-0_14 =
    kotlin:
    mkKotlinJar {
      pname = "kotlinx-coroutines-core";
      version = "0.14";
      src = gh "Kotlin" "kotlinx.coroutines" "0.14" "sha256-5WnI1QxHnIE27sX+p6uK+jhxWFL3s3zAefO9LhA65/8=";
      inherit kotlin;
      sourceDirs = [ "kotlinx-coroutines-core/src/main/kotlin" ];
      kotlincFlags = [ "-Xcoroutines=enable" ];
    };

  # kotlinx.collections.immutable (JVM, common + jvm sources); used by the FIR modules
  kotlinx-collections-immutable =
    kotlin:
    mkKotlinJar {
      pname = "kotlinx-collections-immutable";
      version = "0.3.7";
      src = gh "Kotlin" "kotlinx.collections.immutable" "v0.3.7" "sha256-ldMBZsyi2nolxUxnkn9alv7t1j5wVCZwRSzIXRzhOhs=";
      inherit kotlin;
      sourceDirs = [ "core/commonMain/src" "core/jvmMain/src" ];
      kotlincFlags = [ "-Xmulti-platform" "-Xcommon-sources=core/commonMain/src" "-Xopt-in=kotlin.RequiresOptIn" "-Xno-call-assertions" "-Xno-param-assertions" ];
    };
}
