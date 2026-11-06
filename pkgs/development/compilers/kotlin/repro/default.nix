# Kotlin releases' published JVM runtime jars rebuilt bit for bit by the chain's compilers, see
# README.md.  Per release (`kotlin.repro."2.4.10".runtime` etc.):
#
#   runtime    kotlin-stdlib, kotlin-stdlib-jdk7, kotlin-stdlib-jdk8, kotlin-script-runtime, kotlin-test
#   upstream   the same jars from Maven Central, for the comparison only
#   check      runtime against upstream (fails unless all are identical)
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  python3,
  jdks,
  java,
  kotlin,
}:

let
  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = ./scripts;
  };
  gradleJar = ../../../tools/build-managers/gradle/gradle-jar.py;

  release =
    version:
    {
      # the chain's compiler nearest to the release's bootstrap compiler
      # (gradle.properties' bootstrap.kotlin.default.version)
      compiler,
      # the release's build number (Implementation-Version: VERSION-release-BUILD), a fact of
      # JetBrains' CI
      build,
      script,
      hashes,
      src ? kotlin.${version}.src,
    }:
    let
      runtime = stdenv.mkDerivation {
        pname = "kotlin-runtime-repro";
        inherit version;
        dontUnpack = true;
        dontConfigure = true;
        dontFixup = true;
        nativeBuildInputs = [ python3 ];
        env = {
          SRC = "${src}";
          KOTLIN = "${compiler}";
          JDK8 = "${jdks.openjdk8}";
          JDK11 = "${jdks.openjdk11}";
          JDK17 = "${jdks.openjdk17}";
          # org.jetbrains:annotations 13.0 has no type-use targets; 16.0.3's Java 5 variant neither
          ANN = "${java.jetbrains-annotations-16}/share/java/intellij-annotations.jar";
          JARPY = "${gradleJar}";
          SCRIPTS = "${scripts}/scripts";
          VERSION = version;
          BUILD = build;
        };
        buildPhase = ''
          runHook preBuild
          WORK=$TMPDIR/work OUT=$out/share/java bash ${scripts}/scripts/${script}
          runHook postBuild
        '';
        dontInstall = true;
        meta = {
          description = "Kotlin ${version}'s JVM runtime jars as published, rebuilt from source";
          homepage = "https://github.com/JetBrains/kotlin";
          license = lib.licenses.asl20;
          platforms = lib.platforms.linux;
        };
      };
      upstream = runCommand "kotlin-runtime-${version}-upstream" { } (
        "mkdir $out\n"
        + lib.concatStrings (
          lib.mapAttrsToList (a: hash: ''
            ln -s ${
              fetchurl {
                url = "https://repo1.maven.org/maven2/org/jetbrains/kotlin/${a}/${version}/${a}-${version}.jar";
                inherit hash;
              }
            } $out/${a}.jar
          '') hashes
        )
      );
      check = runCommand "kotlin-runtime-${version}-repro-check" { nativeBuildInputs = [ python3 ]; } ''
        python3 -I ${scripts}/scripts/check.py ${upstream} ${runtime}/share/java | tee $out
      '';
    in
    {
      inherit runtime upstream check;
    };
in
lib.mapAttrs release {
  "2.4.10" = {
    # bootstrap 2.4.0-dev-8449
    compiler = kotlin."2.4.0";
    build = "377";
    script = "runtime-2.4.sh";
    hashes = {
      kotlin-stdlib = "sha256-TsApO8N1FCOyA/HYSTJRxXxC5z62N3prhWDQl0/wpt8=";
      kotlin-stdlib-jdk7 = "sha256-56j+fKzzucg49rP8sm391B+ERVGjumf9P5WaDZ1cC+8=";
      kotlin-stdlib-jdk8 = "sha256-CDRrf0z7pAwRORYcnzC2gZn0Jc7PO2PeZ4OAY/NKBcc=";
      kotlin-script-runtime = "sha256-9KWzDC/fvjhrCXEBt5idvuo3Q8BjlhNmZHhOCOFcaJk=";
      kotlin-test = "sha256-XTNKexfOmyI+TbNeNV8AgvsFUdNsBCSlmb81aGuiq3s=";
    };
  };
}
