# PiCo, the compiler of Scala's 2004 boot compiler: Pizza (Java with algebraic data types)
# made extensible, the Pizza front end of JaCo, Matthias Zenger's extensible Java compiler.
# JaCo is written in PiCo, and its repository ships compiler jars, JCup's parse tables and
# the parsers' tables.  Here none of them is used:
#
#   JCup's tables      made by a stand-in for JCup's own spec parser (pico/jcup-bootstrap)
#   the parsers        made by that JCup from the grammars (the generated sources shipped
#                      are overwritten, the tables are the same as the shipped ones)
#   boot               the sources translated to Java by Pizza's boot translator and javac
#   pico               compiled by boot, then by itself twice; the last two are the same
#
# See README.md.
{
  lib,
  stdenv,
  fetchFromGitHub,
  runCommand,
  python3,
  regexEdit,
  jdks,
}:

let
  # PiCo reads the class library from rt.jar, which JDK 9 and later no longer have
  jdk = jdks.openjdk8;

  sourcesOf =
    root: names:
    lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions (map (n: root + "/${n}") names);
    };
  builders = sourcesOf ./builders [
    "common.sh"
    "jcup.sh"
    "boot.sh"
    "stage.sh"
  ];
  jcupBootstrap = sourcesOf ./jcup-bootstrap [ "parser.java" ];

  meta = {
    description = "PiCo, the Pizza compiler of JaCo (Scala's 2004 boot compiler was written for it)";
    homepage = "https://github.com/objecthub/jaco";
    # the repository's LICENSE; its COPYRIGHT file (1997-2002) allows research and teaching only
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };

  # JaCo's sources: of the repository only what the build uses (the rest is compiler jars,
  # distributions, documents, and the other extensions, which come with test binaries) and
  # the licenses, without the parse tables
  src = fetchFromGitHub {
    owner = "objecthub";
    repo = "jaco";
    rev = "8f7b8ebc0efeba4e82dba09a00cebc7c88c4e346";
    hash = "sha256-JimZlIxq6M6nEo5QQqLeryR37c1uOM3MXOh8OSK9qXs=";
    postFetch = ''
      cd $out
      find . -mindepth 1 -maxdepth 1 ! -name sources ! -name LICENSE ! -name COPYRIGHT -exec rm -rf {} +
      find sources/jaco -mindepth 1 -maxdepth 1 ! -name framework ! -name java ! -name pizza -exec rm -rf {} +
      find . \( -name '*.jar' -o -name '*.class' -o -name '*.tables' -o -name '.DS_Store' \) -delete
    '';
  };

  # the sources/ directory, with the class file reader reading the class files of Java 8
  patched = runCommand "jaco-sources" { } ''
    cp -r --no-preserve=mode ${src}/sources $out
    patch -d $out -p2 < ${./patches/classreader.patch}
  '';

  jcup = stdenv.mkDerivation {
    pname = "jcup-bootstrapped";
    version = "0.13";
    dontUnpack = true;
    dontFixup = true;
    env = {
      JDK = "${jdk}";
      BOOT = "${jcupBootstrap}";
    };
    buildPhase = "bash ${builders}/jcup.sh ${patched} $out";
    dontInstall = true;
    inherit meta;
  };

  # the sources with the parsers made from the grammars
  parsers = runCommand "jaco-sources-with-parsers" { nativeBuildInputs = [ regexEdit ]; } ''
    cp -r --no-preserve=mode ${patched} $out
    for g in "java Parser Symbols" "pizza PizzaParser PizzaSymbols"; do
      set -- $g
      ${jdk}/bin/java -cp ${jcup} jcup.Main -package jaco.$1.grammar -parser $2 -symbols $3 \
        -o $out/jaco/$1/grammar/ -f $out/jaco/$1/grammar/Grammar.cup
      # (JCup dates the files it writes)
      regex-edit --lines '^// \w+ \w+ \d+ [\d:]+ \w+ \d+\n' "" $out/jaco/$1/grammar/{$2,$3}.java
    done
  '';

  boot = stdenv.mkDerivation {
    pname = "pico-boot";
    version = "2003";
    dontUnpack = true;
    dontFixup = true;
    nativeBuildInputs = [ python3 ];
    env = {
      JDK = "${jdk}";
      TRANSLATOR = "${../pizza/tools/pizza2java.py}";
    };
    buildPhase = "bash ${builders}/boot.sh ${parsers} $out";
    dontInstall = true;
    inherit meta;
  };

  pico = stdenv.mkDerivation {
    pname = "pico";
    version = "2003";
    dontUnpack = true;
    dontFixup = true;
    env.JDK = "${jdk}";
    buildPhase = ''
      bash ${builders}/stage.sh ${parsers} ${boot} build
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp -r build $out/classes
      cat > $out/bin/pico <<EOF
      #!${stdenv.shell}
      exec ${jdk}/bin/java -Xss16m -cp $out/classes jaco.pizza.Main "\$@"
      EOF
      chmod +x $out/bin/pico
    '';
    # the compiler compiles and runs a small program
    doInstallCheck = true;
    installCheckPhase = ''
      mkdir hello
      $out/bin/pico -d hello ${./tests/Hello.java} 2>&1 | tee errors.txt
      if grep -q error errors.txt; then exit 1; fi
      ${jdk}/bin/java -cp hello:$out/classes Hello | tee hello.txt
      grep -qx 'Hello from PiCo: 42' hello.txt
    '';
    inherit meta;
  };
in
{
  inherit
    src
    jcup
    parsers
    boot
    pico
    ;
  latest = pico;
}
