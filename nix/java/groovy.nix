# Apache Groovy from source, after Guix' gnu/packages/groovy.scm:
#   javac-only bootstrap -> joint (groovy+java) compile of the core with it
#   -> subprojects compiled with that core.
{
  lib,
  stdenv,
  fetchurl,
  fetchzip,
  mkJar,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  ant,
  java,
  antlr,
  javaLib,
  version ? "3.0.5",
  hash ? "sha256-1aZTzpwfRmLNyqL+LQ63NZk2+AfWeAf7UMOyKjs2pQA=",
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };

  src = gh "apache" "groovy" "GROOVY_${lib.replaceStrings [ "." ] [ "_" ] version}" hash;
  patches = lib.optional (
    version == "3.0.5"
  ) ../../patches/guix/groovy-add-exceptionutilsgenerator.patch;

  generateParsers = ''
    (cd src/main/antlr2/org/codehaus/groovy/antlr/java && antlr java.g)
    (cd src/main/antlr2/org/codehaus/groovy/antlr && mkdir -p parser && cd parser && antlr ../groovy.g)
    antlr4 -lib src/antlr -package org.apache.groovy.parser.antlr4 -visitor -no-listener src/antlr/GroovyLexer.g4
    antlr4 -lib src/antlr -package org.apache.groovy.parser.antlr4 -visitor -no-listener src/antlr/GroovyParser.g4
  '';

  self = lib.fix (s: {
    picocli = mkJar {
      pname = "picocli";
      version = "4.3.2";
      src = gh "remkop" "picocli" "v4.3.2" "sha256-bCimZp0gV+ilCNyQRx4vdfbdSmhjkeApSk0+J3s2t+s=";
      sourceDirs = [ "src/main/java" ];
      javaRelease = "1.8";
    };

    commons-cli = mkJar {
      pname = "commons-cli";
      version = "1.4";
      src = fetchurl {
        url = "https://archive.apache.org/dist/commons/cli/source/commons-cli-1.4-src.tar.gz";
        hash = "sha256-od742U5P5r5P/eEAp0pkf+PfW6AvhePJGR+7AL6IDxY=";
      };
      sourceDirs = [ "src/main/java" ];
      javaRelease = "1.8";
    };

    servletapi = mkJar {
      pname = "servletapi";
      version = "3.0.1";
      src = fetchurl {
        url = "mirror://gnu/classpathx/servletapi/servletapi-3.0.1.tar.gz";
        hash = "sha256-HTgn5VduA4nBky5KovoKeGkRJhRHZTeGE+pFHQqAqB0=";
      };
      sourceDirs = [ "source" ];
      copySourceResources = true;
      javaRelease = "1.8";
    };

    # Repository plugins needing third party libraries are dropped.
    ivy = mkJar {
      pname = "ivy";
      version = "2.4.0";
      src = fetchurl {
        url = "https://archive.apache.org/dist/ant/ivy/2.4.0/apache-ivy-2.4.0-src.tar.gz";
        hash = "sha256-IC8IykH0vfHAgaqLLlMVZb5sc+nl4NaBN/RU8U6xbvY=";
      };
      postPatch = ''
        rm -rf src/example
        cd src/java/org/apache/ivy
        rm -rf plugins/repository/vfs plugins/repository/ssh plugins/repository/sftp \
               plugins/resolver/VfsResolver.java plugins/resolver/SshResolver.java \
               plugins/resolver/SFTPResolver.java plugins/resolver/AbstractSshBasedResolver.java \
               plugins/signer/bouncycastle util/url/HttpClientHandler.java
        cd -
        grep -rlE 'import (org\.apache\.commons\.(httpclient|vfs)|com\.jcraft|org\.bouncycastle)' src/java | xargs -r rm -v || true
      '';
      sourceDirs = [ "src/java" ];
      copySourceResources = true;
      deps = [
        ant
        java.jakarta-oro
      ];
      postBuild = "mkdir -p build/classes/META-INF; cp META-INF/MANIFEST.MF build/classes/META-INF/ || true";
      javaRelease = "1.8";
    };

    # JavaCC is written with JavaCC.  Seed: the Maven sources jar of 7.0.4,
    # which contains the generated parsers as plain Java; then JavaCC is
    # rebuilt from git with the seed, regenerating them from the grammars.
    javacc-seed = mkJar {
      pname = "javacc";
      version = "7.0.4-seed";
      src = fetchzip {
        url = "https://repo1.maven.org/maven2/net/java/dev/javacc/javacc/7.0.4/javacc-7.0.4-sources.jar";
        hash = "sha256-rumrnr144u61SIiqTTzFpv/7twGiEE3DzKpHHONsEx4=";
        extension = "zip";
      };
      postPatch = "rm -rf bin; find . -name '*.class' -delete";
      sourceDirs = [
        "src/main/java"
        "src/main/generated-sources"
      ];
      resourceDirs = [ "src/main/resources" ];
      javaRelease = "1.8";
    };

    javacc = stdenv.mkDerivation {
      pname = "javacc";
      version = "7.0.4";
      src = gh "javacc" "javacc" "7.0.4" "sha256-MfXuyBA7/OUnmVzETEREWYIHADb+ZVlEfiOp9sZUc6I=";
      nativeBuildInputs = [
        jdk
        ant
        stripJavaArchivesHook
      ];
      postPatch = "rm -rf bootstrap lib";
      buildPhase = ''
        ant -Dbootstrap-jar=${s.javacc-seed}/share/java/javacc.jar jar
      '';
      installPhase = ''
        install -Dm644 target/javacc.jar $out/share/java/javacc.jar
        mkdir -p $out/bin
        printf '#!/bin/sh\nexec ${jdk}/bin/java -cp %s/share/java/javacc.jar "$(basename "$0")" "$@"\n' $out > $out/bin/javacc
        chmod +x $out/bin/javacc
      '';
    };

    javaparser-core = mkJar {
      pname = "javaparser-core";
      version = "3.16.1";
      src =
        gh "javaparser" "javaparser" "javaparser-parent-3.16.1"
          "sha256-aVfF9+pxnSUIUtCCa4AI0t2dxgGqbeSBcmEo50SYkqg=";
      nativeBuildInputs = [ s.javacc ];
      preBuild = ''
        cd javaparser-core/src/main
        cp java-templates/com/github/javaparser/JavaParserBuild.java java/com/github/javaparser/
        sed -i -e 's/''${project.version}/3.16.1/; s/''${project.name}/javaparser/' \
               -e 's/''${project.build.finalName}/javaparser/; s/''${[a-z.]*}/unknown/g' \
               java/com/github/javaparser/JavaParserBuild.java
        (cd java && java -cp ${s.javacc}/share/java/javacc.jar javacc ../javacc/java.jj)
        cp -r javacc-support/. java/
        cd -
      '';
      sourceDirs = [ "javaparser-core/src/main/java" ];
      javaRelease = "1.8";
    };

    qdox-1_12 = mkJar {
      pname = "qdox";
      version = "1.12.1";
      src = fetchzip {
        url = "https://repo1.maven.org/maven2/com/thoughtworks/qdox/qdox/1.12.1/qdox-1.12.1-sources.jar";
        hash = "sha256-YKtNKPhgGGccxc3cbIbQJujlhSonf/q9pF6Fzsf+isc=";
        stripRoot = false;
        extension = "zip";
      };
      postPatch = "rm -rf com/thoughtworks/qdox/junit";
      sourceDirs = [ "." ];
      deps = [ ant ];
      javaRelease = "1.8";
    };

    deps = [
      antlr.antlr2
      antlr.tvl-antlr4-runtime
      antlr.tvl-antlr4-runtime-annotations
      java.asm-8
      s.servletapi
      s.commons-cli
      java.jansi-1
      java.jline-2
      s.picocli
      java.xstream
    ];

    # Javac only: enough to compile the groovy sources afterwards.
    groovy-java-bootstrap = mkJar {
      pname = "groovy-java-bootstrap";
      inherit version src patches;
      nativeBuildInputs = [
        antlr.antlr2
        antlr.tvl-antlr4
      ];
      preBuild = generateParsers;
      sourceDirs = [
        "src/main/java"
        "src/main/antlr2"
        "subprojects/parser-antlr4/src/main/java"
        "src/antlr"
      ];
      deps = s.deps;
      buildDeps = [ java.jsr305 ];
      postBuild = ''
        javac -nowarn -cp "$CLASSPATH" -source 1.8 -target 1.8 -d gen config/ant/src/org/codehaus/groovy/ExceptionUtilsGenerator.java
        java -cp "$CLASSPATH:gen" org.codehaus.groovy.ExceptionUtilsGenerator \
          build/classes/org/codehaus/groovy/runtime/ExceptionUtils.class
      '';
      mainClass = "groovy.ui.GroovyMain";
      javaRelease = "1.8";
    };

    # Joint compile of Groovy and Java sources with FileSystemCompiler.
    mkGroovyJar =
      {
        pname,
        compiler,
        sourceDirs,
        deps ? [ ],
        resourceDirs ? [ ],
        preBuild ? "",
        postBuild ? "",
        nativeBuildInputs ? [ ],
      }:
      stdenv.mkDerivation {
        inherit
          pname
          version
          src
          patches
          ;
        nativeBuildInputs = [
          jdk
          zip
          unzip
          stripJavaArchivesHook
        ]
        ++ nativeBuildInputs;
        buildPhase = ''
          runHook preBuild
          export CLASSPATH="${javaLib.classpathOf ([ compiler ] ++ deps)}"
          mkdir -p build/classes
          ${preBuild}
          : > build/sources
          for d in ${lib.escapeShellArgs sourceDirs}; do
            [ -d "$d" ] && find "$d" \( -name '*.groovy' -o -name '*.java' \) >> build/sources
          done
          sort -o build/sources build/sources
          echo "compiling $(wc -l < build/sources) files"
          java -Xmx2g -cp "$CLASSPATH" org.codehaus.groovy.tools.FileSystemCompiler \
            -cp "$CLASSPATH" -d build/classes -j -Jsource=1.8 -Jtarget=1.8 $(cat build/sources)
          for d in ${lib.escapeShellArgs resourceDirs}; do
            [ -d "$d" ] && cp -r "$d"/. build/classes/
          done
          ${postBuild}
          runHook postBuild
        '';
        installPhase = ''
          mkdir -p $out/share/java
          jar cf $out/share/java/${pname}.jar -C build/classes .
        '';
        passthru.javaDeps = javaLib.closureOf deps;
      };

    groovy-core = s.mkGroovyJar {
      pname = "groovy";
      compiler = s.groovy-java-bootstrap;
      deps = s.deps ++ [
        s.ivy
        java.jsr305
      ];
      nativeBuildInputs = [
        antlr.antlr2
        antlr.tvl-antlr4
      ];
      preBuild = generateParsers + ''
        javac -nowarn -cp "$CLASSPATH" -source 1.8 -target 1.8 -d gen config/ant/src/org/codehaus/groovy/ExceptionUtilsGenerator.java
        mkdir -p build/classes/org/codehaus/groovy/runtime build/classes/META-INF
        java -cp "$CLASSPATH:gen" org.codehaus.groovy.ExceptionUtilsGenerator \
          build/classes/org/codehaus/groovy/runtime/ExceptionUtils.class
        javac -nowarn -cp "$CLASSPATH" -source 1.8 -target 1.8 -d gen src/main/java/org/codehaus/groovy/tools/DgmConverter.java
        # DgmConverter writes to target/classes
        mkdir -p target/classes/org/codehaus/groovy/runtime target/classes/META-INF
        java -cp "$CLASSPATH:gen" org.codehaus.groovy.tools.DgmConverter
        cp -r target/classes/. build/classes/
        (cd src/main/java && find . \( -name '*.txt' -o -name '*.properties' -o -name '*.xml' -o -name '*.html' \) \
           -exec cp --parents -t ../../../build/classes {} +)
      '';
      sourceDirs = [
        "src/main"
        "subprojects/parser-antlr4/src/main/java"
        "src/antlr"
      ];
      resourceDirs = [ "src/resources" ];
    };

    subproject =
      name:
      {
        deps ? [ ],
        preBuild ? "",
      }:
      s.mkGroovyJar {
        pname = name;
        compiler = s.groovy-core;
        deps = [ s.groovy-core ] ++ deps;
        inherit preBuild;
        sourceDirs = [
          "subprojects/${name}/src/main/java"
          "subprojects/${name}/src/main/groovy"
        ];
        resourceDirs = [ "subprojects/${name}/src/main/resources" ];
      };

    removeFindbugs = dir: ''
      find ${dir} -name '*.java' -exec sed -i \
        -e '/import edu.umd.cs.findbugs.annotations.SuppressFBWarnings;/d' \
        -e 's/@SuppressFBWarnings.*//' {} +
    '';

    groovy-test = s.subproject "groovy-test" { deps = [ java.junit4 ]; };
    groovy-xml = s.subproject "groovy-xml" { };
    groovy-templates = s.subproject "groovy-templates" {
      deps = [ s.groovy-xml ];
      preBuild = s.removeFindbugs "subprojects/groovy-templates";
    };
    groovy-json = s.subproject "groovy-json" { };
    groovy-nio = s.subproject "groovy-nio" { };
    groovy-datetime = s.subproject "groovy-datetime" { };
    groovy-dateutil = s.subproject "groovy-dateutil" { };
    groovy-sql = s.subproject "groovy-sql" { };
    groovy-astbuilder = s.subproject "groovy-astbuilder" { };
    groovy-docgenerator = s.subproject "groovy-docgenerator" {
      deps = [
        s.groovy-templates
        s.groovy-xml
        s.qdox-1_12
      ];
    };
    groovy-groovydoc = s.subproject "groovy-groovydoc" {
      deps = [
        s.groovy-templates
        s.groovy-xml
        s.groovy-docgenerator
        s.javaparser-core
      ];
    };
    groovy-ant = s.subproject "groovy-ant" {
      deps = [
        ant
        s.groovy-xml
        s.groovy-groovydoc
        java.junit4
      ];
      preBuild = s.removeFindbugs "subprojects/groovy-ant";
    };
  });
in
self
