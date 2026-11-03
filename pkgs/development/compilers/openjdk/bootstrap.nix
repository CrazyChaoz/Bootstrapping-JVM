# The first stages of the Java bootstrap, ported from Guix'
# gnu/packages/java-bootstrap.scm:
#
#   jikes (C++) + GNU Classpath 0.93 + JamVM 1.5.1   -> a tiny JDK
#   -> ant 1.8.4, ecj 3.2.2
#   -> GNU Classpath 0.99 (for javah) -> Classpath "devel" + JamVM 2.0.0
#   -> ecj 4.2.1 (enough Java 7 for IcedTea 2)
{
  lib,
  stdenv,
  fetchurl,
  fetchgit,
  writeShellScript,
  bash,
  fastjar,
  libtool,
  pkg-config,
  libffi,
  zlib,
  zip,
  unzip,
  autoconf,
  automake,
  gettext,
  texinfo,
}:

let
  oldC = "-std=gnu89 -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=return-mismatch";

  classpathFlags = [
    "--disable-Werror"
    "--disable-gmp"
    "--disable-gtk-peer"
    "--disable-gconf-peer"
    "--disable-plugin"
    "--disable-dssi"
    "--disable-alsa"
    "--disable-gjdoc"
    "--disable-examples"
  ];

  # A javac compatible wrapper around ecj running on jamvm (replaces Guix'
  # guile script).
  mkEcjWrapper =
    {
      name,
      ecj,
      jamvm,
      classpath,
    }:
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out/bin
        cat > $out/bin/javac <<'EOF'
        #!${bash}/bin/bash
        # Defaults, unless given on the command line.
        declare -A have
        for a in "$@"; do have[$a]=1; done
        vm=() args=()
        for a in "$@"; do
          case "$a" in
            -J*) vm+=("''${a#-J}") ;;
            *) args+=("$a") ;;
          esac
        done
        defaults=()
        [ -n "''${have[-bootclasspath]:-}" ] || defaults+=(-bootclasspath "@bootcp@")
        [ -n "''${have[-source]:-}" ] || defaults+=(-source 1.5)
        [ -n "''${have[-target]:-}" ] || defaults+=(-target 1.5)
        [ -n "''${have[-cp]:-}''${have[-classpath]:-}" ] || defaults+=(-cp .)
        export CLASSPATH="@ecj@''${CLASSPATH:+:$CLASSPATH}"
        exec @java@ "''${vm[@]}" org.eclipse.jdt.internal.compiler.batch.Main -nowarn "''${defaults[@]}" "''${args[@]}"
        EOF
        substituteInPlace $out/bin/javac \
          --replace-fail @bootcp@ ${classpath}/share/classpath/glibj.zip:${classpath}/share/classpath/tools.zip \
          --replace-fail @ecj@ ${ecj}/share/java/ecj-bootstrap.jar \
          --replace-fail @java@ ${jamvm}/bin/jamvm
        chmod +x $out/bin/javac
      '';
    };
in
lib.fix (self: {
  jikes = stdenv.mkDerivation {
    pname = "jikes";
    version = "1.22";
    src = fetchurl {
      url = "https://downloads.sourceforge.net/jikes/Jikes/1.22/jikes-1.22.tar.bz2";
      hash = "sha256-DLAsdjvEQTSfbTjKzVKt92IwLM46COJp8fdfcm5uFOM=";
    };
    env.NIX_CFLAGS_COMPILE = "-std=gnu++98 -fpermissive -Wno-error";
  };

  # This is the last version of GNU Classpath that can be built without ECJ.
  classpath-bootstrap = stdenv.mkDerivation {
    pname = "classpath";
    version = "0.93";
    src = fetchurl {
      url = "mirror://gnu/classpath/classpath-0.93.tar.gz";
      hash = "sha256-3y0JNhKr0j/mfpQJ2JuyqOebFmT+Ky2kDhyO1pPjKUU=";
    };
    patches = [ ./patches/classpath-miscompilation.patch ];
    nativeBuildInputs = [
      self.jikes
      fastjar
      pkg-config
    ];
    buildInputs = [ libtool ];
    configureFlags = [
      "JAVAC=${self.jikes}/bin/jikes"
    ]
    ++ classpathFlags;
    env.NIX_CFLAGS_COMPILE = oldC;
    hardeningDisable = [ "all" ];
    postInstall = "make install-data";
    enableParallelBuilding = false;
  };

  # This is the last version of JamVM that works with a version of GNU
  # classpath that does not require ECJ.
  jamvm-1-bootstrap = stdenv.mkDerivation {
    pname = "jamvm";
    version = "1.5.1";
    src = fetchurl {
      url = "https://downloads.sourceforge.net/jamvm/jamvm/JamVM%201.5.1/jamvm-1.5.1.tar.gz";
      hash = "sha256-ZjiVvWnK86H9pq9e6oJj2Qpf01yo9MMuIhCsQQeIkBo=";
    };
    postPatch = "rm lib/classes.zip";
    nativeBuildInputs = [
      self.jikes
      zip
    ];
    buildInputs = [
      libffi
      zlib
    ];
    configureFlags = [
      "--with-classpath-install-dir=${self.classpath-bootstrap}"
      "--disable-int-caching"
      "--enable-runtime-reloc-checks"
      "--enable-ffi"
    ];
    env.NIX_CFLAGS_COMPILE = oldC;
    hardeningDisable = [ "all" ];
  };

  # The 1.8.x series is the last to use only features supported by Jikes.
  ant-bootstrap = stdenv.mkDerivation {
    pname = "ant-bootstrap";
    version = "1.8.4";
    src = fetchurl {
      url = "https://archive.apache.org/dist/ant/source/apache-ant-1.8.4-src.tar.bz2";
      hash = "sha256-XeZfe6P2fkNv//zcCnP1kdEAbp+0GvhjLB8fhNSj4LE=";
    };
    nativeBuildInputs = [
      self.jikes
      self.jamvm-1-bootstrap
      zip
      unzip
    ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export JAVA_HOME=${self.jamvm-1-bootstrap}
      export JAVACMD=${self.jamvm-1-bootstrap}/bin/jamvm
      export JAVAC=${self.jikes}/bin/jikes
      export CLASSPATH=${self.jamvm-1-bootstrap}/lib/rt.jar
      export HOME=$TMPDIR
      touch $HOME/.ant.properties
      # Use jikes instead of javac for <javac ...> tags in build.xml
      export ANT_OPTS=-Dbuild.compiler=jikes
      export BOOTJAVAC_OPTS=-nowarn
      # Without these JamVM options the build may freeze.
      sed -i 's/^"''${JAVACMD}" /"''${JAVACMD}" -Xnocompact -Xnoinlining /' bootstrap.sh
      sed -i 's/depends="jars,test-jar"/depends="jars"/' build.xml
      bash bootstrap.sh -Ddist.dir=$out
      runHook postBuild
    '';
    dontInstall = true;
  };

  # Version 3.2.2 is the last version without a dependency on a full-fledged
  # compiler for Java 1.5.
  ecj-bootstrap = stdenv.mkDerivation {
    pname = "ecj-bootstrap";
    version = "3.2.2";
    src = fetchurl {
      url = "http://archive.eclipse.org/eclipse/downloads/drops/R-3.2.2-200702121330/ecjsrc.zip";
      hash = "sha256-BwzUJfUyQ0kHPI6po6DUMWZCkmRYTanpU3iI1qdAEhY=";
    };
    nativeBuildInputs = [
      unzip
      self.jikes
      fastjar
    ];
    unpackPhase = "mkdir src; cd src; unzip -q $src";
    buildPhase = ''
      export CLASSPATH=${self.jamvm-1-bootstrap}/lib/rt.jar:$(ls ${self.ant-bootstrap}/lib/*.jar | tr '\n' ':')
      printf 'Manifest-Version: 1.0\nMain-Class: org.eclipse.jdt.internal.compiler.batch.Main\n' > manifest
      find . -name '*.java' | sort > sources
      jikes @sources
      fastjar cvfm ecj-bootstrap.jar manifest .
    '';
    installPhase = "install -Dm644 ecj-bootstrap.jar -t $out/share/java";
  };

  ecj-javac-wrapper = mkEcjWrapper {
    name = "ecj-javac-wrapper";
    ecj = self.ecj-bootstrap;
    jamvm = self.jamvm-1-bootstrap;
    classpath = self.classpath-bootstrap;
  };

  # The classpath-bootstrap was built without a virtual machine, so it does
  # not provide a wrapper for javah.  We cannot build the development version
  # of Classpath without javah.
  classpath-0_99 = stdenv.mkDerivation {
    pname = "classpath";
    version = "0.99";
    src = fetchurl {
      url = "mirror://gnu/classpath/classpath-0.99.tar.gz";
      hash = "sha256-+Skpf4rpthOhoWfiMVZoYYkyYGUdkTrZtsEZM4lf7Mg=";
    };
    nativeBuildInputs = [
      fastjar
      pkg-config
      self.jamvm-1-bootstrap
    ];
    buildInputs = [ libtool ];
    configureFlags = [
      "--with-ecj-jar=${self.ecj-bootstrap}/share/java/ecj-bootstrap.jar"
      "JAVAC=${self.ecj-javac-wrapper}/bin/javac"
      "JAVA=${self.jamvm-1-bootstrap}/bin/jamvm"
      "GCJ_JAVAC_TRUE=no"
      "ac_cv_prog_java_works=yes"
    ]
    ++ classpathFlags;
    env.NIX_CFLAGS_COMPILE = oldC;
    hardeningDisable = [ "all" ];
    postInstall = "make install-data";
  };

  # Wrappers for the tools (javah, ...) of Classpath 0.99, run on JamVM 1.
  classpath-jamvm-wrappers = stdenv.mkDerivation {
    name = "classpath-jamvm-wrappers";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      for tool in javah rmic rmid orbd rmiregistry native2ascii; do
        main=Main; [ $tool = native2ascii ] && main=Native2ASCII
        cat > $out/bin/$tool <<EOF
      #!${bash}/bin/sh
      exec ${self.jamvm-1-bootstrap}/bin/jamvm -Xnocompact -Xnoinlining -classpath ${self.classpath-0_99}/share/classpath/tools.zip gnu.classpath.tools.$tool.$main "\$@"
      EOF
        chmod +x $out/bin/$tool
      done
    '';
  };

  # The last release of GNU Classpath is 0.99 (2012); since then Classpath
  # has gained much more support for Java 1.6.
  classpath-devel = stdenv.mkDerivation {
    pname = "classpath";
    version = "0.99-1.e7c13ee0c";
    src = fetchgit {
      url = "https://git.savannah.gnu.org/git/classpath.git";
      rev = "e7c13ee0cf2005206fbec0eca677f8cf66d5a103";
      hash = "sha256-hEdXkMAcQDGK7uylusK48xk2Z1Ai6PFuFWJwbg7nWew=";
    };
    postPatch = ''
      find java -name '*.java' -exec sed -i 's/@Override//g' {} +
    '';
    preConfigure = "autoreconf -vif";
    nativeBuildInputs = [
      autoconf
      automake
      libtool
      gettext
      texinfo
      pkg-config
      fastjar
      self.classpath-jamvm-wrappers
      self.jamvm-1-bootstrap
      self.ecj-javac-wrapper
      zip
    ];
    buildInputs = [ libtool ];
    preBuild = "makeFlagsArray+=(\"JAVAC_MEM_OPT=-J-Xms512M -J-Xmx768M\")";
    configureFlags = [
      "--with-ecj-jar=${self.ecj-bootstrap}/share/java/ecj-bootstrap.jar"
      "--with-javac=${self.ecj-javac-wrapper}/bin/javac"
      "JAVA=${self.jamvm-1-bootstrap}/bin/jamvm"
      "GCJ_JAVAC_TRUE=no"
      "ac_cv_prog_java_works=yes"
    ]
    ++ classpathFlags;
    env.NIX_CFLAGS_COMPILE = oldC;
    hardeningDisable = [ "all" ];
    postInstall = "make install-data";
  };

  jamvm = stdenv.mkDerivation {
    pname = "jamvm";
    version = "2.0.0";
    src = fetchurl {
      url = "https://downloads.sourceforge.net/jamvm/jamvm/JamVM%202.0.0/jamvm-2.0.0.tar.gz";
      hash = "sha256-dkKOlt8K6d2WTHp8dMHpqDfi8xLDnpo1f6gXj37/gNo=";
    };
    patches = [
      ./patches/jamvm-2.0.0-disable-branch-patching.patch
      ./patches/jamvm-2.0.0-opcode-guard.patch
    ];
    postPatch = "rm src/classlib/gnuclasspath/lib/classes.zip";
    nativeBuildInputs = [
      self.ecj-javac-wrapper
      zip
    ];
    buildInputs = [
      libffi
      zlib
    ];
    configureFlags = [
      "--with-classpath-install-dir=${self.classpath-devel}"
      "--disable-int-caching"
      "--enable-runtime-reloc-checks"
      "--enable-ffi"
    ];
    env.NIX_CFLAGS_COMPILE = oldC;
    hardeningDisable = [ "all" ];
  };

  ecj-javac-wrapper-final = mkEcjWrapper {
    name = "ecj-javac-wrapper-final";
    ecj = self.ecj-bootstrap;
    inherit (self) jamvm;
    classpath = self.classpath-devel;
  };

  # ECJ 4.2.1, patched so that the bootstrap JDK can build it; it supports
  # enough of Java 7 to build IcedTea 2.x directly.
  ecj4-bootstrap = stdenv.mkDerivation {
    pname = "ecj-bootstrap";
    version = "4.2.1";
    src = fetchurl {
      url = "http://archive.eclipse.org/eclipse/downloads/drops4/R-4.2.1-201209141800/ecjsrc-4.2.1.jar";
      hash = "sha256-0mGyFY9ZhkDxkjgF0um/R+sh2DM/Ths39Z+EetANSPQ=";
    };
    nativeBuildInputs = [
      unzip
      zip
      self.ecj-javac-wrapper-final
    ];
    unpackPhase = "mkdir src; cd src; unzip -q $src";
    buildPhase = ''
      export CLASSPATH=${self.jamvm}/lib/rt.jar:$(ls ${self.ant-bootstrap}/lib/*.jar | tr '\n' ':')
      find . -name '*.java' -exec sed -i 's/@Override//g' {} +
      rm org/eclipse/jdt/core/JDTCompilerAdapter.java
      rm -r org/eclipse/jdt/internal/antadapter
      mkdir -p META-INF
      printf 'Manifest-Version: 1.0\nMain-Class: org.eclipse.jdt.internal.compiler.batch.Main\n' > META-INF/MANIFEST.MF
      find . -name '*.java' | sort > sources
      javac @sources
      find . -exec touch -d @1 {} +
      zip -q -0 -X ecj-bootstrap.jar META-INF/MANIFEST.MF $(find . -type f ! -name '*.java' ! -name sources ! -path ./META-INF/MANIFEST.MF | sort)
    '';
    installPhase = "install -Dm644 ecj-bootstrap.jar -t $out/share/java";
  };

  ecj4-javac-wrapper = mkEcjWrapper {
    name = "ecj4-javac-wrapper";
    ecj = self.ecj4-bootstrap;
    inherit (self) jamvm;
    classpath = self.classpath-devel;
  };

  jamvm-with-ecj4 = self.jamvm.overrideAttrs (o: {
    nativeBuildInputs = [
      self.ecj4-javac-wrapper
      zip
    ];
  });
})
