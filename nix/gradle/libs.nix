# Third party Java libraries of the Gradle distribution, built from source
# with the JDK 21 of the chain.  Versions follow Gradle 9.8's
# gradle/dependency-management/*.toml.
#
# Sources come from the upstream git tags where the Maven/Gradle build does
# not generate code; otherwise from the Maven "-sources.jar" (which contains
# the generated sources too, e.g. Modello models).
{
  lib,
  stdenv,
  fetchurl,
  fetchzip,
  mkJar,
  classpathOf,
  jdk,
  java,
  antlr,
  regexEdit,
  ncurses,
  callPackage,
  runCommand,
  slf4jLegacy ? false, # slf4j 1.7 (Gradle 8) instead of 2.x
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };
  mvn =
    group: artifact: version: hash:
    fetchzip {
      url = "https://repo1.maven.org/maven2/${
        lib.replaceStrings [ "." ] [ "/" ] group
      }/${artifact}/${version}/${artifact}-${version}-sources.jar";
      inherit hash;
      stripRoot = false;
      extension = "zip";
    };
  # Like mkJar: Java 8 by default (-source/-target like the upstream builds,
  # `useRelease = true` to compile against the Java 8 API instead of JDK 21's),
  # module descriptors dropped, missing resource directories skipped.
  mk =
    args:
    let
      release = args.javaRelease or "8";
      sourceDirs = args.sourceDirs or [ "src" ];
      cp = classpathOf ((args.deps or [ ]) ++ (args.buildDeps or [ ]));
      target =
        if args.useRelease or false then
          "--release ${release}"
        else
          "-source ${release} -target ${release}";
    in
    mkJar (
      {
        javaRelease = release;
      }
      // removeAttrs args [
        "resourceDirs"
        "useRelease"
      ]
      // {
        postPatch = ''
          find . -name module-info.java -delete
        ''
        + (args.postPatch or "");
        buildPhase =
          args.buildPhase or ''
            runHook preBuild
            export CLASSPATH="${cp}"
            mkdir -p build/classes
            : > build/sources.txt
            for d in ${lib.escapeShellArgs sourceDirs}; do
              find "$d" -path ./build -prune -o -name '*.java' -print >> build/sources.txt
            done
            sort -o build/sources.txt build/sources.txt
            echo "compiling $(wc -l < build/sources.txt) java files"
            if [ -s build/sources.txt ]; then
              javac -d build/classes -encoding ${args.encoding or "UTF-8"} ${target} -nowarn -g -Xmaxerrs 1000 \
                -cp "$CLASSPATH" ${lib.escapeShellArgs (args.javacFlags or [ ])} @build/sources.txt
            fi
            ${lib.optionalString (args.copySourceResources or false) ''
              for d in ${lib.escapeShellArgs sourceDirs}; do
                (cd "$d" && find . -path ./build -prune -o -type f ! -name '*.java' -print0 | xargs -0 -r cp --parents -t "$OLDPWD/build/classes")
              done
            ''}
            ${lib.concatMapStrings (d: ''
              if [ -d "${d}" ]; then cp -r "${d}"/. build/classes/; fi
            '') (args.resourceDirs or [ ])}
            for j in ${lib.escapeShellArgs (args.mergeJars or [ ])}; do
              (cd build/classes && unzip -qo "$j" -x 'META-INF/MANIFEST.MF' 'META-INF/INDEX.LIST')
            done
            runHook postBuild
          '';
      }
    );
  # Maven resource filtering of ${project.version}-style placeholders.
  filterVersion = version: files: ''
    sed -i -e 's/''${project.version}/${version}/g; s/''${pom.version}/${version}/g' ${lib.concatStringsSep " " files}
  '';

  asmSrc = fetchzip {
    url = "https://gitlab.ow2.org/asm/asm/-/archive/ASM_9_10_1/asm-ASM_9_10_1.tar.gz";
    hash = "sha256-iqjqfWVIVzVLZMK6gfRMpm08vtUVo0uTFjxes5ZfUGc=";
  };
  guavaSrc = gh "google" "guava" "v33.4.6" "sha256-fN7emUqyheqzzZTHwVKmyzYUz66tOAnOsnsNFGzOwLA=";
  slf4jVersion = if slf4jLegacy then "1.7.36" else "2.0.17";
  slf4jSrc =
    if slf4jLegacy then
      gh "qos-ch" "slf4j" "v_1.7.36" "sha256-A891wuusRHJJJHDTLqKgT6sRUFZQioAk1u1tpnbWbRY="
    else
      gh "qos-ch" "slf4j" "v_2.0.17" "sha256-MOAIvzVPxFv9Nfov4Ych774urZ0v9emscKqwIGI/3Ik=";
  jackson8Src =
    gh "FasterXML" "jackson-modules-java8" "jackson-modules-java8-2.22.0"
      "sha256-zZYt5ehdX69xo1VQ6ZVQhw/3u4HMTbrOOuyvpXFkRnI=";
  # jackson's PackageVersion.java.in
  jacksonVersion =
    {
      template,
      package,
      group,
      artifact,
      version,
    }:
    ''
      pv=src/main/java/${lib.replaceStrings [ "." ] [ "/" ] package}/PackageVersion.java
      sed -e 's/@package@/${package}/g; s/@projectversion@/${version}/g' \
          -e 's/@projectgroupid@/${group}/g; s/@projectartifactid@/${artifact}/g' \
          ${template} > $pv
    '';
in
lib.fix (self: {
  inherit mk gh mvn;

  # --- annotations -------------------------------------------------------
  jspecify = mk {
    pname = "jspecify";
    version = "1.0.0";
    src = gh "jspecify" "jspecify" "v1.0.0" "sha256-WgVRaGm9lYhMeMM6QWUezXtUsXkaK/iPt1gj2koWNu8=";
    sourceDirs = [ "src/main/java" ];
  };

  jsr305 = mk {
    pname = "jsr305";
    version = "3.0.2";
    src =
      mvn "com.google.code.findbugs" "jsr305" "3.0.2"
        "sha256-JDujjNoIfofxXRpsVIoOcGtqzVR1WQSjoEM7ZydKYnc=";
    sourceDirs = [ "." ];
  };

  error-prone-annotations = mk {
    pname = "error_prone_annotations";
    version = "2.50.0";
    src = gh "google" "error-prone" "v2.50.0" "sha256-0ZlVJWTQy/bW3Iz3bo/gU9mgt0t4d8la6XbhYgM4Uy8=";
    sourceDirs = [ "annotations/src/main/java" ];
  };

  j2objc-annotations = mk {
    pname = "j2objc-annotations";
    version = "3.0.0";
    src =
      mvn "com.google.j2objc" "j2objc-annotations" "3.0.0"
        "sha256-y/3+hlFvZK4gT3SPGQmxxwIVtxQmEx+Kt6ODZ5uEbrM=";
    sourceDirs = [ "." ];
  };

  checker-qual = mk {
    pname = "checker-qual";
    version = "3.43.0";
    src =
      mvn "org.checkerframework" "checker-qual" "3.43.0"
        "sha256-jA0rTiJoi59+GnkM6+QKdMgTSpNEM7bLSQkjPn4M2LQ=";
    sourceDirs = [ "." ];
  };

  jetbrains-annotations = mk {
    pname = "annotations";
    version = "24.0.1";
    src =
      gh "JetBrains" "java-annotations" "24.0.1"
        "sha256-VupUlE0gYl+sHPmIswR/1hJzkOKEOGhJyD2LDhjg0/c=";
    sourceDirs = [
      "common/src/main/java"
      "java8/src/main/java"
    ];
  };

  javax-inject = java.javax-inject;

  # --- ASM ---------------------------------------------------------------
  asm = mk {
    pname = "asm";
    version = "9.10.1";
    src = asmSrc;
    sourceDirs = [ "asm/src/main/java" ];
  };
  # for the Kotlin compiler built here, which reads classes with an older ASM api level
  asm-lenient = mk {
    pname = "asm";
    version = "9.10.1";
    src = asmSrc;
    nativeBuildInputs = [ regexEdit ];
    postPatch = ''
      sed -i '/api < Opcodes.ASM9/,/^    }/d' asm/src/main/java/org/objectweb/asm/ClassVisitor.java
      # (the pre-release API the compiler's own ASM fork was compiled with)
      regex-edit '(  public void visitPermittedSubclass)' '  public void visitPermittedSubtypeExperimental(final String permittedSubclass) {\n    visitPermittedSubclass(permittedSubclass);\n  }\n\n\1' asm/src/main/java/org/objectweb/asm/ClassVisitor.java
    '';
    sourceDirs = [ "asm/src/main/java" ];
  };
  asm-tree = mk {
    pname = "asm-tree";
    version = "9.10.1";
    src = asmSrc;
    sourceDirs = [ "asm-tree/src/main/java" ];
    deps = [ self.asm ];
  };
  asm-analysis = mk {
    pname = "asm-analysis";
    version = "9.10.1";
    src = asmSrc;
    sourceDirs = [ "asm-analysis/src/main/java" ];
    deps = [ self.asm-tree ];
  };
  asm-commons = mk {
    pname = "asm-commons";
    version = "9.10.1";
    src = asmSrc;
    sourceDirs = [ "asm-commons/src/main/java" ];
    deps = [
      self.asm-tree
      self.asm-analysis
    ];
  };
  asm-util = mk {
    pname = "asm-util";
    version = "9.10.1";
    src = asmSrc;
    sourceDirs = [ "asm-util/src/main/java" ];
    deps = [
      self.asm-tree
      self.asm-analysis
    ];
  };

  # --- Guava -------------------------------------------------------------
  failureaccess = mk {
    pname = "failureaccess";
    version = "1.0.3";
    src = guavaSrc;
    sourceDirs = [ "futures/failureaccess/src" ];
  };

  guava = mk {
    pname = "guava";
    version = "33.4.6-jre";
    src = guavaSrc;
    sourceDirs = [ "guava/src" ];
    deps = [
      self.failureaccess
      self.jspecify
    ];
    buildDeps = [
      self.error-prone-annotations
      self.j2objc-annotations
      self.checker-qual
      self.jsr305
    ];
  };

  # --- Apache Commons ----------------------------------------------------
  commons-io = mk {
    pname = "commons-io";
    version = "2.20.0";
    src =
      gh "apache" "commons-io" "rel/commons-io-2.20.0"
        "sha256-fzfrmR0LhFihXe0TdEO3M4EIR0MxJw0AwhiSWRC6PVs=";
    sourceDirs = [ "src/main/java" ];
  };

  commons-lang3 = mk {
    pname = "commons-lang3";
    version = "3.20.0";
    src =
      gh "apache" "commons-lang" "rel/commons-lang-3.20.0"
        "sha256-6FivHu4P6fJ1cDABHLt6TXM3PJ08W/73KwPiPa5RONA=";
    sourceDirs = [ "src/main/java" ];
  };

  commons-lang2 = mk {
    pname = "commons-lang";
    useRelease = true;
    postPatch = "rm -r org/apache/commons/lang/enum"; # (a deprecated package named like a keyword)
    encoding = "ISO-8859-1";
    version = "2.6";
    src = mvn "commons-lang" "commons-lang" "2.6" "sha256-abXn7fXqF2nnwabMIjYM/IjZV/EmmKz+SL7OjbyK2jo=";
    sourceDirs = [ "." ];
  };

  commons-codec = mk {
    pname = "commons-codec";
    version = "1.18.0";
    src =
      gh "apache" "commons-codec" "rel/commons-codec-1.18.0"
        "sha256-bJCwxDn4fnEFJRZFcCPrZXJS7/UcNj10yNV/kd1Pq4w=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
  };

  xz = mk {
    pname = "xz";
    version = "1.10";
    src = gh "tukaani-project" "xz-java" "v1.10" "sha256-vW0C4QrRY0VBIpbWKEGVGfgsxg7MyFU++VLnbbKUb+c=";
    postPatch = "find src -maxdepth 1 -name '*.java' -delete";
    sourceDirs = [ "src" ];
  };

  commons-compress = mk {
    pname = "commons-compress";
    version = "1.28.0";
    src =
      gh "apache" "commons-compress" "rel/commons-compress-1.28.0"
        "sha256-7nv1Vp/WMn5H2/P0FaoyQgzu+wWdOogztEJlORD8wDA=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [
      self.commons-io
      self.commons-lang3
      self.commons-codec
    ];
    buildDeps = [
      self.xz
      java.brotli-dec
      self.zstd-stub
      self.asm
    ];
  };

  # Compile-time only (zstd-jni is a JNI library).
  zstd-stub = mk {
    pname = "zstd-stub";
    src = ./zstd-stub;
    sourceDirs = [ "." ];
  };

  # --- HTTP --------------------------------------------------------------
  httpcore = mk {
    pname = "httpcore";
    version = "4.4.16";
    src =
      gh "apache" "httpcomponents-core" "rel/v4.4.16"
        "sha256-2Fk8UnvEJDI95AV/92N3Jzg6MMHZdyRHQXsbpRq+Td4=";
    sourceDirs = [
      "httpcore/src/main/java"
      "httpcore/src/main/java-deprecated"
    ];
    resourceDirs = [ "httpcore/src/main/resources" ];
    preBuild = filterVersion "4.4.16" [
      "httpcore/src/main/resources/org/apache/http/version.properties"
    ];
  };

  httpclient = mk {
    pname = "httpclient";
    version = "4.5.14";
    src =
      gh "apache" "httpcomponents-client" "rel/v4.5.14"
        "sha256-WrOA/EQ+Y3HWkYXQgiEdTcfYyZ+16aIJ0HCwiYISxEY=";
    sourceDirs = [
      "httpclient/src/main/java"
      "httpclient/src/main/java-deprecated"
    ];
    resourceDirs = [ "httpclient/src/main/resources" ];
    preBuild = filterVersion "4.5.14" [
      "httpclient/src/main/resources/org/apache/http/client/version.properties"
    ];
    deps = [
      self.httpcore
      self.commons-codec
      self.jcl-over-slf4j
    ];
  };

  # --- logging -----------------------------------------------------------
  slf4j-api = mk (
    {
      pname = "slf4j-api";
      version = slf4jVersion;
      src = slf4jSrc;
      sourceDirs = [ "slf4j-api/src/main/java" ];
      resourceDirs = [ "slf4j-api/src/main/resources" ];
    }
    // lib.optionalAttrs slf4jLegacy { postBuild = "rm -rf build/classes/org/slf4j/impl"; }
  );
  jcl-over-slf4j = mk {
    pname = "jcl-over-slf4j";
    version = slf4jVersion;
    src = slf4jSrc;
    sourceDirs = [ "jcl-over-slf4j/src/main/java" ];
    resourceDirs = [ "jcl-over-slf4j/src/main/resources" ];
    deps = [ self.slf4j-api ];
  };
  jul-to-slf4j = mk {
    pname = "jul-to-slf4j";
    version = slf4jVersion;
    src = slf4jSrc;
    sourceDirs = [ "jul-to-slf4j/src/main/java" ];
    deps = [ self.slf4j-api ];
  };
  log4j-over-slf4j = mk {
    pname = "log4j-over-slf4j";
    version = slf4jVersion;
    src = slf4jSrc;
    sourceDirs = [ "log4j-over-slf4j/src/main/java" ];
    resourceDirs = [ "log4j-over-slf4j/src/main/resources" ];
    deps = [ self.slf4j-api ];
  };

  # --- batch 3 -----------------------------------------------------------
  tomlj = mk {
    pname = "tomlj";
    version = "1.0.0";
    src = gh "tomlj" "tomlj" "refs/tags/1.0.0" "sha256-vmX2d66S/jIqSMojFYZT6v5AF5HS1VKkkqdroPeb6GQ=";
    nativeBuildInputs = [ self.antlr4 ];
    preBuild = ''
      mkdir -p gen/org/tomlj/internal
      (cd src/main/antlr/org/tomlj/internal && antlr4 -visitor -no-listener \
        -o $OLDPWD/gen/org/tomlj/internal TomlLexer.g4 TomlParser.g4)
      rm -f gen/org/tomlj/internal/*.tokens gen/org/tomlj/internal/*.interp
    '';
    sourceDirs = [
      "src/main/java"
      "gen"
    ];
    deps = [
      self.antlr4-runtime
      self.checker-qual
      self.jsr305
    ];
  };
  antlr2 = mk {
    pname = "antlr";
    version = "2.7.7";
    src = fetchzip {
      url = "https://www.antlr2.org/download/antlr-2.7.7.tar.gz";
      hash = "sha256-jOg8Eg4ZBG6kTht9m0HRbmIa63aJCbF3FeJSVpbgK1k=";
    };
    sourceDirs = [ "antlr" ];
  };
  jsch = mk {
    pname = "jsch";
    version = "0.2.16";
    src = mvn "com.github.mwiede" "jsch" "0.2.16" "sha256-hlYwvTDC/oynWhRNtQoTGUTI/nCtgjBsE/O6AbXHPFo=";
    sourceDirs = [ "." ];
    useRelease = true;
    nativeBuildInputs = [ regexEdit ];
    postPatch = ''
      rm -rf META-INF/versions com/jcraft/jsch/JUnixSocketFactory.java com/jcraft/jsch/Log4j2Logger.java com/jcraft/jsch/PageantConnector.java
      regex-edit '(?s)try \{\s*return new JUnixSocketFactory\(\);.*?\n      \}\n    \}\n  \}' 'throw e;\n    }\n  }' com/jcraft/jsch/SSHAgentConnector.java
    '';
    deps = [
      self.slf4j-api
      self.bcprov
    ];
    copySourceResources = true;
  };
  plexus-classworlds = mk {
    pname = "plexus-classworlds";
    version = "2.7.0";
    src =
      mvn "org.codehaus.plexus" "plexus-classworlds" "2.7.0"
        "sha256-sGoU/WKD8Q49Hp97ys1WybTThZ4v0+tTzMM8DLrdG0c=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  maven-artifact = mk {
    pname = "maven-artifact";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-artifact" "3.9.5"
        "sha256-9AGscnM6IuVDCsWiZje75/zwQectE+QztcKSCJ2OmfY=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.plexus-utils
      self.commons-lang3
    ];
  };
  maven-resolver-api = mk {
    pname = "maven-resolver-api";
    version = "1.9.16";
    src =
      mvn "org.apache.maven.resolver" "maven-resolver-api" "1.9.16"
        "sha256-YTNkIZcaYnOPXIGf17vXKylFUwz+xI1yvFra7zmnK5E=";
    sourceDirs = [ "." ];
  };
  maven-plugin-api = mk {
    pname = "maven-plugin-api";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-plugin-api" "3.9.5"
        "sha256-Zd97QLplbZgYZAodKzjdUqVmSx+SPYAHLkCdrMvQXLc=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.maven-model
      self.maven-artifact
      self.plexus-utils
      self.javax-inject
    ];
  };

  # --- batch 4: git and ssh -----------------------------------------------
  javaewah = mk {
    pname = "JavaEWAH";
    version = "1.2.3";
    src =
      mvn "com.googlecode.javaewah" "JavaEWAH" "1.2.3"
        "sha256-kTNsFoaEFFQo3jAfPS5dWaXwP+JfniEzhI4P8Yr6h00=";
    sourceDirs = [ "." ];
  };
  jgit = mk {
    pname = "org.eclipse.jgit";
    version = "7.2.1.202505142326-r";
    src =
      mvn "org.eclipse.jgit" "org.eclipse.jgit" "7.2.1.202505142326-r"
        "sha256-3oiAwcD2B2zoPBewtnEbpcL8G9UkPgjKpfJ0+rcL2Pg=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    javaRelease = "17";
    deps = [
      self.slf4j-api
      self.javaewah
      self.commons-codec
    ];
  };
  sshd-osgi = mk {
    pname = "sshd-osgi";
    version = "2.15.0";
    postPatch = "rm -rf org/apache/sshd/agent/unix org/apache/sshd/agent/local/ProxyAgentFactory.java";
    src =
      mvn "org.apache.sshd" "sshd-osgi" "2.15.0"
        "sha256-xb0F6cqM5GsZiGS39cVoUo5d4DkMxktyHXwecsrwO9A=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.slf4j-api
      self.bcprov
      self.bcutil
      self.bcpkix
      self.eddsa
    ];
  };
  eddsa = mk {
    pname = "eddsa";
    version = "0.3.0";
    src = mvn "net.i2p.crypto" "eddsa" "0.3.0" "sha256-5vovDtZjNPL3M8j9pteZatYb9xEWzDiUQC2s/SXJpL4=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  bcpkix = mk {
    pname = "bcpkix-jdk18on";
    version = "1.85";
    postPatch = "rm -rf META-INF/versions";
    src =
      mvn "org.bouncycastle" "bcpkix-jdk18on" "1.85"
        "sha256-F1Cm5fRK3Tu0qpOmZ8Mra54f27/77Os8I4fsqv0CeDw=";
    sourceDirs = [ "." ];
    deps = [
      self.bcprov
      self.bcutil
    ];
  };
  sshd-sftp = mk {
    pname = "sshd-sftp";
    version = "2.15.0";
    src =
      mvn "org.apache.sshd" "sshd-sftp" "2.15.0"
        "sha256-Tc0GeiOeqng5zgys8u5FDHK0S2icO9Z28OsQCYHRcs8=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.slf4j-api
      self.sshd-osgi
    ];
  };
  jgit-ssh-apache = mk {
    pname = "org.eclipse.jgit.ssh.apache";
    version = "7.2.1.202505142326-r";
    src =
      mvn "org.eclipse.jgit" "org.eclipse.jgit.ssh.apache" "7.2.1.202505142326-r"
        "sha256-dZNJiujVQ2bnFuTuDYvlVftRYkqwoX0Cvw5kYJdu4Xs=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    javaRelease = "17";
    deps = [
      self.slf4j-api
      self.jgit
      self.sshd-osgi
      self.sshd-sftp
    ];
  };

  # --- misc --------------------------------------------------------------
  gson = mk {
    pname = "gson";
    version = "2.13.1";
    src = gh "google" "gson" "gson-parent-2.13.1" "sha256-D+CjEE5ZCIJ1+93lGPlg7vlZdbpiscNBb+Q0hZG0Nwg=";
    sourceDirs = [ "gson/src/main/java" ];
    preBuild = ''
      sed 's/''${project.version}/2.13.1/' gson/src/main/java-templates/com/google/gson/internal/GsonBuildConfig.java \
        > gson/src/main/java/com/google/gson/internal/GsonBuildConfig.java
    '';
    buildDeps = [ self.error-prone-annotations ];
  };

  objenesis = mk {
    pname = "objenesis";
    version = "2.6";
    src = gh "easymock" "objenesis" "2.6" "sha256-OLyBYJWhI9o0h9hIq11nTMRdyMSYWpS8Zo08In4rSJY=";
    # Unsafe.defineClass is gone since JDK 11 (objenesis uses it on JDK 8 only)
    postPatch = ''
      substituteInPlace main/src/main/java/org/objenesis/instantiator/util/ClassDefinitionUtils.java \
        --replace-fail "UnsafeUtils.getUnsafe().defineClass(className, b, 0, b.length, loader, PROTECTION_DOMAIN)" \
          "invokeDefineClass(className, b, loader)"
      substituteInPlace main/src/main/java/org/objenesis/instantiator/util/ClassDefinitionUtils.java \
        --replace-fail "   private ClassDefinitionUtils() { }" \
          "   private ClassDefinitionUtils() { }
         private static Object invokeDefineClass(String n, byte[] b, ClassLoader l) {
            try {
               return sun.misc.Unsafe.class.getMethod(\"defineClass\", String.class, byte[].class, int.class, int.class, ClassLoader.class, ProtectionDomain.class)
                  .invoke(UnsafeUtils.getUnsafe(), n, b, 0, b.length, l, PROTECTION_DOMAIN);
            } catch (Exception e) { throw new RuntimeException(e); }
         }"
    '';
    sourceDirs = [ "main/src/main/java" ];
  };

  minlog = mk {
    pname = "minlog";
    version = "1.2";
    src = gh "EsotericSoftware" "minlog" "1.2" "sha256-t6449TameMGZ76ikrimiQ+dAxDnSclaAQJVvfIwZvNg=";
    sourceDirs = [ "src" ];
  };

  # shaded into kryo upstream
  reflectasm = mk {
    pname = "reflectasm";
    version = "1.09";
    src =
      mvn "com.esotericsoftware.reflectasm" "reflectasm" "1.09"
        "sha256-i1RT+swQaiHAptorotQH41v1HVcP1VDbm792gtq8mVQ=";
    sourceDirs = [ "." ];
    buildDeps = [ self.asm ];
  };

  kryo = mk {
    pname = "kryo";
    version = "2.24.0";
    src =
      gh "EsotericSoftware" "kryo" "kryo-2.24.0"
        "sha256-fW2eZNF6iL+lnkRXGJhHQMJa9aPyM8doGoFQcNgX23M=";
    sourceDirs = [ "src" ];
    deps = [
      self.minlog
      self.objenesis
    ];
    # sun.misc.Cleaner is gone since JDK 9
    nativeBuildInputs = [ regexEdit ];
    postPatch = ''
      f=src/com/esotericsoftware/kryo/util/UnsafeUtil.java
      sed -i -e '/^import sun.misc.Cleaner;/d' -e '/^import sun.nio.ch.DirectBuffer;/d' $f
      regex-edit 'Object cleaner = \(\(DirectBuffer\) niobuffer\).cleaner\(\);\s*if\(cleaner != null\)\s*\(\(Cleaner\)cleaner\).clean\(\);' 'try { Object cleaner = niobuffer.getClass().getMethod("cleaner").invoke(niobuffer); if (cleaner != null) cleaner.getClass().getMethod("clean").invoke(cleaner); } catch (Exception e) { }' $f
      grep -q 'getMethod("clean")' $f
    '';
    buildDeps = [ self.reflectasm ];
    mergeJars = [ "${self.reflectasm}/share/java/reflectasm.jar" ];
  };

  jctools-core = mk {
    pname = "jctools-core";
    version = "4.0.5";
    src = gh "JCTools" "JCTools" "v4.0.5" "sha256-698Fa9DafOr9ai8UQLlV5Ag/y9PA7AzveNq97x8vePs=";
    # OSGi bundle annotations
    postPatch = "find jctools-core/src/main -name package-info.java -delete";
    sourceDirs = [ "jctools-core/src/main/java" ];
  };

  jnr-constants = mk {
    pname = "jnr-constants";
    version = "0.10.4";
    src =
      gh "jnr" "jnr-constants" "jnr-constants-0.10.4"
        "sha256-leMxtrWU30/y+9WIhkQlImjYmzdAF4ptoMKLZMxVDJM=";
    sourceDirs = [ "src/main/java" ];
  };

  jcifs = mk {
    pname = "jcifs";
    version = "1.3.17";
    src = fetchzip {
      url = "https://repo1.maven.org/maven2/jcifs/jcifs/1.3.17/jcifs-1.3.17-sources.jar";
      stripRoot = false;
      extension = "zip";
      hash = "sha256-QrLVQF8NzFPMP4jPwqrMjN7h9s7abTEW7XvGSTSNe04=";
    };
    # jcifs.http needs the servlet API
    postPatch = "rm -rf jcifs/http jcifs/https";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };

  jatl = mk {
    pname = "jatl";
    version = "0.2.3";
    src =
      mvn "com.googlecode.jatl" "jatl" "0.2.3"
        "sha256-WOUU6BlcycSM5mbLmDD5vDR21L7W0LHchcXLpyzisLg=";
    sourceDirs = [ "." ];
  };

  javapoet = mk {
    pname = "javapoet";
    version = "1.13.0";
    src =
      gh "square" "javapoet" "javapoet-1.13.0"
        "sha256-Pj28ZTJFi9WB5Qnl8XIrSkRkzdA4De0o4vL9Ww9XjuA=";
    sourceDirs = [ "src/main/java" ];
  };

  # --- Jackson -----------------------------------------------------------
  jackson-annotations = mk {
    pname = "jackson-annotations";
    version = "2.22";
    src =
      gh "FasterXML" "jackson-annotations" "jackson-annotations-2.22"
        "sha256-nos0/g7RKc5RZtl36nLjPY7o2zssdJxVqP/NOeha2Hg=";
    sourceDirs = [ "src/main/java" ];
  };

  fastdoubleparser = mk {
    pname = "fastdoubleparser";
    version = "2.0.1";
    src =
      gh "wrandelshofer" "FastDoubleParser" "v2.0.1"
        "sha256-o80akZwUit5QdqF7SG64ENJhTFcKeHQBJY6SifjeLiY=";
    # the Java 8 flavour: the dev sources with a few classes replaced
    preBuild = ''
      mkdir java8
      cp -r fastdoubleparser-dev/src/main/java/ch.randelshofer.fastdoubleparser/. java8/
      cp -r fastdoubleparser-java8/src/main/java/ch.randelshofer.fastdoubleparser/. java8/
      rm -f java8/ch/randelshofer/fastdoubleparser/{FastDoubleVector,Decimal}.java
    '';
    sourceDirs = [ "java8" ];
  };

  jackson-core = mk {
    pname = "jackson-core";
    version = "2.22.0";
    src =
      gh "FasterXML" "jackson-core" "jackson-core-2.22.0"
        "sha256-52pW647+IDXZdW0uPq1YMiA8cHfVXvaoy+6cRMWTXAA=";
    preBuild = jacksonVersion {
      template = "src/main/java/com/fasterxml/jackson/core/json/PackageVersion.java.in";
      package = "com.fasterxml.jackson.core.json";
      group = "com.fasterxml.jackson.core";
      artifact = "jackson-core";
      version = "2.22.0";
    };
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    # shaded upstream
    buildDeps = [ self.fastdoubleparser ];
    mergeJars = [ "${self.fastdoubleparser}/share/java/fastdoubleparser.jar" ];
  };

  jackson-databind = mk {
    pname = "jackson-databind";
    version = "2.22.0";
    src =
      gh "FasterXML" "jackson-databind" "jackson-databind-2.22.0"
        "sha256-tPE+Ye/GZdXocQqkye8qjjAUE0kG8fThAWyCQOBdGTM=";
    preBuild = jacksonVersion {
      template = "src/main/java/com/fasterxml/jackson/databind/cfg/PackageVersion.java.in";
      package = "com.fasterxml.jackson.databind.cfg";
      group = "com.fasterxml.jackson.core";
      artifact = "jackson-databind";
      version = "2.22.0";
    };
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [
      self.jackson-core
      self.jackson-annotations
    ];
  };

  jackson-datatype-jdk8 = mk {
    pname = "jackson-datatype-jdk8";
    version = "2.22.0";
    src = jackson8Src;
    preBuild =
      "cd datatypes\n"
      + jacksonVersion {
        template = "src/main/java/com/fasterxml/jackson/datatype/jdk8/PackageVersion.java.in";
        package = "com.fasterxml.jackson.datatype.jdk8";
        group = "com.fasterxml.jackson.datatype";
        artifact = "jackson-datatype-jdk8";
        version = "2.22.0";
      };
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [ self.jackson-databind ];
  };

  jackson-datatype-jsr310 = mk {
    pname = "jackson-datatype-jsr310";
    version = "2.22.0";
    src = jackson8Src;
    preBuild =
      "cd datetime\n"
      + jacksonVersion {
        template = "src/main/java/com/fasterxml/jackson/datatype/jsr310/PackageVersion.java.in";
        package = "com.fasterxml.jackson.datatype.jsr310";
        group = "com.fasterxml.jackson.datatype";
        artifact = "jackson-datatype-jsr310";
        version = "2.22.0";
      };
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [ self.jackson-databind ];
  };
  # --- JNI libraries -----------------------------------------------------
  # The Java classes plus the Linux x86_64 shared libraries, built with gcc
  # instead of the Gradle C++ plugin / zig; javac -h writes the JNI headers.
  native-platform = stdenv.mkDerivation {
    pname = "native-platform";
    version = "0.22-milestone-29";
    src =
      gh "gradle" "native-platform" "0.22-milestone-29"
        "sha256-HNVA6QDiPPKh0BQpCBjwiv4LNYxDySlqXcZjYC+FdFo=";
    nativeBuildInputs = [ jdk ];
    buildInputs = [ ncurses ];
    buildPhase = ''
      cd native-platform
      v=nix-0.22-milestone-29
      mkdir -p gen/java/net/rubygrapefruit/platform/internal/jni gen/headers classes
      printf 'package net.rubygrapefruit.platform.internal.jni;\npublic interface NativeVersion {\n    String VERSION = "%s";\n}\n' $v \
        > gen/java/net/rubygrapefruit/platform/internal/jni/NativeVersion.java
      printf '#ifndef __INCLUDE_NATIVE_PLATFORM_VERSION_H__\n#define __INCLUDE_NATIVE_PLATFORM_VERSION_H__\n#define NATIVE_VERSION "%s"\n#endif\n' $v \
        > gen/headers/native_platform_version.h
      find src/main/java gen/java -name '*.java' > sources
      javac -nowarn -source 8 -target 8 -encoding UTF-8 -cp ${self.jsr305}/share/java/jsr305.jar \
        -d classes -h gen/headers @sources
      cflags="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I${jdk.home}/include -I${jdk.home}/include/linux -Igen/headers -Isrc/shared/headers"
      mkdir -p native/net/rubygrapefruit/platform/linux-amd64 native-curses/net/rubygrapefruit/platform/linux-amd64-ncurses6
      g++ $cflags -shared -o native/net/rubygrapefruit/platform/linux-amd64/libnative-platform.so \
        src/shared/cpp/*.cpp src/main/cpp/*.cpp
      g++ $cflags -shared -o native-curses/net/rubygrapefruit/platform/linux-amd64-ncurses6/libnative-platform-curses.so \
        src/shared/cpp/*.cpp src/curses/cpp/*.cpp -lncursesw
    '';
    installPhase = ''
      mkdir -p $out/share/java
      jar cf $out/share/java/native-platform.jar -C classes .
      jar cf $out/share/java/native-platform-linux-amd64.jar -C native .
      jar cf $out/share/java/native-platform-linux-amd64-ncurses6.jar -C native-curses .
    '';
  };

  gradle-fileevents = stdenv.mkDerivation {
    pname = "gradle-fileevents";
    version = "0.2.8";
    src = gh "gradle" "gradle-fileevents" "0.2.8" "sha256-FELiaSgFVrCJgAGy7Xp7Lwmh7BK0VZL5Y49n6BCHFBU=";
    nativeBuildInputs = [ jdk ];
    buildPhase = ''
      v=nix-0.2.8
      mkdir -p gen/java/org/gradle/fileevents/internal gen/headers classes/net/rubygrapefruit/platform/x86_64-linux-gnu
      printf 'package org.gradle.fileevents.internal;\npublic class FileEventsVersion {\n    public static final String VERSION = "%s";\n}\n' $v \
        > gen/java/org/gradle/fileevents/internal/FileEventsVersion.java
      printf '#define FILE_EVENTS_VERSION "%s"\n' $v > gen/headers/fileevents_version.h
      find src/main/java gen/java -name '*.java' > sources
      javac -nowarn -source 8 -target 8 -encoding UTF-8 \
        -cp ${self.jsr305}/share/java/jsr305.jar:${self.native-platform}/share/java/native-platform.jar:${self.slf4j-api}/share/java/slf4j-api.jar \
        -d classes -h gen/headers @sources
      g++ --std=c++17 -O2 -fPIC -shared -I${jdk.home}/include -I${jdk.home}/include/linux -Igen/headers -Isrc/main/headers \
        -o classes/net/rubygrapefruit/platform/x86_64-linux-gnu/libgradle-fileevents.so src/main/cpp/*.cpp
    '';
    installPhase = ''
      mkdir -p $out/share/java
      jar cf $out/share/java/gradle-fileevents.jar -C classes .
    '';
    passthru.javaDeps = [
      self.native-platform
      self.slf4j-api
    ];
  };

  jansi = stdenv.mkDerivation {
    pname = "jansi";
    version = "2.4.2";
    src = gh "fusesource" "jansi" "jansi-2.4.2" "sha256-D7mMLtkOuh4p7wmCLCXalG9pieNCdHPWk4e7z1j5MQ4=";
    nativeBuildInputs = [ jdk ];
    buildPhase = ''
      # drop the prebuilt libraries
      rm -rf src/main/resources/org/fusesource/jansi/internal/native
      mkdir -p classes
      cp -r src/main/resources/. classes/
      sed -i 's/''${project.version}/2.4.2/' classes/org/fusesource/jansi/jansi.properties
      find src/main/java -name '*.java' ! -name module-info.java > sources
      javac -nowarn -source 8 -target 8 -encoding UTF-8 -d classes @sources
      d=classes/org/fusesource/jansi/internal/native/Linux/x86_64
      mkdir -p $d
      gcc -Os -fPIC -fvisibility=hidden -I${jdk.home}/include -I${jdk.home}/include/linux -Isrc/main/native \
        -shared -o $d/libjansi.so src/main/native/*.c -lutil
    '';
    installPhase = ''
      mkdir -p $out/share/java
      jar cf $out/share/java/jansi.jar -C classes .
    '';
  };
  # jansi 1.18 (Gradle 8): with the Java parts of jansi-native and hawtjni-runtime (as the shaded jar has them),
  # without the JNI library
  jansi118 = mk {
    pname = "jansi";
    version = "1.18";
    src = runCommand "jansi-1.18-src" { } ''
      mkdir $out
      cp -r ${
        gh "fusesource" "jansi" "jansi-project-1.18" "sha256-WmsC2Dczc+hSzKRTcyRgDi9XPZ00c5YJCnz+WMQtJbE="
      }/jansi/src/main/java $out/jansi
      chmod -R u+w $out
      cp -r ${
        gh "fusesource" "jansi-native" "jansi-native-1.8"
          "sha256-s2H9HCvWoC+p7kbQkLV+47DKcE+8OU20E0eH7sHxPsI="
      }/src/main/java $out/native
      cp -r ${
        gh "fusesource" "hawtjni" "hawtjni-project-1.17"
          "sha256-2w/wamZfHEjEDFp/AYj3qMyFLupC9Z8yogNnNiFk5jI="
      }/hawtjni-runtime/src/main/java $out/hawtjni
    '';
    sourceDirs = [
      "jansi"
      "native"
      "hawtjni"
    ];
  };
  jsoup = mk {
    pname = "jsoup";
    version = "1.15.3";
    src = gh "jhy" "jsoup" "jsoup-1.15.3" "sha256-aY+ORveoiBRBkdG0pRrRc2xQuj9WH3z8rROjEQQv4+Y=";
    deps = [ self.jsr305 ];
    sourceDirs = [ "src/main/java" ];
  };

  # --- build tools -------------------------------------------------------
  ant = callPackage ../java/ant.nix {
    inherit jdk;
    version = "1.10.17";
    hash = "sha256-8DkKXO4Qdgd/mtuP7d2ZMx/rpKmIfzN5mSuLaye+ZFw=";
  };

  oro = mk {
    pname = "oro";
    version = "2.0.8";
    src = mvn "oro" "oro" "2.0.8" "sha256-+XfMzcf77NcWzewnc9VckYT+7BwUJ/sopg04pfUb9Zc=";
    sourceDirs = [ "." ];
  };
  ivy = mk {
    pname = "ivy";
    version = "2.5.3";
    src = fetchurl {
      url = "https://archive.apache.org/dist/ant/ivy/2.5.3/apache-ivy-2.5.3-src.tar.gz";
      hash = "sha256-KTyThYsjJ8U9R0oZ/rO+sGUnBe7wYKTbY+ELUUld6i4=";
    };
    # repository/signer plugins needing third party libraries are dropped
    postPatch = ''
      rm -rf src/example
      cd src/java/org/apache/ivy
      rm -rf plugins/repository/vfs plugins/repository/ssh plugins/repository/sftp \
             plugins/resolver/VfsResolver.java plugins/resolver/SshResolver.java \
             plugins/resolver/SFTPResolver.java plugins/resolver/AbstractSshBasedResolver.java \
             plugins/signer/bouncycastle
      cd -
      grep -rlE 'import (org\.apache\.commons\.(httpclient|vfs)|org\.apache\.http|com\.jcraft|org\.bouncycastle)' src/java | xargs -r rm -v
    '';
    sourceDirs = [ "src/java" ];
    copySourceResources = true;
    useRelease = true; # java.util.jar.Pack200
    deps = [
      self.ant
      self.oro
    ];
  };

  # --- crypto ------------------------------------------------------------
  bcprov = mk {
    pname = "bcprov-jdk18on";
    version = "1.85";
    # multi-release extras (Java 9+ variants of some classes)
    postPatch = "rm -rf META-INF/versions";
    src =
      mvn "org.bouncycastle" "bcprov-jdk18on" "1.85"
        "sha256-HiI4dcHwCHdPGrzREHXOiNXulv3QD2MvFneHGQlhQd4=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  bcutil = mk {
    pname = "bcutil-jdk18on";
    version = "1.85";
    postPatch = "rm -rf META-INF/versions";
    src =
      mvn "org.bouncycastle" "bcutil-jdk18on" "1.85"
        "sha256-+BobUZ3LeTENY4DSPpEikqJRVYMmjTmI0houVrzOzaw=";
    sourceDirs = [ "." ];
    deps = [ self.bcprov ];
  };
  bcpg = mk {
    pname = "bcpg-jdk18on";
    version = "1.85";
    postPatch = "rm -rf META-INF/versions";
    src =
      mvn "org.bouncycastle" "bcpg-jdk18on" "1.85"
        "sha256-pspoKvNrHz9bWAGpbZdrtgI5h8xaFM0cjp8x+fqu6+8=";
    sourceDirs = [ "." ];
    deps = [
      self.bcprov
      self.bcutil
    ];
  };

  # --- Maven / Plexus ----------------------------------------------------
  plexus-utils = mk {
    pname = "plexus-utils";
    version = "3.6.1";
    src =
      gh "codehaus-plexus" "plexus-utils" "plexus-utils-3.6.1"
        "sha256-xOIdnUzG2qNsuiHmLOY3eZMdNIvgyoZjy3dokg6Jh1s=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
  };
  plexus-interpolation = mk {
    pname = "plexus-interpolation";
    version = "1.26";
    src =
      gh "codehaus-plexus" "plexus-interpolation" "plexus-interpolation-1.26"
        "sha256-kP7uahc6j+AGmKm6pcJpbHuufkyMfixGLc047mGVUOU=";
    sourceDirs = [ "src/main/java" ];
  };
  plexus-cipher = mk {
    pname = "plexus-cipher";
    version = "2.0";
    # sisu's @Typed is only a hint for the DI container
    postPatch = "sed -i -e '/^import org.eclipse.sisu.Typed;/d' -e 's/^@Typed.*//' org/sonatype/plexus/components/cipher/DefaultPlexusCipher.java";
    src =
      mvn "org.codehaus.plexus" "plexus-cipher" "2.0"
        "sha256-ZcdbhITWv4AcvPS0lfLMMNHxqusHikBLmze/imMMYhU=";
    sourceDirs = [ "." ];
    deps = [ self.javax-inject ];
  };
  plexus-sec-dispatcher = mk {
    pname = "plexus-sec-dispatcher";
    version = "2.0";
    src =
      mvn "org.codehaus.plexus" "plexus-sec-dispatcher" "2.0"
        "sha256-Xb+PNTL+ou4fRBZPIyzHpdfISIZGcJnoKwyFO71hI7Y=";
    sourceDirs = [ "." ];
    deps = [
      self.plexus-cipher
      self.plexus-utils
      self.javax-inject
    ];
  };
  maven-model = mk {
    pname = "maven-model";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-model" "3.9.5"
        "sha256-PGlrUqhc0oackZg5TsrGpRxJwFCMj5D8jnNH8oA3m/Y=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-utils ];
  };
  maven-settings = mk {
    pname = "maven-settings";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-settings" "3.9.5"
        "sha256-7aSMu02mIVw2aDp+kmDOWbIGolhtZuw2X2KTP1q4+RI=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-utils ];
  };
  maven-builder-support = mk {
    pname = "maven-builder-support";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-builder-support" "3.9.5"
        "sha256-+DjTFKPeMQPcsXVPoGj1HqScjyXYyEqMU7QLxWW+TKc=";
    sourceDirs = [ "." ];
  };
  maven-settings-builder = mk {
    pname = "maven-settings-builder";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-settings-builder" "3.9.5"
        "sha256-EsILTANmXX5/BLB0Q71cqxkPvewsUaRdPH+SBzrbAaU=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.maven-settings
      self.maven-builder-support
      self.plexus-interpolation
      self.plexus-sec-dispatcher
      self.javax-inject
    ];
  };
  maven-repository-metadata = mk {
    pname = "maven-repository-metadata";
    version = "3.9.5";
    src =
      mvn "org.apache.maven" "maven-repository-metadata" "3.9.5"
        "sha256-0Sn1thJUWUWgegz8Z5cV6SAWfYRS9FAZKnkSAOosyuU=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-utils ];
  };

  # --- misc --------------------------------------------------------------
  snakeyaml = mk {
    pname = "snakeyaml";
    version = "2.6";
    src = mvn "org.yaml" "snakeyaml" "2.6" "sha256-bc8W5M2efayRzWtArIsquZWpA1j/i/hW+bLZ8v7PC0Y=";
    sourceDirs = [ "." ];
  };
  dd-plist = mk {
    pname = "dd-plist";
    version = "1.27";
    postPatch = "rm -rf src/test";
    src =
      mvn "com.googlecode.plist" "dd-plist" "1.27"
        "sha256-uxCRwetEXJ06tPPm4z7hikqwNHe21eL6jFQZ8nIsdkM=";
    sourceDirs = [ "." ];
  };

  # --- test frameworks (compile-only for Gradle's test workers) ----------
  hamcrest-core = java.hamcrest-core;
  junit4 = mk {
    pname = "junit";
    version = "4.13.2";
    useRelease = true; # ObjectInputStream.GetField.get throws ClassNotFoundException since JDK 21
    src = gh "junit-team" "junit4" "r4.13.2" "sha256-A6ZbmsECwP/hYqmIoU3rDvEX3V9Dx3FtCgAxpv8n8+Q=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [ self.hamcrest-core ];
  };
  opentest4j = mk {
    pname = "opentest4j";
    version = "1.3.0";
    src = gh "ota4j-team" "opentest4j" "r1.3.0" "sha256-ZasHBY4C/8j6qfiljR+B68Xm16GrKRzY2IIeiWjO8/w=";
    sourceDirs = [ "src/main/java" ];
  };
  apiguardian = mk {
    pname = "apiguardian-api";
    version = "1.1.2";
    src =
      gh "apiguardian-team" "apiguardian" "r1.1.2"
        "sha256-3KOLE2XcbSpGr3iXFY6vVt4PFbkCpLT1SK0oPrbjfWU=";
    sourceDirs = [ "src/main/java" ];
  };
  junit5Src =
    gh "junit-team" "junit5" "r5.12.2"
      "sha256-8kLvtoStNToLtGJthbuPomlcMX35tgQZ6Fy9nDPq6TM=";
  junit-platform-commons = mk {
    pname = "junit-platform-commons";
    version = "1.12.2";
    src = self.junit5Src;
    sourceDirs = [ "junit-platform-commons/src/main/java" ];
    deps = [ self.apiguardian ];
  };
  junit-platform-engine = mk {
    pname = "junit-platform-engine";
    version = "1.12.2";
    src = self.junit5Src;
    sourceDirs = [ "junit-platform-engine/src/main/java" ];
    deps = [
      self.junit-platform-commons
      self.opentest4j
    ];
  };
  junit-platform-launcher = mk {
    pname = "junit-platform-launcher";
    version = "1.12.2";
    src = self.junit5Src;
    sourceDirs = [ "junit-platform-launcher/src/main/java" ];
    useRelease = true;
    resourceDirs = [ "junit-platform-launcher/src/main/resources" ];
    deps = [ self.junit-platform-engine ];
  };
  testng = mk {
    pname = "testng";
    version = "6.3.1";
    src = mvn "org.testng" "testng" "6.3.1" "sha256-LEdoBNyEufagH0YVYXhV/0CvJqOFNE9vvh4M028v4L4=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    deps = [
      self.junit4
      self.ant
      self.jcommander
      self.bsh
      self.snakeyaml-1
    ];
    buildDeps = [ self.guice-stub ];
  };
  jcommander = mk {
    pname = "jcommander";
    version = "1.12";
    src = mvn "com.beust" "jcommander" "1.12" "sha256-jcFbdfzJzzFXIhUkmlO/4fZdHev4q7K9RN87yuawWIo=";
    sourceDirs = [ "." ];
  };
  bsh = mk {
    pname = "bsh";
    version = "2.0b6";
    # scripted classes (bundled ASM 1.x, loaded reflectively), servlet and AWT bits dropped
    postPatch = "rm -rf bsh/ClassGeneratorImpl.java bsh/ClassGeneratorUtil.java bsh/servlet bsh/util/AWT*.java";
    src =
      mvn "org.apache-extras.beanshell" "bsh" "2.0b6"
        "sha256-rfnFw2T0p7Q0LzJpfl/Z+o313CFdQfLHeIrCopN5m4o=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  snakeyaml-1 = mk {
    pname = "snakeyaml";
    version = "1.6";
    src = mvn "org.yaml" "snakeyaml" "1.6" "sha256-8jkjqMOiWrwbVXY/yjfTC0iCWyTkZowvgk1lcAe5cNE=";
    sourceDirs = [ "." ];
  };
  findbugs-stub = mk {
    pname = "findbugs-annotations-stub";
    src = ./findbugs-stub;
    sourceDirs = [ "." ];
  };
  guice-stub = mk {
    pname = "guice-stub";
    src = ./guice-stub;
    sourceDirs = [ "." ];
  };
  # --- ANTLR 4.13 fork (Groovy 4's parser) -------------------------------
  # Groovy needs me.sunlan's fork of ANTLR 4.13.2 (alt labels may be reused
  # across rules); built from its Maven sources jars.
  # official 4.13.2: only for its Unicode data template, the fork's generates too large a method
  antlr413-git-src =
    gh "antlr" "antlr4" "4.13.2"
      "sha256-DxxRL+FQFA+x0RudIXtLhewseU50aScHKSCDX7DE9bY=";
  antlr413-annotations = mk {
    pname = "antlr4-annotations";
    version = "4.13.2.7";
    javacFlags = [ "-proc:none" ];
    src =
      mvn "me.sunlan" "antlr4-annotations" "4.13.2.7"
        "sha256-HSFVeXnRSGOfmbZV3CXVv/kHXYN/+wqZ0DsRqoNkjSw=";
    sourceDirs = [ "." ];
  };
  # (annotations merged in, like upstream's shading)
  antlr413-runtime = mk {
    pname = "antlr4-runtime";
    version = "4.13.2.7";
    buildDeps = [ self.antlr413-annotations ];
    mergeJars = [ "${self.antlr413-annotations}/share/java/antlr4-annotations.jar" ];
    javacFlags = [ "-proc:none" ];
    src =
      mvn "me.sunlan" "antlr4-runtime" "4.13.2.7"
        "sha256-fEd8goMfXXvrXJq7mrJWlVt0a5hAVlJ+e4CZJE7Dj9Q=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };

  # the official 4.13.2 runtime (the fork's differs in API, e.g. a generic ANTLRErrorListener)
  antlr4-runtime = mk {
    pname = "antlr4-runtime";
    version = "4.13.2";
    src = self.antlr413-git-src;
    sourceDirs = [ "runtime/Java/src" ];
  };

  # (the antlr.mkAntlr4 recipe of nix/java/antlr.nix, with 4.13's template-based
  # Unicode data generation: a small renderer replaces string-template-maven-plugin)
  # the official 4.13.2 tool (for grammars compiled against the official runtime)
  antlr4 =
    (mk {
      pname = "antlr4";
      version = "4.13.2";
      src = self.antlr413-git-src;
      nativeBuildInputs = [ antlr.antlr3 ];
      preBuild = ''
        cp -r tool/resources/. tool/src/
        chmod -R u+w tool/src
        export CLASSPATH="${
          classpathOf [
            antlr.antlr3
            self.antlr4-runtime
            antlr.stringtemplate4
            antlr.treelayout
            antlr.icu4j
          ]
        }"
        mkdir -p $TMPDIR/gen-classes
        cat > UnicodeRenderer.java <<'EOF'
        import java.io.*;
        import java.util.Map;
        import org.stringtemplate.v4.*;
        public class UnicodeRenderer {
          public static void main(String[] a) throws Exception {
            Map<String, Object> props = org.antlr.v4.unicode.UnicodeDataTemplateController.getProperties();
            STGroup g = new STGroupDir(a[0]);
            ST st = g.getInstanceOf("unicodedata");
            for (Map.Entry<String, Object> e : props.entrySet()) st.add(e.getKey(), e.getValue());
            try (Writer w = new FileWriter(a[1])) { w.write(st.render()); }
          }
        }
        EOF
        javac -cp "$CLASSPATH" -d $TMPDIR/gen-classes -nowarn UnicodeRenderer.java \
          tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java
        java -cp "$CLASSPATH:$TMPDIR/gen-classes" UnicodeRenderer \
          tool/src/org/antlr/v4/tool/templates tool/src/org/antlr/v4/unicode/UnicodeData.java
        sed -i 's/\\>/>/g' tool/src/org/antlr/v4/unicode/UnicodeData.java
        rm UnicodeRenderer.java
        (cd tool/src/org/antlr/v4/parse
         for f in ANTLRLexer.g ANTLRParser.g BlockSetTransformer.g GrammarTreeVisitor.g ATNBuilder.g \
                  ActionSplitter.g LeftRecursiveRuleWalker.g; do antlr3 $f; done)
        (cd tool/src/org/antlr/v4/codegen && cp ../parse/ANTLRParser.tokens . && antlr3 SourceGenTriggers.g)
      '';
      sourceDirs = [ "tool/src" ];
      copySourceResources = true;
      deps = [
        antlr.antlr3
        self.antlr4-runtime
        antlr.stringtemplate4
        antlr.treelayout
      ];
      buildDeps = [ antlr.icu4j ];
    }).overrideAttrs
      (o: {
        postInstall = ''
          mkdir -p $out/bin
          cat > $out/bin/antlr4 <<EOF
          #!/bin/sh
          exec ${jdk}/bin/java -cp $out/share/java/antlr4.jar:${classpathOf o.passthru.javaDeps} org.antlr.v4.Tool "\$@"
          EOF
          chmod +x $out/bin/antlr4
        '';
      });

  # antlr 4.9.0 (the version Groovy 3 is generated and compiled with)
  antlr49-git-src = gh "antlr" "antlr4" "4.9" "sha256-BD+QTj5KnoTrfJKiACJvyMp+2E3lFFadLzvAH7e8UHc=";
  antlr49-runtime = mk {
    pname = "antlr4-runtime";
    version = "4.9.0";
    src = self.antlr49-git-src;
    sourceDirs = [ "runtime/Java/src" ];
  };
  antlr49 =
    (mk {
      pname = "antlr4";
      version = "4.9.0";
      src = self.antlr49-git-src;
      nativeBuildInputs = [ antlr.antlr3 ];
      preBuild = ''
        rm tool/src/org/antlr/v4/codegen/target/SwiftTarget.java # (needs javax.json; loaded by name only)
        # (4.9's Unicode data template overflows the method size limit: use 4.13's)
        cp ${self.antlr413-git-src}/tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java tool/src/org/antlr/v4/unicode/
        cp ${self.antlr413-git-src}/tool/resources/org/antlr/v4/tool/templates/unicodedata.st tool/resources/org/antlr/v4/tool/templates/
        cp -r tool/resources/. tool/src/
        chmod -R u+w tool/src
        export CLASSPATH="${
          classpathOf [
            antlr.antlr3
            self.antlr49-runtime
            antlr.stringtemplate4
            antlr.treelayout
            antlr.icu4j
          ]
        }"
        mkdir -p $TMPDIR/gen-classes
        cat > UnicodeRenderer.java <<'EOF'
        import java.io.*;
        import java.util.Map;
        import org.stringtemplate.v4.*;
        public class UnicodeRenderer {
          public static void main(String[] a) throws Exception {
            Map<String, Object> props = org.antlr.v4.unicode.UnicodeDataTemplateController.getProperties();
            STGroup g = new STGroupDir(a[0]);
            ST st = g.getInstanceOf("unicodedata");
            for (Map.Entry<String, Object> e : props.entrySet()) st.add(e.getKey(), e.getValue());
            try (Writer w = new FileWriter(a[1])) { w.write(st.render()); }
          }
        }
        EOF
        javac -cp "$CLASSPATH" -d $TMPDIR/gen-classes -nowarn UnicodeRenderer.java \
          tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java
        java -cp "$CLASSPATH:$TMPDIR/gen-classes" UnicodeRenderer \
          tool/src/org/antlr/v4/tool/templates tool/src/org/antlr/v4/unicode/UnicodeData.java
        sed -i 's/\\>/>/g' tool/src/org/antlr/v4/unicode/UnicodeData.java
        rm UnicodeRenderer.java
        (cd tool/src/org/antlr/v4/parse
         for f in ANTLRLexer.g ANTLRParser.g BlockSetTransformer.g GrammarTreeVisitor.g ATNBuilder.g \
                  ActionSplitter.g LeftRecursiveRuleWalker.g; do antlr3 $f; done)
        (cd tool/src/org/antlr/v4/codegen && cp ../parse/ANTLRParser.tokens . && antlr3 SourceGenTriggers.g)
      '';
      sourceDirs = [ "tool/src" ];
      copySourceResources = true;
      deps = [
        antlr.antlr3
        self.antlr49-runtime
        antlr.stringtemplate4
        antlr.treelayout
      ];
      buildDeps = [ antlr.icu4j ];
    }).overrideAttrs
      (o: {
        postInstall = ''
          mkdir -p $out/bin
          cat > $out/bin/antlr4 <<EOF
          #!/bin/sh
          exec ${jdk}/bin/java -cp $out/share/java/antlr4.jar:${classpathOf o.passthru.javaDeps} org.antlr.v4.Tool "\$@"
          EOF
          chmod +x $out/bin/antlr4
        '';
      });

  antlr413 =
    (mk {
      pname = "antlr4";
      version = "4.13.2.7";
      javacFlags = [ "-proc:none" ];
      # (the jar also carries a generated UnicodeData.java under src/)
      postPatch = "rm -rf src";
      src = mvn "me.sunlan" "antlr4" "4.13.2.7" "sha256-VUSy4SzdTzP0hn/5tBW8C1V4/XLwSktIsvy5radoCKE=";
      nativeBuildInputs = [ antlr.antlr3 ];
      preBuild = ''
        export CLASSPATH="${
          classpathOf [
            antlr.antlr3
            self.antlr413-runtime
            antlr.stringtemplate4
            antlr.treelayout
            antlr.icu4j
          ]
        }"
        mkdir -p $TMPDIR/gen-classes
        cp ${self.antlr413-git-src}/tool/resources/org/antlr/v4/tool/templates/unicodedata.st org/antlr/v4/tool/templates/
        cp ${self.antlr413-git-src}/tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java org/antlr/v4/unicode/
        chmod -R u+w org
        cat > UnicodeRenderer.java <<'EOF'
        import java.io.*;
        import java.util.Map;
        import org.stringtemplate.v4.*;
        public class UnicodeRenderer {
          public static void main(String[] a) throws Exception {
            Map<String, Object> props = org.antlr.v4.unicode.UnicodeDataTemplateController.getProperties();
            STGroup g = new STGroupDir(a[0]);
            ST st = g.getInstanceOf("unicodedata");
            for (Map.Entry<String, Object> e : props.entrySet()) st.add(e.getKey(), e.getValue());
            try (Writer w = new FileWriter(a[1])) { w.write(st.render()); }
          }
        }
        EOF
        javac -cp "$CLASSPATH" -d $TMPDIR/gen-classes -nowarn UnicodeRenderer.java \
          org/antlr/v4/unicode/UnicodeDataTemplateController.java
        java -cp "$CLASSPATH:$TMPDIR/gen-classes" UnicodeRenderer \
          org/antlr/v4/tool/templates org/antlr/v4/unicode/UnicodeData.java
        sed -i 's/\\>/>/g' org/antlr/v4/unicode/UnicodeData.java
        rm UnicodeRenderer.java
        (cd org/antlr/v4/parse
         for f in ANTLRLexer.g ANTLRParser.g BlockSetTransformer.g GrammarTreeVisitor.g ATNBuilder.g \
                  ActionSplitter.g LeftRecursiveRuleWalker.g; do antlr3 $f; done)
        (cd org/antlr/v4/codegen && cp ../parse/ANTLRParser.tokens . && antlr3 SourceGenTriggers.g)
      '';
      sourceDirs = [ "." ];
      copySourceResources = true;
      deps = [
        antlr.antlr3
        self.antlr413-runtime
        antlr.stringtemplate4
        antlr.treelayout
      ];
      buildDeps = [ antlr.icu4j ];
    }).overrideAttrs
      (o: {
        postInstall = ''
          mkdir -p $out/bin
          cat > $out/bin/antlr4 <<EOF
          #!/bin/sh
          exec ${jdk}/bin/java -cp $out/share/java/antlr4.jar:${classpathOf o.passthru.javaDeps} org.antlr.v4.Tool "\$@"
          EOF
          chmod +x $out/bin/antlr4
        '';
      });
})
