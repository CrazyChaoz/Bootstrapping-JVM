# Third party Java libraries needed by the IntelliJ SDK modules and Kotlin,
# all built from source.  Versions follow the TarCV/kotlin-guix chain, which
# itself mostly uses what Guix packages.
{
  lib,
  fetchurl,
  fetchzip,
  mkJar,
  ant,
  jdk,
  callPackage,
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };
  ow2asm =
    tag: hash:
    fetchzip {
      url = "https://gitlab.ow2.org/asm/asm/-/archive/${tag}/asm-${tag}.tar.gz";
      inherit hash;
    };
  # Maven "-sources.jar" artifacts are plain source archives.
  sourcesJar =
    url: hash:
    fetchzip {
      inherit url hash;
      stripRoot = false;
      extension = "zip";
    };
in
lib.fix (self: {
  cli-parser = mkJar {
    pname = "cli-parser";
    version = "1.1.6";
    src = gh "spullara" "cli-parser" "cli-parser-1.1.6" "sha256-PDypWr9swyVRdGG69WM8yXlwvc/0zyEhdLZcyyTZSbg=";
    sourceDirs = [ "src/main/java" ];
    javaRelease = "1.6";
  };

  hawtjni-runtime = mkJar {
    pname = "hawtjni-runtime";
    version = "1.15";
    src = gh "fusesource" "hawtjni" "hawtjni-project-1.15" "sha256-ZazGd/bck2XwSgxb7i+K/3tdnx5hiQ9YlSulZBDn6RM=";
    sourceDirs = [ "hawtjni-runtime/src/main/java" ];
    javaRelease = "1.6";
  };

  # Only the Java side; the JNI library is not needed for compiling Kotlin.
  jansi-native = mkJar {
    pname = "jansi-native";
    version = "1.7";
    src = gh "fusesource" "jansi-native" "jansi-native-1.7" "sha256-8Jw8GGfmEU61pjz83OJU8FHmjJg02qtVdui9ILEXx+M=";
    sourceDirs = [ "src/main/java" ];
    deps = [ self.hawtjni-runtime ];
    javaRelease = "1.6";
  };

  jansi-1 = mkJar {
    pname = "jansi";
    version = "1.16";
    src = gh "fusesource" "jansi" "jansi-project-1.16" "sha256-3Su9UVslaO2OrrOwvFUFUmreE2oyWCzIAgM+UUYHc0Y=";
    sourceDirs = [ "jansi/src/main/java" ];
    deps = [ self.jansi-native ];
    javaRelease = "1.6";
  };

  jline-2 = mkJar {
    pname = "jline";
    version = "2.14.5";
    src = gh "jline" "jline2" "jline-2.14.5" "sha256-IMvF+ErDwnbEGJFFtodINBabYMAPhIzSU4y6iQ9VD3k=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [ self.jansi-1 ];
    javaRelease = "1.6";
  };

  jsr305 = mkJar {
    pname = "jsr305";
    version = "3.0.1";
    src = sourcesJar "https://repo1.maven.org/maven2/com/google/code/findbugs/jsr305/3.0.1/jsr305-3.0.1-sources.jar" "sha256-pSQPiS18YhsD0/A51XONpcAo+PMNo+UJmFvIK6NPMAA=";
    sourceDirs = [ "." ];
    javaRelease = "1.6";
  };

  error-prone-annotations-2_0_12 = mkJar {
    pname = "error-prone-annotations";
    version = "2.0.12";
    src = gh "google" "error-prone" "v2.0.12" "sha256-E1MOvcrISlH3xXIE4pyADsoynr14xMtprlud55r6v18=";
    sourceDirs = [ "annotations/src/main/java" ];
    deps = [ self.jsr305 ];
    javaRelease = "1.6";
  };

  # Latest Guava that does not depend on Java 8 Predicate (see TarCV).
  guava-20 = mkJar {
    pname = "guava";
    version = "20.0";
    src = gh "google" "guava" "v20.0" "sha256-V/updpB71e059hpW50Pd1KHiAvw7+tFs3IFF2bhiBQI=";
    patches = [ ../../patches/tarcv/guava-20-linkedhashset.patch ];
    postPatch = ''
      cd guava/src/com/google/common
      find . -name '*.java' -exec sed -i -E \
        -e '/^import com\.google\.j2objc/d' \
        -e '/^import org\.checkerframework\.checker/d' \
        -e '/^import org\.codehaus\.mojo\.animal_sniffer\.IgnoreJRERequirement;/d' \
        -e 's/@ReflectionSupport\([^)]*\)//g' \
        -e 's/@WeakOuter//g; s/@RetainedWith//g; s/@Weak\b//g' \
        -e 's/@J2ObjCIncompatible//g; s/@IgnoreJRERequirement//g' \
        {} +
      cd -
    '';
    sourceDirs = [ "guava/src" ];
    buildDeps = [
      self.jsr305
      self.error-prone-annotations-2_0_12
    ];
    javaRelease = "1.6";
  };

  javax-inject = mkJar {
    pname = "javax-inject";
    version = "1";
    src = gh "javax-inject" "javax-inject" "1" "sha256-/cgR2LZVRO5cFf5Os4SU1LDYR+IzMmaNizLMPS2gV+c=";
    sourceDirs = [ "src" ];
    javaRelease = "1.6";
  };

  protobuf = callPackage ./protobuf.nix { };

  # ASM, relocated the way IntelliJ/Kotlin expect it.
  mkAsm =
    {
      version,
      src,
      relocateTo ? null,
      sourceDirs ? [ "src" ],
      patches ? [ ],
      javaRelease ? "1.6",
    }:
    mkJar {
      pname = "asm" + lib.optionalString (relocateTo != null) "-${lib.replaceStrings [ "." ] [ "-" ] relocateTo}";
      inherit
        version
        src
        sourceDirs
        patches
        javaRelease
        ;
      postPatch = ''
        find . -type d \( -name optimizer -o -name tools \) -prune -exec rm -r {} +
      ''
      + lib.optionalString (relocateTo != null) ''
        find ${lib.escapeShellArgs sourceDirs} -name '*.java' -exec sed -i -E \
          's/([^[:alnum:]])org\.objectweb\.asm([^[:alnum:]])/\1${relocateTo}\2/g' {} +
      '';
    };

  asm-4-src = ow2asm "ASM_4_2" "sha256-Cgtp4LquNt3FE5fhnYRyOd9G2xVoMjB43mH2TZ66ikM=";
  asm-5-src = ow2asm "ASM_5_2" "sha256-sstam6OFgWOlbu0Znt37TGjc6cTwJ5uL47T1i/5kvZQ=";
  asm-6-src = ow2asm "ASM_6_0" "sha256-meARDWeBQ8WYNgoG9qIdOML2Mhpc/9S+xgehE0+URPs=";
  asm-8-src = ow2asm "ASM_8_0_1" "sha256-ybQpG4Kl7rA8KbLcj3i6Sw0WFiJP8JAQfObEwP4R0ug=";

  jetbrains-asm-4 = self.mkAsm {
    version = "4.2";
    src = self.asm-4-src;
    relocateTo = "org.jetbrains.asm4";
  };
  # build-1.0.3-dev-378 and later break without the coverage fix (TarCV)
  jetbrains-asm-5 = self.mkAsm {
    version = "5.2";
    src = self.asm-5-src;
    patches = [ ../../patches/tarcv/sdk172-asm/2_coverage_fix.patch ];
    relocateTo = "org.jetbrains.org.objectweb.asm";
  };
  jetbrains-asm-6 = self.mkAsm {
    version = "6.0";
    src = self.asm-6-src;
    patches = [
      ../../patches/tarcv/sdk172-asm/1_version_check.patch
      ../../patches/tarcv/sdk172-asm/2_coverage_fix.patch
      ../../patches/tarcv/sdk172-asm/3_api_version.patch
    ];
    relocateTo = "org.jetbrains.org.objectweb.asm";
  };
  asm-6 = self.mkAsm {
    version = "6.0";
    src = self.asm-6-src;
  };
  asm-8 = self.mkAsm {
    version = "8.0.1";
    src = self.asm-8-src;
    sourceDirs = [
      "asm/src/main/java"
      "asm-tree/src/main/java"
      "asm-analysis/src/main/java"
      "asm-commons/src/main/java"
      "asm-util/src/main/java"
    ];
    javaRelease = "1.8";
  };

  cglib = mkJar {
    pname = "cglib";
    version = "3.3.0";
    src = gh "cglib" "cglib" "RELEASE_3_3_0" "sha256-JIBmGaAjd2J1BngxcqWwf9ynelavyPjkgdAuw6pi2tI=";
    sourceDirs = [ "cglib/src/main/java" ];
    # The ant task is optional.
    postPatch = ''
      rm -r cglib/src/main/java/net/sf/cglib/transform/AbstractTransformTask.java \
            cglib/src/main/java/net/sf/cglib/transform/AbstractProcessTask.java
    '';
    deps = [ self.asm-8 ];
    javaRelease = "1.6";
  };

  automaton = mkJar {
    pname = "automaton";
    version = "1.12.4";
    src = gh "cs-au-dk" "dk.brics.automaton" "75db9df045892a4c59b8994f51e5cbc60be7fdc9" "sha256-2yt0DdFjcRQQ+ZO1vzz7NyCVnogBn2OnEVSZBWGzXSg=";
    sourceDirs = [ "src" ];
    javaRelease = "1.6";
  };

  iq80-snappy = mkJar {
    pname = "iq80-snappy";
    version = "0.4";
    src = gh "dain" "snappy" "snappy-0.4" "sha256-n62AF55hWG0nEExuoPqz4S3YKVY9m9nXb7kYcICAXNc=";
    sourceDirs = [ "src/main/java" ];
    # Drop the optional Hadoop codec.
    postPatch = ''
      grep -rl '^import org.apache.hadoop' src/main/java | xargs -r rm -v
    '';
    javaRelease = "1.6";
  };

  picocontainer-1 = mkJar {
    pname = "picocontainer";
    version = "1.2";
    src = gh "picocontainer" "PicoContainer1" "picocontainer-1.2" "sha256-Shr1WcQfIh8oB4z73/Zm7XZBjCgo8Z0LKCFknrHYGp0=";
    sourceDirs = [ "container/src/java" ];
    encoding = "ISO-8859-1";
    javaRelease = "1.6";
  };

  jetbrains-trove4j = mkJar {
    pname = "jetbrains-trove4j";
    version = "2016.8.24";
    src = gh "JetBrains" "intellij-deps-trove4j" "29150c19710ef1581c790d0502cf299583db7322" "sha256-jUvaUYcEfY+rAGl+gZQEHSw2Iv4RTozXiMCjEA1eo60=";
    sourceDirs = [
      "core/src"
      "generated/src"
    ];
    javaRelease = "1.6";
  };

  jakarta-oro = mkJar {
    pname = "jakarta-oro";
    version = "2.0.8";
    src = sourcesJar "https://repo1.maven.org/maven2/oro/oro/2.0.8/oro-2.0.8-sources.jar" "sha256-+XfMzcf77NcWzewnc9VckYT+7BwUJ/sopg04pfUb9Zc=";
    sourceDirs = [ "." ];
    javaRelease = "1.6";
  };

  jdom-1 = mkJar {
    pname = "jdom";
    version = "1.1.3";
    src = fetchzip {
      url = "http://jdom.org/dist/binary/archive/jdom-1.1.3.tar.gz";
      hash = "sha256-Evy/i2ms+1UVisYqzO3sQJY1/FPRVu/vc6nUiAJ1baA=";
    };
    sourceDirs = [ "src/java" ];
    # XPath support needs jaxen.
    postPatch = ''
      rm -v src/java/org/jdom/xpath/JaxenXPath.java
    '';
    javaRelease = "1.6";
  };

  # JetBrains' generified JDOM 1, as used by IntelliJ (source shipped in
  # intellij-community as lib/src/jdom.zip).  Used for IntelliJ >= 173.
  jdom-ij = mkJar {
    pname = "jdom";
    version = "1.1-ij";
    src = fetchurl {
      url = "https://raw.githubusercontent.com/JetBrains/intellij-community/bbdf7628cceffbbe21523f4a7e120ab7b18cca3a/lib/src/jdom.zip";
      hash = "sha256-ylhp/1IcaSL4R/pwPN5bOOhrawgRNrjtCkHd1fsKens=";
    };
    unpackPhase = "mkdir src; cd src; unzip -q $src; cd ..";
    postPatch = "rm -f src/org/jdom/xpath/JaxenXPath.java";
    sourceDirs = [ "src" ];
    javaRelease = "1.6";
  };

  log4j-1 = mkJar {
    pname = "log4j";
    version = "1.2.17";
    src = fetchzip {
      url = "https://archive.apache.org/dist/logging/log4j/1.2.17/log4j-1.2.17.tar.gz";
      hash = "sha256-pZkTn0hADOGb3DCAQpMp8dXh7WZLuwiEIgVjluPzbD0=";
    };
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    # Drop appenders that need JMS, JavaMail or JMX.
    postPatch = ''
      cd src/main/java/org/apache/log4j
      rm -rv jmx or/jms net/JMS* net/SMTPAppender.java
      cd -
    '';
    javaRelease = "1.6";
  };

  jna = mkJar {
    pname = "jna";
    version = "4.5.1";
    src = gh "java-native-access" "jna" "4.5.1" "sha256-kP36wyRWPxjstso6vEqCfa/8e9nwpHxCuGmBviNs3m0=";
    sourceDirs = [ "src" ];
    javaRelease = "1.6";
  };

  jna-platform = mkJar {
    pname = "jna-platform";
    version = "4.5.1";
    inherit (self.jna) src;
    sourceDirs = [ "contrib/platform/src" ];
    deps = [ self.jna ];
    javaRelease = "1.6";
  };

  jsr166e-seqlock = mkJar {
    pname = "jsr166e-seqlock";
    version = "1.7";
    # The 2011 git mirror of the jsr166 CVS still has SequenceLock in the
    # jsr166e package; it later moved to jsr166e.extra, which IntelliJ uses.
    src = fetchurl {
      url = "https://raw.githubusercontent.com/dmlloyd/jsr166/bfaa61eb48588a1b6d1f7aa0dc9a1f3b11c618ee/src/jsr166e/SequenceLock.java";
      hash = "sha256-uRi6wQwCUI3NB7fKFH/DBc3MaT2pkM0U/ao7VAoL5fo=";
    };
    unpackPhase = ''
      mkdir -p src/jsr166e/extra
      sed 's/^package jsr166e;/package jsr166e.extra;/' $src > src/jsr166e/extra/SequenceLock.java
    '';
    javaRelease = "1.6";
  };

  # The git tag lacks the generated CoreMatchers class, the Maven sources jar
  # has it.
  hamcrest-core = mkJar {
    pname = "hamcrest-core";
    version = "1.3";
    src = sourcesJar "https://repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3-sources.jar" "sha256-H9riwZP8KTNtNS0GD+EwcWktjwmg+JbITvfKWLPb5/Q=";
    sourceDirs = [ "." ];
    javaRelease = "1.6";
  };

  junit4 = mkJar {
    pname = "junit";
    version = "4.12";
    src = gh "junit-team" "junit4" "r4.12" "sha256-EG3w77Y+lWxZ9pFnpWttLrqd+YyOJcRkRj/0G1LcCsk=";
    sourceDirs = [ "src/main/java" ];
    resourceDirs = [ "src/main/resources" ];
    deps = [ self.hamcrest-core ];
    javaRelease = "1.6";
  };

  xpp3 = mkJar {
    pname = "xpp3";
    version = "1.1.4c";
    src = sourcesJar "https://repo1.maven.org/maven2/xpp3/xpp3/1.1.4c/xpp3-1.1.4c-sources.jar" "sha256-9srskIJIcAGpFX1tOUGCS6S0RAAmgz1tK8HeM443DGo=";
    sourceDirs = [ "." ];
    copySourceResources = true;
    javaRelease = "1.6";
  };

  # Only the core of XStream; the optional drivers/converters for third
  # party libraries are removed.
  xstream = mkJar {
    pname = "xstream";
    version = "1.4.16";
    src = gh "x-stream" "xstream" "XSTREAM_1_4_16" "sha256-pRxsGQL7Wt6tUaqREHh2MGF0yYMVk7M7PdwJOAyrYpo=";
    sourceDirs = [ "xstream/src/java" ];
    deps = [ self.xpp3 ];
    javaRelease = "1.8";
    postPatch = ''
      cd xstream/src/java/com/thoughtworks/xstream
      grep -rlE 'import (org\.(dom4j|jdom|jdom2|codehaus\.jettison|joda|kxml2|json)|nu\.xom|com\.bea|net\.sf\.cglib|javax\.activation|com\.ctc|org\.codehaus\.woodstox)' . \
        | xargs -r rm -v
      rm -rf io/xml/Dom4J* io/xml/JDom* io/xml/Xom* io/xml/KXml2* io/xml/WstxDriver.java \
             io/xml/BEAStaxDriver.java io/json io/xml/MXParser*
      cd -
    '';
    
  };

  native-platform = mkJar {
    pname = "native-platform";
    version = "0.10";
    src = gh "gradle" "native-platform" "0.10" "sha256-CnaCc3T6snE+xzocy3UNl1Eba5Woc/VL8qLzSqqOkeQ=";
    sourceDirs = [ "src/main/java" ];
    javaRelease = "1.6";
  };

  jarjar = mkJar {
    pname = "jarjar";
    version = "1.4";
    src = fetchzip {
      url = "https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/jarjar/jarjar-src-1.4.zip";
      hash = "sha256-VqKBxW4Ox0KuT0k9dY+iOm1NCNyak8rPoMWp7uMzfSM=";
    };
    sourceDirs = [ "src/main" ];
    copySourceResources = true;
    postPatch = ''
      rm -rf lib src/main/com/tonicsystems/jarjar/JarJarMojo.java
    '';
    deps = [
      self.asm-6
      ant
    ];
    # Like upstream (and Guix), bundle ASM: the classpath of the Kotlin build
    # also has ASM 8, which lacks RemappingClassAdapter.
    mergeJars = [ "${self.asm-6}/share/java/asm.jar" ];
    javaRelease = "1.6";
  };

  # Used by Kotlin >= 1.1.3.  src-gen is produced by a Scala generator, but
  # committed to the repository.
  javaslang-match = mkJar {
    pname = "javaslang-match";
    version = "2.0.6";
    inherit (self.javaslang) src;
    sourceDirs = [ "javaslang-match/src/main/java" ];
    resourceDirs = [ "javaslang-match/src/main/resources" ];
    javaRelease = "1.8";
  };

  javaslang = mkJar {
    pname = "javaslang";
    version = "2.0.6";
    src = gh "vavr-io" "vavr" "javaslang-v2.0.6" "sha256-eetokjpRmePu9rSY7IAincqj47NoJuHZeYvR9LSmN4U=";
    sourceDirs = [
      "javaslang/src/main/java"
      "javaslang/src-gen/main/java"
    ];
    # There is a λ.java
    preBuild = "export LC_ALL=C.UTF-8";
    # Annotation processor generating the pattern classes
    buildDeps = [ self.javaslang-match ];
    javaRelease = "1.8";
  };

  ant-contrib = mkJar {
    pname = "ant-contrib";
    version = "1.0b3";
    src = fetchzip {
      url = "https://downloads.sourceforge.net/ant-contrib/ant-contrib/1.0b3/ant-contrib-1.0b3-src.tar.gz";
      hash = "sha256-WCHIFcrVvUpiizM+VhE1R6DDpB0VxmD/seLpgfSG9Kg=";
    };
    patches = [ ../../patches/tarcv/ant-contrib.patch ];
    sourceDirs = [ "src/java" ];
    copySourceResources = true;
    # Tasks needing BCEL, commons-httpclient or Ivy are dropped.
    postPatch = ''
      rm -rf lib
      grep -rlE 'import (org\.apache\.bcel|org\.apache\.commons\.httpclient|org\.apache\.ivy|fr\.jayasoft|org\.apache\.xerces|org\.apache\.xml\.serialize)' src/java | xargs -r rm -v
      rm -rf src/java/net/sf/antcontrib/net/httpclient src/java/net/sf/antcontrib/design src/java/net/sf/antcontrib/antserver
    '';
    # Drop the definitions of the removed tasks.
    postBuild = ''
      for f in build/classes/net/sf/antcontrib/antcontrib.properties build/classes/net/sf/antcontrib/antlib.xml; do
        [ -f $f ] || continue
        for c in $(grep -oE 'net\.sf\.antcontrib\.[A-Za-z0-9_.]+' $f | sort -u); do
          if [ ! -f "build/classes/''${c//.//}.class" ]; then
            echo "dropping $c from $f"
            sed -i "/''${c//./\\.}\b/d" $f
          fi
        done
      done
    '';
    deps = [ ant ];
    javaRelease = "1.6";
  };
})
