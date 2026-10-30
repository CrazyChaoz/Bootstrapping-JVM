# Third-party inputs of the Scala 2 stages, from source.
{
  lib,
  stdenv,
  fetchFromGitHub,
  runCommand,
  jdk8,
  jdk21,
}:

let
  # a directory of the trees `fetch` gives for each version: DIR/VERSION
  byVersion =
    name: fetch: hashes:
    runCommand name { } (
      ''
        mkdir $out
      ''
      + lib.concatStrings (lib.mapAttrsToList (v: hash: "ln -s ${fetch v hash} $out/${v}\n") hashes)
    );
in
{
  # jline 1.0 (the API of the 0.9.x jars Scala shipped from 2007-07), for the REPL
  jline = stdenv.mkDerivation {
    pname = "jline";
    version = "1.0";
    src = fetchFromGitHub {
      owner = "jline";
      repo = "jline1";
      rev = "jline-1.0";
      hash = "sha256-2ms8i3ChcDUiUUA0+Q9sRiak6qpy38wUcVRGmCqwktY=";
      postFetch = "find $out -name '*.dll' -delete";
    };
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      mkdir -p $out
      ${jdk21}/bin/javac -nowarn --release 8 -encoding utf8 -d $out $(find src/main/java -name '*.java')
      (cd src/main/resources && find . -name '*.properties' -exec install -Dm644 {} $out/{} \;)
      runHook postBuild
    '';
    dontInstall = true;
  };

  # jansi 1.4 with jansi-native 1.0 and hawtjni-runtime 1.0, for Scala's jline fork (2010-12);
  # the Java parts only: the native Windows console support is never loaded on Unix
  jansi =
    let
      fusesource =
        repo: rev: hash:
        fetchFromGitHub {
          owner = "fusesource";
          inherit repo rev hash;
        };
      srcs = [
        "${
          fusesource "jansi" "jansi-1.4" "sha256-Q8r/CIV34v/UPfdJXMGX0pLEtZC+C2NAYL/SAIfRZao="
        }/src/main/java"
        "${
          fusesource "jansi-native" "jansi-native-1.0" "sha256-2gRYTpwlzrkAbKsrJIAWIVFbkiPEoxDYhYrdpR4QpUM="
        }/src/main/java"
        "${
          fusesource "hawtjni" "hawtjni-1.0" "sha256-4rwOvidZ5mrvIDBCihX+XNxzBg4B9NNcUXQG2C8kw7U="
        }/hawtjni-runtime/src/main/java"
      ];
    in
    runCommand "jansi-1.4" { } ''
      mkdir -p $out
      ${jdk8}/bin/javac -nowarn -encoding utf8 -d $out $(find ${lib.concatStringsSep " " srcs} -name '*.java')
    '';

  # scala-asm, the ASM fork of the compiler once ASM left the tree (2015-05): the releases the
  # trees name in versions.properties (2017 on), and 5.1.0-scala-2 (ASM 5.1 with Scala's
  # cherry-picks) for those that name none or one that was never tagged (5.0.x-scala-N of
  # 2015-16, which it is a superset of)
  scalaAsmSrcs =
    byVersion "scala-asm-srcs"
      (
        v: hash:
        "${
          fetchFromGitHub {
            owner = "scala";
            repo = "scala-asm";
            rev = "v${v}";
            inherit hash;
          }
        }/src/main/java"
      )
      {
        "5.1.0-scala-2" = "sha256-DHrPEcX6QcuK6rsqMU32xB/b2OcL0Pbe9Q76kKLuXzc=";
        "5.2.0-scala-1" = "sha256-DubVrroyP7k0fgqCBVDx/u5plk8cysG0Z2HgaMb+tcs=";
        "6.0.0-scala-1" = "sha256-G4P2CZv44E4LfZhIuuxoD8a21PLbymR0Md2X04neWM8=";
        "6.2.0-scala-2" = "sha256-vJbPzDHCReqzeClrktocMRIn0Y/DiC0kE3hK0EpHNDc=";
        "7.0.0-scala-1" = "sha256-Q5EFV2W1uernQugwHOiEPqFiEV24tpsAIUXpSSDxLmk=";
        "7.3.1-scala-1" = "sha256-gCHnwXe9G+fghnLIJY56Y9AYGenjVMbM3fxODxAJaB0=";
        "9.1.0-scala-1" = "sha256-dAxKr6b7HbkIHTyJYPFL2DNMcH24W4Wb7NyBNc2iWfM=";
        "9.2.0-scala-1" = "sha256-5Cb+CaMOM84/GNenoLrZrfdlqIrbVUjPm1OIxD1NwFY=";
        "9.3.0-scala-1" = "sha256-GnR8YbpSnRNvn5f6m+dfnJTHxgPXqir5JunFtkwwjWo=";
        "9.4.0-scala-1" = "sha256-QmCIXoWsx4AGXXFkaYY3TTve8SGLqvhJCDDs9S5l+xA=";
        "9.5.0-scala-1" = "sha256-8HQsQ2Kwhfn5f62gOKKOPxpjgmV6jgjROy7QdPmLrNs=";
        "9.6.0-scala-1" = "sha256-LqXit8/4AK/PZj96rkOSL2brqW08hVCu2ddfV/VFpz0=";
        "9.7.0-scala-2" = "sha256-kdDh4lPkmMURFBpYXgrY49SOELBmfh2ZhV8XhbRnUd8=";
        "9.7.1-scala-1" = "sha256-ZWbI5DK26wVMmJouxg0S2dEaGtb0iqvE0Q5vOY8OTZ4=";
        "9.8.0-scala-1" = "sha256-OqQnxDzJRlFKGN7YS6ANzeZ7IrNiiNLPXGngGGcmRRo=";
        "9.9.0-scala-1" = "sha256-ckAD1N1C0uAxObw3K33D6B+jwFGQvUenZLTI9GB0qVM=";
      };

  # java-diff-utils, for the compiler's -Yprint-trees:diff (2022-05 on): the releases the
  # trees name in build.sbt
  diffutilsSrcs =
    byVersion "java-diff-utils-srcs"
      (
        v: hash:
        fetchFromGitHub {
          owner = "java-diff-utils";
          repo = "java-diff-utils";
          rev = "java-diff-utils-parent-${v}";
          inherit hash;
        }
      )
      {
        "4.11" = "sha256-jE1dl7GDakUph3r6XmdQAfam2yW2GKKlu3vTpVhCQlY=";
        "4.12" = "sha256-QhdBPejv9yQBY4Oc4NQw2FultQPdi0eGJyqiIL56jQE=";
        "4.15" = "sha256-HZN6chKTLiXTwSA+7Ud2sYG8i9qdQnLSqVfpjIJ1yk0=";
        "4.16" = "sha256-H2F+20URht/Va3EP1Eztq1cjpCfNG77ePRRq1mrYvGY=";
      };
}
