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
  perl,
  ncurses,
  callPackage,
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
      url = "https://repo1.maven.org/maven2/${lib.replaceStrings [ "." ] [ "/" ] group}/${artifact}/${version}/${artifact}-${version}-sources.jar";
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
        if args.useRelease or false then "--release ${release}" else "-source ${release} -target ${release}";
    in
    mkJar (
      { javaRelease = release; }
      // removeAttrs args [
        "resourceDirs"
        "useRelease"
      ]
      // {
        postPatch = ''
          find . -name module-info.java -delete
        ''
        + (args.postPatch or "");
        buildPhase = args.buildPhase or ''
          runHook preBuild
          export CLASSPATH="${cp}"
          mkdir -p build/classes
          : > build/sources.txt
          for d in ${lib.escapeShellArgs sourceDirs}; do
            find "$d" -name '*.java' >> build/sources.txt
          done
          sort -o build/sources.txt build/sources.txt
          echo "compiling $(wc -l < build/sources.txt) java files"
          if [ -s build/sources.txt ]; then
            javac -d build/classes -encoding UTF-8 ${target} -nowarn -g -Xmaxerrs 1000 \
              -cp "$CLASSPATH" ${lib.escapeShellArgs (args.javacFlags or [ ])} @build/sources.txt
          fi
          ${lib.optionalString (args.copySourceResources or false) ''
            for d in ${lib.escapeShellArgs sourceDirs}; do
              (cd "$d" && find . -type f ! -name '*.java' -exec cp --parents -t "$OLDPWD/build/classes" {} +)
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
  slf4jSrc = gh "qos-ch" "slf4j" "v_2.0.17" "sha256-MOAIvzVPxFv9Nfov4Ych774urZ0v9emscKqwIGI/3Ik=";
  jackson8Src = gh "FasterXML" "jackson-modules-java8" "jackson-modules-java8-2.22.0" "sha256-zZYt5ehdX69xo1VQ6ZVQhw/3u4HMTbrOOuyvpXFkRnI=";
  # jackson's PackageVersion.java.in
  jacksonVersion =
    { template, package, group, artifact, version }:
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
    src = mvn "com.google.code.findbugs" "jsr305" "3.0.2" "sha256-JDujjNoIfofxXRpsVIoOcGtqzVR1WQSjoEM7ZydKYnc=";
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
    src = mvn "com.google.j2objc" "j2objc-annotations" "3.0.0" "sha256-y/3+hlFvZK4gT3SPGQmxxwIVtxQmEx+Kt6ODZ5uEbrM=";
    sourceDirs = [ "." ];
  };

  checker-qual = mk {
    pname = "checker-qual";
    version = "3.43.0";
    src = mvn "org.checkerframework" "checker-qual" "3.43.0" "sha256-jA0rTiJoi59+GnkM6+QKdMgTSpNEM7bLSQkjPn4M2LQ=";
    sourceDirs = [ "." ];
  };

  jetbrains-annotations = mk {
    pname = "annotations";
    version = "24.0.1";
    src = gh "JetBrains" "java-annotations" "24.0.1" "sha256-VupUlE0gYl+sHPmIswR/1hJzkOKEOGhJyD2LDhjg0/c=";
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
    src = gh "apache" "commons-io" "rel/commons-io-2.20.0" "sha256-fzfrmR0LhFihXe0TdEO3M4EIR0MxJw0AwhiSWRC6PVs=";
    sourceDirs = [ "src/main/java" ];
  };

  commons-lang3 = mk {
    pname = "commons-lang3";
    version = "3.20.0";
    src = gh "apache" "commons-lang" "rel/commons-lang-3.20.0" "sha256-6FivHu4P6fJ1cDABHLt6TXM3PJ08W/73KwPiPa5RONA=";
    sourceDirs = [ "src/main/java" ];
  };

  commons-codec = mk {
    pname = "commons-codec";
    version = "1.18.0";
    src = gh "apache" "commons-codec" "rel/commons-codec-1.18.0" "sha256-bJCwxDn4fnEFJRZFcCPrZXJS7/UcNj10yNV/kd1Pq4w=";
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
    src = gh "apache" "commons-compress" "rel/commons-compress-1.28.0" "sha256-7nv1Vp/WMn5H2/P0FaoyQgzu+wWdOogztEJlORD8wDA=";
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
    src = gh "apache" "httpcomponents-core" "rel/v4.4.16" "sha256-2Fk8UnvEJDI95AV/92N3Jzg6MMHZdyRHQXsbpRq+Td4=";
    sourceDirs = [
      "httpcore/src/main/java"
      "httpcore/src/main/java-deprecated"
    ];
    resourceDirs = [ "httpcore/src/main/resources" ];
    preBuild = filterVersion "4.4.16" [ "httpcore/src/main/resources/org/apache/http/version.properties" ];
  };

  httpclient = mk {
    pname = "httpclient";
    version = "4.5.14";
    src = gh "apache" "httpcomponents-client" "rel/v4.5.14" "sha256-WrOA/EQ+Y3HWkYXQgiEdTcfYyZ+16aIJ0HCwiYISxEY=";
    sourceDirs = [
      "httpclient/src/main/java"
      "httpclient/src/main/java-deprecated"
    ];
    resourceDirs = [ "httpclient/src/main/resources" ];
    preBuild = filterVersion "4.5.14" [ "httpclient/src/main/resources/org/apache/http/client/version.properties" ];
    deps = [
      self.httpcore
      self.commons-codec
      self.jcl-over-slf4j
    ];
  };

  # --- logging -----------------------------------------------------------
  slf4j-api = mk {
    pname = "slf4j-api";
    version = "2.0.17";
    src = slf4jSrc;
    sourceDirs = [ "slf4j-api/src/main/java" ];
    resourceDirs = [ "slf4j-api/src/main/resources" ];
  };
  jcl-over-slf4j = mk {
    pname = "jcl-over-slf4j";
    version = "2.0.17";
    src = slf4jSrc;
    sourceDirs = [ "jcl-over-slf4j/src/main/java" ];
    resourceDirs = [ "jcl-over-slf4j/src/main/resources" ];
    deps = [ self.slf4j-api ];
  };
  jul-to-slf4j = mk {
    pname = "jul-to-slf4j";
    version = "2.0.17";
    src = slf4jSrc;
    sourceDirs = [ "jul-to-slf4j/src/main/java" ];
    deps = [ self.slf4j-api ];
  };
  log4j-over-slf4j = mk {
    pname = "log4j-over-slf4j";
    version = "2.0.17";
    src = slf4jSrc;
    sourceDirs = [ "log4j-over-slf4j/src/main/java" ];
    resourceDirs = [ "log4j-over-slf4j/src/main/resources" ];
    deps = [ self.slf4j-api ];
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
    src = mvn "com.esotericsoftware.reflectasm" "reflectasm" "1.09" "sha256-i1RT+swQaiHAptorotQH41v1HVcP1VDbm792gtq8mVQ=";
    sourceDirs = [ "." ];
    buildDeps = [ self.asm ];
  };

  kryo = mk {
    pname = "kryo";
    version = "2.24.0";
    src = gh "EsotericSoftware" "kryo" "kryo-2.24.0" "sha256-fW2eZNF6iL+lnkRXGJhHQMJa9aPyM8doGoFQcNgX23M=";
    sourceDirs = [ "src" ];
    deps = [
      self.minlog
      self.objenesis
    ];
    # sun.misc.Cleaner is gone since JDK 9
    nativeBuildInputs = [ perl ];
    postPatch = ''
      f=src/com/esotericsoftware/kryo/util/UnsafeUtil.java
      sed -i -e '/^import sun.misc.Cleaner;/d' -e '/^import sun.nio.ch.DirectBuffer;/d' $f
      perl -0pi -e 's/Object cleaner = \(\(DirectBuffer\) niobuffer\).cleaner\(\);\s*if\(cleaner != null\)\s*\(\(Cleaner\)cleaner\).clean\(\);/try { Object cleaner = niobuffer.getClass().getMethod("cleaner").invoke(niobuffer); if (cleaner != null) cleaner.getClass().getMethod("clean").invoke(cleaner); } catch (Exception e) { }/' $f
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
    src = gh "jnr" "jnr-constants" "jnr-constants-0.10.4" "sha256-leMxtrWU30/y+9WIhkQlImjYmzdAF4ptoMKLZMxVDJM=";
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
    src = mvn "com.googlecode.jatl" "jatl" "0.2.3" "sha256-WOUU6BlcycSM5mbLmDD5vDR21L7W0LHchcXLpyzisLg=";
    sourceDirs = [ "." ];
  };

  javapoet = mk {
    pname = "javapoet";
    version = "1.13.0";
    src = gh "square" "javapoet" "javapoet-1.13.0" "sha256-Pj28ZTJFi9WB5Qnl8XIrSkRkzdA4De0o4vL9Ww9XjuA=";
    sourceDirs = [ "src/main/java" ];
  };

  # --- Jackson -----------------------------------------------------------
  jackson-annotations = mk {
    pname = "jackson-annotations";
    version = "2.22";
    src = gh "FasterXML" "jackson-annotations" "jackson-annotations-2.22" "sha256-nos0/g7RKc5RZtl36nLjPY7o2zssdJxVqP/NOeha2Hg=";
    sourceDirs = [ "src/main/java" ];
  };

  fastdoubleparser = mk {
    pname = "fastdoubleparser";
    version = "2.0.1";
    src = gh "wrandelshofer" "FastDoubleParser" "v2.0.1" "sha256-o80akZwUit5QdqF7SG64ENJhTFcKeHQBJY6SifjeLiY=";
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
    src = gh "FasterXML" "jackson-core" "jackson-core-2.22.0" "sha256-52pW647+IDXZdW0uPq1YMiA8cHfVXvaoy+6cRMWTXAA=";
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
    src = gh "FasterXML" "jackson-databind" "jackson-databind-2.22.0" "sha256-tPE+Ye/GZdXocQqkye8qjjAUE0kG8fThAWyCQOBdGTM=";
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
    preBuild = "cd datatypes\n" + jacksonVersion {
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
    preBuild = "cd datetime\n" + jacksonVersion {
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
    src = gh "gradle" "native-platform" "0.22-milestone-29" "sha256-HNVA6QDiPPKh0BQpCBjwiv4LNYxDySlqXcZjYC+FdFo=";
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
    passthru.javaDeps = [ self.native-platform self.slf4j-api ];
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
  # --- build tools -------------------------------------------------------
  ant = callPackage ../java/ant.nix {
    inherit jdk;
    version = "1.10.17";
    hash = "sha256-8DkKXO4Qdgd/mtuP7d2ZMx/rpKmIfzN5mSuLaye+ZFw=";
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
      grep -rlE 'import (org\.apache\.commons\.(httpclient|vfs)|org\.apache\.http|com\.jcraft|org\.bouncycastle|org\.apache\.oro)' src/java | xargs -r rm -v
    '';
    sourceDirs = [ "src/java" ];
    copySourceResources = true;
    useRelease = true; # java.util.jar.Pack200
    deps = [ self.ant ];
  };

  # --- crypto ------------------------------------------------------------
  bcprov = mk {
    pname = "bcprov-jdk18on";
    version = "1.85";
    # multi-release extras (Java 9+ variants of some classes)
    postPatch = "rm -rf META-INF/versions";
    src = mvn "org.bouncycastle" "bcprov-jdk18on" "1.85" "sha256-HiI4dcHwCHdPGrzREHXOiNXulv3QD2MvFneHGQlhQd4=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  bcutil = mk {
    pname = "bcutil-jdk18on";
    version = "1.85";
    postPatch = "rm -rf META-INF/versions";
    src = mvn "org.bouncycastle" "bcutil-jdk18on" "1.85" "sha256-+BobUZ3LeTENY4DSPpEikqJRVYMmjTmI0houVrzOzaw=";
    sourceDirs = [ "." ];
    deps = [ self.bcprov ];
  };
  bcpg = mk {
    pname = "bcpg-jdk18on";
    version = "1.85";
    postPatch = "rm -rf META-INF/versions";
    src = mvn "org.bouncycastle" "bcpg-jdk18on" "1.85" "sha256-pspoKvNrHz9bWAGpbZdrtgI5h8xaFM0cjp8x+fqu6+8=";
    sourceDirs = [ "." ];
    deps = [ self.bcprov self.bcutil ];
  };

  # --- Maven / Plexus ----------------------------------------------------
  plexus-utils = mk {
    pname = "plexus-utils";
    version = "3.6.1";
    src = gh "codehaus-plexus" "plexus-utils" "plexus-utils-3.6.1" "sha256-xOIdnUzG2qNsuiHmLOY3eZMdNIvgyoZjy3dokg6Jh1s=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
  };
  plexus-interpolation = mk {
    pname = "plexus-interpolation";
    version = "1.26";
    src = gh "codehaus-plexus" "plexus-interpolation" "plexus-interpolation-1.26" "sha256-kP7uahc6j+AGmKm6pcJpbHuufkyMfixGLc047mGVUOU=";
    sourceDirs = [ "src/main/java" ];
  };
  plexus-cipher = mk {
    pname = "plexus-cipher";
    version = "2.0";
    # sisu's @Typed is only a hint for the DI container
    postPatch = "sed -i -e '/^import org.eclipse.sisu.Typed;/d' -e 's/^@Typed.*//' org/sonatype/plexus/components/cipher/DefaultPlexusCipher.java";
    src = mvn "org.codehaus.plexus" "plexus-cipher" "2.0" "sha256-ZcdbhITWv4AcvPS0lfLMMNHxqusHikBLmze/imMMYhU=";
    sourceDirs = [ "." ];
    deps = [ self.javax-inject ];
  };
  plexus-sec-dispatcher = mk {
    pname = "plexus-sec-dispatcher";
    version = "2.0";
    src = mvn "org.codehaus.plexus" "plexus-sec-dispatcher" "2.0" "sha256-Xb+PNTL+ou4fRBZPIyzHpdfISIZGcJnoKwyFO71hI7Y=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-cipher self.plexus-utils self.javax-inject ];
  };
  maven-model = mk {
    pname = "maven-model";
    version = "3.9.5";
    src = mvn "org.apache.maven" "maven-model" "3.9.5" "sha256-PGlrUqhc0oackZg5TsrGpRxJwFCMj5D8jnNH8oA3m/Y=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-utils ];
  };
  maven-settings = mk {
    pname = "maven-settings";
    version = "3.9.5";
    src = mvn "org.apache.maven" "maven-settings" "3.9.5" "sha256-7aSMu02mIVw2aDp+kmDOWbIGolhtZuw2X2KTP1q4+RI=";
    sourceDirs = [ "." ];
    deps = [ self.plexus-utils ];
  };
  maven-builder-support = mk {
    pname = "maven-builder-support";
    version = "3.9.5";
    src = mvn "org.apache.maven" "maven-builder-support" "3.9.5" "sha256-+DjTFKPeMQPcsXVPoGj1HqScjyXYyEqMU7QLxWW+TKc=";
    sourceDirs = [ "." ];
  };
  maven-settings-builder = mk {
    pname = "maven-settings-builder";
    version = "3.9.5";
    src = mvn "org.apache.maven" "maven-settings-builder" "3.9.5" "sha256-EsILTANmXX5/BLB0Q71cqxkPvewsUaRdPH+SBzrbAaU=";
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
    src = mvn "org.apache.maven" "maven-repository-metadata" "3.9.5" "sha256-0Sn1thJUWUWgegz8Z5cV6SAWfYRS9FAZKnkSAOosyuU=";
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
    src = mvn "com.googlecode.plist" "dd-plist" "1.27" "sha256-uxCRwetEXJ06tPPm4z7hikqwNHe21eL6jFQZ8nIsdkM=";
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
    src = gh "apiguardian-team" "apiguardian" "r1.1.2" "sha256-3KOLE2XcbSpGr3iXFY6vVt4PFbkCpLT1SK0oPrbjfWU=";
    sourceDirs = [ "src/main/java" ];
  };
  junit5Src = gh "junit-team" "junit5" "r5.12.2" "sha256-8kLvtoStNToLtGJthbuPomlcMX35tgQZ6Fy9nDPq6TM=";
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
    deps = [ self.junit-platform-commons self.opentest4j ];
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
    src = mvn "org.apache-extras.beanshell" "bsh" "2.0b6" "sha256-rfnFw2T0p7Q0LzJpfl/Z+o313CFdQfLHeIrCopN5m4o=";
    sourceDirs = [ "." ];
    copySourceResources = true;
  };
  snakeyaml-1 = mk {
    pname = "snakeyaml";
    version = "1.6";
    src = mvn "org.yaml" "snakeyaml" "1.6" "sha256-8jkjqMOiWrwbVXY/yjfTC0iCWyTkZowvgk1lcAe5cNE=";
    sourceDirs = [ "." ];
  };
  guice-stub = mk {
    pname = "guice-stub";
    src = ./guice-stub;
    sourceDirs = [ "." ];
  };
})
