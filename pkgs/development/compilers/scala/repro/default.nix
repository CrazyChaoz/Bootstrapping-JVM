# Scala 3.10.0's published jars rebuilt bit for bit from the chain's compilers, see README.md.
#
#   library    scala-library-3.10.0.jar (deterministic)
#   compiler   scala3-interfaces, tasty-core_3, scala3-compiler_3 and scala3-library_3 3.10.0
#              (the compiler jar comes out identical in about 1 of 4 runs: upstream's typing
#              depends on GC timing; `nix build --rebuild` runs it again)
#   upstream   the jars of Maven Central, for the comparison only
#   check      all five against upstream (fails unless all are identical: for the
#              compiler jar, `nix build --rebuild .#scala.repro.compiler` until it is)
#   checkLibrary  the library jar against upstream (deterministic)
#   env        the inputs for the scripts run by hand: REPRO_ENV=$(nix build --print-out-paths .#scala.repro.env)
{
  lib,
  stdenv,
  runCommand,
  writeText,
  fetchurl,
  python3,
  jdk17,
  # the nonbootstrapped compiler: 3.10.0 compiled by 3.9.0 (dotty stage d74)
  d74,
  # scalac 2.13.18 (Scala 2 stage s230)
  s230,
  # scala/scala3 at 3.10.0 and scala/scala at v2.13.18 (the trees of d74 and s230)
  scala3Src ? d74.src,
  scala2Src ? s230.src,
  # scala-js 1.22.0's tree
  scalajsSrc,
}:

let
  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./scripts
      ./tools
    ];
  };

  inputs = {
    SRC = "${scala3Src}";
    NIX = "${d74}";
    S230 = "${s230}";
    SRC2 = "${scala2Src}";
    SJS = "${scalajsSrc}";
    JDK17 = "${jdk17}";
  };

  mk =
    name: script:
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      dontConfigure = true;
      dontFixup = true;
      nativeBuildInputs = [ python3 ];
      env = inputs;
      buildPhase = ''
        runHook preBuild
        export WORK=$TMPDIR/work
        ${script}
        runHook postBuild
      '';
      dontInstall = true;
      meta = {
        description = "Scala 3.10.0's ${name} jar(s) as published, rebuilt from source";
        homepage = "https://github.com/scala/scala3";
        license = lib.licenses.asl20;
        platforms = lib.platforms.linux;
      };
    };

  library = mk "scala-library-3.10.0-repro" ''
    bash ${scripts}/scripts/build-library.sh $out/scala-library-3.10.0.jar
    # (the classes, for the compiler's build)
    cp -r $WORK/bl-lib $out/classes
  '';

  compiler = mk "scala3-compiler-3.10.0-repro" ''
    LIBCLASSES=${library}/classes bash ${scripts}/scripts/build-compiler.sh $out
  '';

  maven =
    artifact: hash:
    fetchurl {
      url = "https://repo1.maven.org/maven2/org/scala-lang/${artifact}/3.10.0/${artifact}-3.10.0.jar";
      inherit hash;
    };
  upstream = runCommand "scala-3.10.0-upstream-jars" { } (
    "mkdir $out\n"
    + lib.concatStrings (
      lib.mapAttrsToList (a: h: "ln -s ${maven a h} $out/${a}-3.10.0.jar\n") {
        scala-library = "sha256-tHvvsp4Cu8CKELvTh7Nc+A/5vwT9qP3z3abIrWiV8yU=";
        scala3-library_3 = "sha256-Tart4k3f7qCCu+0Ja6DEktmehChjLp/Tw4+Cz3qtS2M=";
        scala3-interfaces = "sha256-IpMjfFdGLvzCAOHPnse1dkwXRYs4hmicwWxeyaVVLd8=";
        tasty-core_3 = "sha256-zYCI20RX6EYQz98DgejC+S9An7VlrV15KjvcfTdSYFg=";
        scala3-compiler_3 = "sha256-UeJBk4lQcj+uvkIOtNO9TaOhtob2vldK0P9AQKa0vB8=";
      }
    )
  );

  checkJars =
    name: drvs:
    runCommand name { } ''
      mkdir all up
      ln -s ${lib.concatMapStringsSep " " (d: "${d}/*.jar") drvs} all/
      for j in all/*.jar; do ln -s ${upstream}/$(basename $j) up/; done
      bash ${scripts}/scripts/check.sh up all | tee $out
    '';
  check = checkJars "scala-3.10.0-repro-check" [
    library
    compiler
  ];
  checkLibrary = checkJars "scala-library-3.10.0-repro-check" [ library ];
in
{
  inherit
    library
    compiler
    upstream
    check
    checkLibrary
    ;
  env = writeText "scala-repro-env.sh" (
    lib.concatStrings (lib.mapAttrsToList (n: v: "export ${n}=${v}\n") inputs)
  );
}
