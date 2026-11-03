# The ANTLR bootstrap (needed by Groovy), after Guix:
#   antlr 2.7.7 -> StringTemplate 3 -> antlr 3.1 -> antlr 3.3 -> ST 4.0.6
#   -> antlr 3.5.2 (bootstrap) -> ST 4.0.8 -> antlr 3.5.2
#   -> antlr 4.1 -> tunnelvisionlabs antlr 4.7.4 (bootstrap) -> final
{
  lib,
  fetchurl,
  fetchzip,
  mkJar,
  jdk,
  writeShellScript,
  java,
  javaLib,
  icuData,
}:

let
  gh =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
      inherit hash;
    };
  p = n: ./patches + "/${n}.patch";

  # Add a bin/NAME wrapper running mainClass with the jar and its closure.
  withTool =
    name: mainClass: drv:
    drv.overrideAttrs (o: {
      postInstall = (o.postInstall or "") + ''
        mkdir -p $out/bin
        cat > $out/bin/${name} <<EOF
        #!/bin/sh
        exec ${jdk}/bin/java -cp $out/share/java/${o.pname}.jar:${
          javaLib.classpathOf (drv.passthru.javaDeps or [ ])
        } ${mainClass} "\$@"
        EOF
        chmod +x $out/bin/${name}
      '';
    });

  stResources = dir: ''
    (cd ${dir} && find . \( -name '*.stg' -o -name '*.st' -o -name '*.sti' -o -name 'STLexer.tokens' \) \
       -exec cp --parents -t $OLDPWD/build/classes {} +)
  '';
in
lib.fix (self: {
  antlr2 = withTool "antlr" "antlr.Tool" (mkJar {
    pname = "antlr2";
    version = "2.7.7";
    src = fetchurl {
      url = "https://www.antlr2.org/download/antlr-2.7.7.tar.gz";
      hash = "sha256-hTrrAhrvdYa9op50prAwBry1ZadVyGtmAy2Owxtn27k=";
    };
    postPatch = "rm -f antlr.jar";
    sourceDirs = [ "antlr" ];
    javaRelease = "1.6";
  });

  stringtemplate3 = mkJar {
    pname = "stringtemplate3";
    version = "3.2.1";
    src = fetchurl {
      url = "https://github.com/antlr/website-st4/raw/gh-pages/download/stringtemplate-3.2.1.tar.gz";
      hash = "sha256-Ogrbt1EMKCLKUVxjXh/xRps6x49tIHLkhHiHa5GR3iA=";
    };
    nativeBuildInputs = [ self.antlr2 ];
    preBuild = ''
      (cd src/org/antlr/stringtemplate/language && for f in template.g angle.bracket.template.g action.g eval.g group.g interface.g; do antlr $f; done)
    '';
    sourceDirs = [ "src" ];
    deps = [ self.antlr2 ];
    javaRelease = "1.6";
  };

  antlr3_1 = withTool "antlr3" "org.antlr.Tool" (mkJar {
    pname = "antlr3";
    version = "3.1";
    src = fetchurl {
      url = "https://github.com/antlr/website-antlr3/raw/gh-pages/download/antlr-3.1.tar.gz";
      hash = "sha256-35huYo45vlDS4hf7kZhQ9T6nEHvex0c+jPmtyxKr0Wk=";
    };
    patches = [ (p "antlr3-3_1-fix-java8-compilation") ];
    nativeBuildInputs = [ self.antlr2 ];
    preBuild = ''
      rm -r src/org/antlr/test
      d=src/org/antlr/tool
      for f in antlr.g antlr.print.g assign.types.g buildnfa.g define.g; do antlr -o $d $d/$f; done
      antlr -o src/org/antlr/codegen src/org/antlr/codegen/codegen.g
    '';
    sourceDirs = [
      "src"
      "runtime/Java/src"
    ];
    postBuild = stResources "src";
    deps = [
      self.stringtemplate3
      self.antlr2
    ];
    javaRelease = "1.6";
  });

  antlr3_3 = withTool "antlr3" "org.antlr.Tool" (mkJar {
    pname = "antlr3";
    version = "3.3";
    src = fetchurl {
      url = "https://github.com/antlr/website-antlr3/raw/gh-pages/download/antlr-3.3.tar.gz";
      hash = "sha256-dayTOJ1uv72Jlwp5+4TPYt9WhFLL3SSbaYGSqt8u72E=";
    };
    patches = [ (p "antlr3-3_3-fix-java8-compilation") ];
    nativeBuildInputs = [
      self.antlr2
      self.antlr3_1
    ];
    preBuild = ''
      sed -i 's/^import org.antlr.grammar.v2.\*;/import org.antlr.grammar.v2.*;\nimport org.antlr.grammar.v2.TreeToNFAConverter;\nimport org.antlr.grammar.v2.DefineGrammarItemsWalker;\nimport org.antlr.grammar.v2.ANTLRTreePrinter;/' \
        tool/src/main/java/org/antlr/tool/Grammar.java
      (cd tool/src/main/antlr2/org/antlr/grammar/v2 && for f in antlr.g antlr.print.g assign.types.g buildnfa.g codegen.g define.g; do antlr $f; done)
      (cd tool/src/main/antlr3/org/antlr/grammar/v3 && for f in ActionAnalysis.g ActionTranslator.g ANTLRv3.g ANTLRv3Tree.g; do antlr3 $f; done)
    '';
    sourceDirs = [
      "tool/src/main/java"
      "runtime/Java/src/main/java"
      "tool/src/main/antlr2"
      "tool/src/main/antlr3"
    ];
    postBuild = stResources "tool/src/main/resources";
    deps = [
      self.stringtemplate3
      self.antlr2
    ];
    javaRelease = "1.6";
  });

  mkST4 =
    {
      version,
      src,
      antlr3,
    }:
    mkJar {
      pname = "stringtemplate4";
      inherit version src;
      nativeBuildInputs = [ antlr3 ];
      preBuild = ''
        (cd src/org/stringtemplate/v4/compiler && for f in STParser.g Group.g CodeGenerator.g; do antlr3 $f; done)
      '';
      sourceDirs = [ "src" ];
      deps = [ antlr3 ];
      javaRelease = "1.6";
    };

  stringtemplate4_0_6 = self.mkST4 {
    version = "4.0.6";
    src = gh "antlr" "stringtemplate4" "ST-4.0.6" "sha256-LI7O/mOwGj2u4ef2HVCoxbPNw+j4FqlbX7q9XrAszqA=";
    antlr3 = self.antlr3_3;
  };

  mkAntlr3_5 =
    { antlr3, st4 }:
    withTool "antlr3" "org.antlr.Tool" (mkJar {
      pname = "antlr3";
      version = "3.5.2";
      src = gh "antlr" "antlr3" "3.5.2" "sha256-zt4GgGWB5NFcXheIOvV/nbfZsRQMzQwfnRD/KvNWTjE=";
      nativeBuildInputs = [ antlr3 ];
      preBuild = ''
        (cd tool/src/main/antlr3/org/antlr/grammar/v3/
         for f in ANTLR.g ANTLRTreePrinter.g ActionAnalysis.g AssignTokenTypesWalker.g ActionTranslator.g \
                  TreeToNFAConverter.g ANTLRv3.g ANTLRv3Tree.g LeftRecursiveRuleWalker.g CodeGenTreeWalker.g \
                  DefineGrammarItemsWalker.g; do antlr3 $f; done
         sed -i 's/public Object getTree/public GrammarAST getTree/' ANTLRParser.java
         sed -i 's/public Object getTree/public CommonTree getTree/' ANTLRv3Parser.java)
        sed -i 's/^import org.antlr.grammar.v3.\*;/import org.antlr.grammar.v3.*;\nimport org.antlr.grammar.v3.ANTLRTreePrinter;/' \
          tool/src/main/java/org/antlr/tool/LeftRecursiveRuleAnalyzer.java
        sed -i 's/case NO_SUCH_ATTRIBUTE_PASS_THROUGH://' tool/src/main/java/org/antlr/tool/ErrorManager.java
      '';
      sourceDirs = [
        "tool/src/main/java"
        "runtime/Java/src/main/java"
        "tool/src/main/antlr3"
      ];
      postBuild = stResources "tool/src/main/resources";
      deps = [
        self.stringtemplate3
        self.antlr2
        st4
      ];
      javaRelease = "1.6";
    });

  antlr3-bootstrap = self.mkAntlr3_5 {
    antlr3 = self.antlr3_3;
    st4 = self.stringtemplate4_0_6;
  };

  stringtemplate4 = self.mkST4 {
    version = "4.0.8";
    src = gh "antlr" "stringtemplate4" "4.0.8" "sha256-t/CtWkXWdIZ3GYFfPbJToYOpJ88Zhlxp+CauE3fvXtI=";
    antlr3 = self.antlr3-bootstrap;
  };

  antlr3 = self.mkAntlr3_5 {
    antlr3 = self.antlr3-bootstrap;
    st4 = self.stringtemplate4;
  };

  # Only used to generate antlr4's Unicode tables.  The data (icudata.jar) is
  # built from the Unicode data text files, see pkgs/development/java-modules/icu.
  icu4j = mkJar {
    pname = "icu4j";
    version = "70.1";
    src = icuData.src;
    sourceDirs = [ "icu4j/main/classes/core/src" ];
    copySourceResources = true;
    mergeJars = [ "${icuData}/share/java/icudata.jar" ];
    javaRelease = "1.8";
  };

  # antlr 4.1 is the closest version that does not need antlr4 to build.
  antlr4_1-src = gh "antlr" "antlr4" "4.1" "sha256-gZHNi2CYC1wE0F7WMMMHAFPT9n0dRAm3lwwVq0qvEMU=";

  antlr4-runtime_4_1 = mkJar {
    pname = "antlr4-runtime";
    version = "4.1";
    src = self.antlr4_1-src;
    sourceDirs = [ "runtime/Java/src/org" ];
    deps = [ self.treelayout ];
    javaRelease = "1.6";
  };

  mkAntlr4 =
    {
      version,
      src,
      runtime,
      extraDeps ? [ ],
      generateUnicode ? true,
      patches ? [ ],
    }:
    withTool "antlr4" "org.antlr.v4.Tool" (mkJar {
      pname = "antlr4";
      inherit version src patches;
      nativeBuildInputs = [ self.antlr3 ];
      preBuild =
        lib.optionalString generateUnicode ''
          export CLASSPATH="${
            javaLib.classpathOf (
              [
                self.antlr3
                runtime
                self.stringtemplate4
                self.treelayout
                self.icu4j
              ]
              ++ extraDeps
            )
          }"
          javac -cp "$CLASSPATH" -d gen-classes -nowarn \
            tool/src/org/antlr/v4/unicode/UnicodeRenderer.java \
            tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java 2>/dev/null \
          || { mkdir -p gen-classes; javac -cp "$CLASSPATH" -d gen-classes -nowarn \
                 tool/src/org/antlr/v4/unicode/UnicodeRenderer.java \
                 tool/src/org/antlr/v4/unicode/UnicodeDataTemplateController.java; }
          java -cp "$CLASSPATH:gen-classes:tool/src:runtime/Java" org.antlr.v4.unicode.UnicodeRenderer \
            tool/resources/org/antlr/v4/tool/templates unicodedata tool/src/org/antlr/v4/unicode/UnicodeData.java
          # It seems there is a bug with our ST4 (Guix)
          sed -i 's/\\>/>/g' tool/src/org/antlr/v4/unicode/UnicodeData.java
          rm tool/src/org/antlr/v4/unicode/UnicodeRenderer.java
        ''
        + ''
          (cd tool/src/org/antlr/v4/parse
           for f in ANTLRLexer.g ANTLRParser.g BlockSetTransformer.g GrammarTreeVisitor.g ATNBuilder.g \
                    ActionSplitter.g LeftRecursiveRuleWalker.g; do antlr3 $f; done)
          (cd tool/src/org/antlr/v4/codegen && cp ../parse/ANTLRParser.tokens . && antlr3 SourceGenTriggers.g)
        '';
      sourceDirs = [ "tool/src" ];
      resourceDirs = [ "tool/resources" ];
      deps = [
        self.antlr3
        runtime
        self.stringtemplate4
        self.treelayout
      ]
      ++ extraDeps;
      buildDeps = lib.optional generateUnicode self.icu4j;
      javaRelease = "1.8";
    });

  antlr4_1 = self.mkAntlr4 {
    version = "4.1";
    src = self.antlr4_1-src;
    runtime = self.antlr4-runtime_4_1;
    generateUnicode = false;
  };

  # Groovy uses the "optimized" fork of antlr4 by tunnelvisionlabs.
  tvl-src =
    gh "tunnelvisionlabs" "antlr4" "4.7.4-opt"
      "sha256-KC+rcn2l0n8IUleuTMVoFpTL70CqDjE1VfF+rfemwtU=";
  tvl-patches = [
    (p "java-antlr4-Add-standalone-generator")
    (p "java-tunnelvisionlabs-antlr-code-too-large")
  ];

  tvl-antlr4-runtime-annotations = mkJar {
    pname = "antlr4-runtime-annotations";
    version = "4.7.4";
    src = self.tvl-src;
    patches = self.tvl-patches;
    sourceDirs = [ "runtime/JavaAnnotations/src" ];
    resourceDirs = [ "runtime/JavaAnnotations/resources" ];
    javaRelease = "1.8";
  };

  # The runtime needs a lexer generated by antlr4, and antlr4 needs this
  # runtime: generate it with antlr 4.1 first, then again with the result.
  mkTvlRuntime =
    antlr4:
    mkJar {
      pname = "antlr4-runtime";
      version = "4.7.4";
      src = self.tvl-src;
      patches = self.tvl-patches;
      nativeBuildInputs = [ antlr4 ];
      preBuild = ''
        antlr4 -lib runtime/Java/src/org/antlr/v4/runtime/tree/xpath -visitor -no-listener \
          -package org.antlr.v4.runtime.tree.xpath runtime/Java/src/org/antlr/v4/runtime/tree/xpath/XPathLexer.g4
        # Generated code is for an incompatible version of the runtime
        sed -i 's/LexerATNSimulator(this,_ATN,_decisionToDFA,_sharedContextCache)/LexerATNSimulator(this,_ATN)/' \
          runtime/Java/src/org/antlr/v4/runtime/tree/xpath/XPathLexer.java
      '';
      sourceDirs = [ "runtime/Java/src" ];
      resourceDirs = [ "runtime/Java/src/main/dot" ];
      buildDeps = [ self.tvl-antlr4-runtime-annotations ];
      javaRelease = "1.8";
    };

  tvl-antlr4-runtime-bootstrap = self.mkTvlRuntime self.antlr4_1;
  tvl-antlr4-bootstrap = self.mkAntlr4 {
    version = "4.7.4";
    src = self.tvl-src;
    patches = self.tvl-patches;
    runtime = self.tvl-antlr4-runtime-bootstrap;
    extraDeps = [ self.tvl-antlr4-runtime-annotations ];
  };
  tvl-antlr4-runtime = self.mkTvlRuntime self.tvl-antlr4-bootstrap;
  tvl-antlr4 = self.mkAntlr4 {
    version = "4.7.4";
    src = self.tvl-src;
    patches = self.tvl-patches;
    runtime = self.tvl-antlr4-runtime;
    extraDeps = [ self.tvl-antlr4-runtime-annotations ];
  };

  treelayout = mkJar {
    pname = "treelayout";
    version = "1.0.3";
    src = gh "abego" "treelayout" "v1.0.3" "sha256-U/Ud2+Cb8Qodm9tF56F7tw0HXT8wzp0/sMCHlShGvqI=";
    sourceDirs = [ "org.abego.treelayout/src/main/java" ];
    javaRelease = "1.6";
  };
})
