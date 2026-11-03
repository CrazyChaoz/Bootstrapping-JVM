# Apache Groovy 3 from source (the version Gradle 8.x bundles), JDK 21.
#   javac-only bootstrap compiler -> joint (groovy+java) compile of the core
#   -> DGM info -> repackaging of ASM/ANTLR4/picocli with jarjar
#   -> subprojects compiled with that core.
# Not done: bridger (adds bridge methods to a few classes), grooid, the OSGi manifest.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  classpathOf,
  closureOf,
  mk,
  gh,
  java,
  antlr,
  gradleLibs,
  javacc,
  qdox-1_12,
  version ? "3.0.24",
}:

let
  src = gh "apache" "groovy" "GROOVY_${
    lib.replaceStrings [ "." ] [ "_" ] version
  }" "sha256-YrorzpTNQSgMVpLpB3L+JwIten7Dbay7ussbNtEqHvs=";

  self = lib.fix (s: {
    picocli = mk {
      pname = "picocli";
      version = "4.7.7";
      src = gh "remkop" "picocli" "v4.7.7" "sha256-srgcsSw0jDtn/670yJD3Hwj2MamvLmI4DQxrB526RkI=";
      sourceDirs = [ "src/main/java" ];
    };

    deps = [
      gradleLibs.asm
      gradleLibs.asm-tree
      gradleLibs.asm-commons
      gradleLibs.asm-analysis
      gradleLibs.asm-util
      gradleLibs.antlr2
      antlr.tvl-antlr4-runtime
      antlr.tvl-antlr4-runtime-annotations
      s.picocli
      gradleLibs.ivy
      gradleLibs.jansi
      gradleLibs.findbugs-stub
      java.xstream
      java.jsr305
    ];

    generateParsers = ''
      # antlr 2: the old parser and the Java parser
      mkdir -p gen/org/codehaus/groovy/antlr/parser gen/org/codehaus/groovy/antlr/java
      java -cp ${classpathOf [ gradleLibs.antlr2 ]} antlr.Tool \
        -o gen/org/codehaus/groovy/antlr/parser src/main/antlr2/org/codehaus/groovy/antlr/groovy.g
      java -cp ${classpathOf [ gradleLibs.antlr2 ]} antlr.Tool \
        -o gen/org/codehaus/groovy/antlr/java src/main/antlr2/org/codehaus/groovy/antlr/java/java.g
      # antlr 4: the Parrot parser
      mkdir -p gen/org/apache/groovy/parser/antlr4
      (cd src/antlr && java -cp ${
        classpathOf [ antlr.tvl-antlr4 ]
      } org.antlr.v4.Tool -package org.apache.groovy.parser.antlr4 -visitor -no-listener \
        -o ../../gen/org/apache/groovy/parser/antlr4 GroovyLexer.g4 GroovyParser.g4)
      rm -f gen/org/apache/groovy/parser/antlr4/*.tokens gen/org/apache/groovy/parser/antlr4/*.interp
    '';

    # Javac only: enough to compile the groovy sources afterwards.
    groovy-java-bootstrap = mk {
      pname = "groovy-java-bootstrap";
      inherit version src;
      preBuild = s.generateParsers;
      sourceDirs = [
        "src/main/java"
        "subprojects/parser-antlr4/src/main/java"
        "gen"
      ];
      deps = s.deps;
      mainClass = "groovy.ui.GroovyMain";
    };

    # Joint compile of Groovy and Java sources with the bootstrap compiler.
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
        extraSrc ? src,
        repackage ? false,
      }:
      stdenv.mkDerivation {
        inherit pname version;
        src = extraSrc;
        nativeBuildInputs = [
          jdk
          zip
          unzip
          stripJavaArchivesHook
        ]
        ++ nativeBuildInputs;
        buildPhase = ''
          runHook preBuild
          export CLASSPATH="${classpathOf ([ compiler ] ++ deps)}"
          mkdir -p build/classes
          ${preBuild}
          : > build/sources
          for d in ${lib.escapeShellArgs sourceDirs}; do
            [ -d "$d" ] && find "$d" \( -name '*.groovy' -o -name '*.java' \) >> build/sources
          done
          sort -o build/sources build/sources
          echo "compiling $(wc -l < build/sources) files"
          java -Xmx3g -cp "$CLASSPATH" org.codehaus.groovy.tools.FileSystemCompiler \
            -cp "$CLASSPATH" -d build/classes -j -Jsource=8 -Jtarget=8 $(cat build/sources)
          for d in ${lib.escapeShellArgs resourceDirs}; do
            [ -d "$d" ] && cp -r "$d"/. build/classes/
          done
          ${postBuild}
          runHook postBuild
        '';
        installPhase = ''
          mkdir -p $out/share/java
          jar cf $out/share/java/${pname}.jar -C build/classes .
          ${lib.optionalString repackage ''
            printf 'rule antlr.** groovyjarjarantlr.@1\nrule org.antlr.** groovyjarjarantlr4.@1\nrule org.objectweb.** groovyjarjarasm.@1\nrule picocli.** groovyjarjarpicocli.@1\n' > rules
            java -cp ${java.jarjar}/share/java/jarjar.jar:${classpathOf [ java.jarjar ]} \
              com.tonicsystems.jarjar.Main process rules $out/share/java/${pname}.jar $TMPDIR/repackaged.jar
            mv $TMPDIR/repackaged.jar $out/share/java/${pname}.jar
          ''}
        '';
        passthru.javaDeps = closureOf deps;
      };

    # groovy-core before repackaging (ASM, ANTLR4 and picocli still separate)
    groovy-core-raw = s.mkGroovyJar {
      pname = "groovy-raw";
      compiler = s.groovy-java-bootstrap;
      deps = s.deps;
      preBuild = s.generateParsers;
      sourceDirs = [
        "src/main/java"
        "src/main/groovy"
        "subprojects/parser-antlr4/src/main/java"
        "gen"
      ];
      resourceDirs = [ "src/resources" ];
      postBuild = ''
        mkdir -p dgm/META-INF
        java -cp "$CLASSPATH:build/classes" -Dgroovy.target.bytecode=1.8 \
          org.codehaus.groovy.tools.DgmConverter --info dgm
        cp -r dgm/. build/classes/
        cat > build/classes/META-INF/groovy-release-info.properties <<EOF
        ImplementationVersion=${version}
        BundleVersion=${version}
        BuildDate=01-Jan-1980
        BuildTime=12:00 AM
        EOF
      '';
    };

    javaparser-core = mk {
      pname = "javaparser-core";
      version = "3.28.0";
      src =
        gh "javaparser" "javaparser" "javaparser-parent-3.28.0"
          "sha256-fzkYSAxN1ziFmDwSX77B/BLQv3xNOclWBsqJKzkFtDc=";
      nativeBuildInputs = [ javacc ];
      preBuild = ''
        cd javaparser-core/src/main
        cp java-templates/com/github/javaparser/JavaParserBuild.java java/com/github/javaparser/
        sed -i -e 's/''${project.version}/3.28.0/' -e 's/''${project.name}/javaparser/' \
               -e 's/''${project.build.finalName}/javaparser/; s/''${[a-z.]*}/unknown/g' \
               java/com/github/javaparser/JavaParserBuild.java
        # JavaCC 7.0.4 cannot parse diamonds in action code (upstream uses ph-javacc)
        sed -i 's/new \([A-Za-z.]*\)<>(/new \1(/g' javacc/java.jj
        (cd java && java -cp ${javacc}/share/java/javacc.jar javacc ../javacc/java.jj)
        cp -r javacc-support/. java/
        cd -
      '';
      sourceDirs = [ "javaparser-core/src/main/java" ];
      useRelease = true; # JDK 21's List.getFirst() clashes with NodeList's
    };

    subproject =
      name:
      {
        deps ? [ ],
        preBuild ? "",
      }:
      s.mkGroovyJar {
        pname = name;
        compiler = s.groovy-core-raw;
        deps = [
          s.groovy-core-raw
          gradleLibs.findbugs-stub
          gradleLibs.asm
          gradleLibs.asm-tree
          gradleLibs.asm-analysis
          gradleLibs.asm-util
          gradleLibs.asm-commons
          gradleLibs.antlr2
          antlr.tvl-antlr4-runtime
          antlr.tvl-antlr4-runtime-annotations
          s.picocli
        ]
        ++ deps;
        inherit preBuild;
        repackage = true;
        sourceDirs = [
          "subprojects/${name}/src/main/java"
          "subprojects/${name}/src/main/groovy"
        ];
        resourceDirs = [ "subprojects/${name}/src/main/resources" ];
      };

    groovy-xml = s.subproject "groovy-xml" { };
    groovy-json = s.subproject "groovy-json" { };
    groovy-nio = s.subproject "groovy-nio" { };
    groovy-sql = s.subproject "groovy-sql" { };
    groovy-swing = s.subproject "groovy-swing" { };
    groovy-console = s.subproject "groovy-console" {
      deps = [
        s.groovy-swing
        s.groovy-templates
        s.groovy-xml
        antlr.tvl-antlr4
      ];
    };
    groovy-test = s.subproject "groovy-test" { deps = [ gradleLibs.junit4 ]; };
    groovy-datetime = s.subproject "groovy-datetime" { };
    groovy-dateutil = s.subproject "groovy-dateutil" { };
    groovy-astbuilder = s.subproject "groovy-astbuilder" { };
    groovy-templates = s.subproject "groovy-templates" { deps = [ s.groovy-xml ]; };
    groovy-docgenerator = s.subproject "groovy-docgenerator" {
      deps = [
        s.groovy-templates
        s.groovy-xml
        qdox-1_12
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
        gradleLibs.ant
        s.groovy-xml
        s.groovy-groovydoc
      ];
    };

    # ASM, ANTLR4 and picocli repackaged into the jar (groovyjarjar*), like upstream
    groovy-core = stdenv.mkDerivation {
      pname = "groovy";
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [
        jdk
        zip
        unzip
        stripJavaArchivesHook
      ];
      buildPhase = ''
        mkdir -p merged
        cd merged
        unzip -qo ${s.groovy-core-raw}/share/java/groovy-raw.jar
        for j in ${gradleLibs.asm} ${gradleLibs.asm-tree} ${gradleLibs.asm-commons} ${gradleLibs.asm-analysis} \
                 ${gradleLibs.antlr2} ${antlr.tvl-antlr4-runtime} ${antlr.tvl-antlr4-runtime-annotations} ${s.picocli}; do
          unzip -qo $j/share/java/*.jar -x 'META-INF/*' 'module-info.class'
        done
        unzip -qo ${gradleLibs.asm-util}/share/java/asm-util.jar \
          'org/objectweb/asm/util/Printer.class' 'org/objectweb/asm/util/Textifier*' \
          'org/objectweb/asm/util/ASMifier.class' 'org/objectweb/asm/util/Trace*'
        cd ..
        jar cf merged.jar -C merged .
        cat > rules <<EOF
        rule antlr.** groovyjarjarantlr.@1
        rule org.antlr.** groovyjarjarantlr4.@1
        rule org.objectweb.** groovyjarjarasm.@1
        rule picocli.** groovyjarjarpicocli.@1
        EOF
        java -cp ${java.jarjar}/share/java/jarjar.jar:${classpathOf [ java.jarjar ]} \
          com.tonicsystems.jarjar.Main process rules merged.jar groovy.jar
      '';
      installPhase = ''
        mkdir -p $out/share/java
        cp groovy.jar $out/share/java/groovy.jar
      '';
      passthru.javaDeps = closureOf [
        gradleLibs.ivy
        gradleLibs.jansi
        java.xstream
      ];
    };
  });
in
self
