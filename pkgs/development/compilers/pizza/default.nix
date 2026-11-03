# The Pizza compiler (Odersky and Wadler's Java with generics, function types and algebraic
# data types), from source.  It is written in Pizza and only came with a binary to build
# it; here tools/pizza2java.py translates Pizza 0.40 to Java for javac (`boot`), and
# from there every release is compiled by the one before it and then by itself, which
# must give the same class files again: 0.40 → 1.0 → 1.1.  See README.md.
{
  lib,
  stdenv,
  fetchzip,
  python3,
  stripJavaArchivesHook,
  regexEdit,
  jdks,
}:

let
  # Pizza reads the class library from rt.jar, which JDK 9 and later no longer have
  jdk = jdks.openjdk8;

  sourcesOf =
    root: names:
    lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions (map (n: root + "/${n}") names);
    };
  tools = sourcesOf ./tools [ "pizza2java.py" ];
  builders = sourcesOf ./builders [
    "boot.sh"
    "stage.sh"
  ];

  # A release's source archive (pizzacompiler on SourceForge), without the binaries it
  # ships: the 1.x archives have the compiler that built them (bootstrap/pizzaself.jar),
  # an Ant task, junit and test data jars and classes.
  fetchPizza =
    {
      version,
      file,
      hash,
    }:
    fetchzip {
      name = "pizza-${version}-src";
      url = "mirror://sourceforge/pizzacompiler/pizzacompiler/${file}";
      inherit hash;
      extension = "zip";
      stripRoot = false;
      postFetch = ''
        find $out -type f \( -name '*.jar' -o -name '*.class' -o -name '*.zip' \) -delete
      '';
    };

  releases = {
    "0.40" = {
      src = fetchPizza {
        version = "0.40";
        file = "pizzacompiler%200.40/pizza-0.40-src.jar";
        hash = "sha256-3tlFILN+mb206aKpGbqXbGZ4HRoqaGm+ZP6kw2ATfn0=";
      };
      root = ".";
      main = "pizza.v40.Main";
    };
    "1.0" = {
      src = fetchPizza {
        version = "1.0";
        file = "1.0/pizza-1.0-src.zip";
        hash = "sha256-933tZvemezKUqo4h9S6R9+sFWeIXrmnzgISAX5lIF94=";
      };
      root = "pizza/main/src";
      main = "net.sf.pizzacompiler.compiler.Main";
      # the Ant task (needs Ant; build.xml compiles it separately, with javac)
      exclude = "^net/sf/pizzacompiler/ant/";
    };
    "1.1" = {
      src = fetchPizza {
        version = "1.1";
        file = "1.1/pizza-1.1-src.zip";
        hash = "sha256-ShiQx7eZGCVCTRJOHns3SlH7bQy2SyxttxSNEfDc6/Y=";
      };
      root = "pizza/main/src";
      main = "net.sf.pizzacompiler.compiler.Main";
      exclude = "^net/sf/pizzacompiler/ant/";
    };
  };

  # the sources with the patches every stage needs: the class file reader reads Java 8's
  # class library (see patches/)
  patchedSource =
    version:
    stdenv.mkDerivation {
      pname = "pizza-src-patched";
      inherit version;
      inherit (releases.${version}) src;
      patches = [ ./patches/classreader-${version}.patch ];
      dontConfigure = true;
      dontBuild = true;
      installPhase = "cp -r . $out";
      dontFixup = true;
    };

  meta = {
    homepage = "https://pizzacompiler.sourceforge.net/";
    license = lib.licenses.artistic1;
    platforms = lib.platforms.linux;
  };

  # Pizza 0.40 translated to Java and compiled by javac
  boot = stdenv.mkDerivation (finalAttrs: {
    pname = "pizza-boot";
    version = "0.40";
    src = patchedSource "0.40";
    dontConfigure = true;
    dontFixup = true;
    nativeBuildInputs = [
      python3
      regexEdit
    ];
    env = {
      JDK = "${jdk}";
      TOOLS = "${tools}";
    };
    buildPhase = ''
      runHook preBuild
      bash ${builders}/boot.sh $src $out
      runHook postBuild
    '';
    dontInstall = true;
    passthru = {
      main = "pizza.v40.Main";
      classpath = "${finalAttrs.finalPackage}/classes";
    };
    meta = meta // {
      description = "Pizza 0.40 translated to Java, the boot compiler of the Pizza bootstrap";
    };
  });

  mkPizza =
    version: prev:
    let
      r = releases.${version};
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "pizza";
      inherit version;
      src = patchedSource version;
      dontConfigure = true;
      nativeBuildInputs = [ stripJavaArchivesHook ];
      env = {
        JDK = "${jdk}";
        PREV_MAIN = prev.main;
        MAIN = r.main;
        EXCLUDE = r.exclude or "";
      };
      buildPhase = ''
        runHook preBuild
        bash ${builders}/stage.sh $src/${r.root} ${prev.classpath} build
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/java $out/bin
        ${jdk}/bin/jar cfe $out/share/java/pizza.jar ${r.main} -C build/classes .
        cat > $out/bin/pizzac <<EOF
        #!${stdenv.shell}
        exec ${jdk}/bin/java -Xss16m -cp $out/share/java/pizza.jar ${r.main} "\$@"
        EOF
        chmod +x $out/bin/pizzac
        runHook postInstall
      '';
      # the compiler compiles and runs a small program
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        mkdir hello
        $out/bin/pizzac -d hello ${./tests/Hello.pizza}
        ${jdk}/bin/java -cp hello:$out/share/java/pizza.jar Hello | tee hello.txt
        grep -qx 'Hello from Pizza: (x10 (x20 x30)), sum 6' hello.txt
        runHook postInstallCheck
      '';
      passthru = {
        inherit (r) main;
        inherit prev;
        classpath = "${finalAttrs.finalPackage}/share/java/pizza.jar";
      };
      meta = meta // {
        description = "The Pizza compiler ${version}, compiled by Pizza ${prev.version} and then by itself";
        mainProgram = "pizzac";
      };
    });

  stages = {
    "0.40" = mkPizza "0.40" boot;
    "1.0" = mkPizza "1.0" stages."0.40";
    "1.1" = mkPizza "1.1" stages."1.0";
  };
in
stages
// {
  inherit boot;
  sources = lib.mapAttrs (_: r: r.src) releases;
  latest = stages."1.1";
}
