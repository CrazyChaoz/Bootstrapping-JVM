# The Kotlin bootstrap chain, from Kotlin 0.6.786 (the last version without
# any Kotlin sources) to 1.1.2-5, each version compiled by the previous one.
#
# The build path, patches and tweaks are those of TarCV/kotlin-guix (which
# extends ebourg/kotlin-bootstrapping and Julien Lepiller's guix-android).
{
  lib,
  stdenv,
  callPackage,
  mkJar,
  jdk,
  ant,
  java,
  intellij,
  kotlinSources,
  kotlinLibs,
  javaLib,
  antlr,
}:

let
  inherit (callPackage ./mk-kotlin.nix { }) mkKotlin stepOps;
  ops = stepOps;

  jar = d: "${d}/share/java/${d.pname}.jar";

  # Symlink the main jar of each derivation into `dir`.
  linkJars = dir: drvs: ''
    mkdir -p ${dir}
    ${lib.concatMapStringsSep "\n" (d: "ln -sf ${jar d} ${dir}/") drvs}
  '';

  # The set of inputs (Guix "native-inputs") for a given IntelliJ SDK.
  inputsFor =
    sdk: extra:
    {
      inherit ant;
      inherit (java)
        ant-contrib
        cli-parser
        javax-inject
        ;
      jline = java.jline-2;
      guava = java.guava-20;
      protobuf = java.protobuf.java-2_5;
      annotations = sdk.annotations;
      javac2 = sdk.javac2;
      core = sdk.core;
      jps-model-impl = sdk.jps-model-impl;
    }
    // extra;

  # Kotlin 1.x needed external nullability annotations for the JDK until
  # platform types; these are those of 0.6.2338, patched for 0.6.2451+.
  jdk-annotations = mkJar {
    pname = "kotlin-jdk-annotations";
    version = "0.6.2338";
    src = kotlinSources."0.6.2338";
    patches = map (n: ../../patches/tarcv + "/${n}") [
      "kotlin-0.6.2338.patch"
      "kotlin-annotations-0.6.2338.patch"
    ];
    sourceDirs = [ ];
    resourceDirs = [ "jdk-annotations" ];
  };

  # Steps of the first stage, taken over by all later ones.
  baseSteps =
    inputs:
    let
      s = {
        remove-js-compiler-cli = "rm -r compiler/cli/src/org/jetbrains/jet/cli/js";
        remove-js-compiler = ''
          rm -r js
          mkdir -p js/js.translator/lib js/js.translator/src
        '';
        # 'level' should work even for targets enabling 'compress'
        fix-jar-task = ''
          regex-edit --lines --all '<(jar|jarjar) ' '<\1 level="0" modificationtime="0" ' build.xml
        '';
        # (the names of several versions: each one only where present)
        remove-targets = ''
          for t in android-compiler-plugin androidSdkAnnotations android-sdk-annotations compilerSources \
                   compiler-sources daemon-client j2kConverter jslib runtime_sources; do
            regex-edit --lines --all --optional ",$t(,|\")" '\1' build.xml
          done
        '';
        # fix non-deterministic bytecode generation caused by random iteration
        # order of basic hash maps and sets
        fix-value-order = ''
          find . -type f \( -name '*.java' -o -name '*.kt' \) -print0 \
            | xargs -0 regex-edit --lines --all --optional '([^_A-Za-z0-9]|new)Hash(Map|Set)' '\1LinkedHash\2'
          find . -depth -type f -regextype posix-extended -regex '.*/(|.*[^_[:alnum:]]|new)Hash(Map|Set)[^/]*' -print \
            | while read -r f; do
                d=$(dirname "$f"); b=$(basename "$f")
                mv -v "$f" "$d/''${b//Hash/LinkedHash}"
              done
        '';
        disable-classpath-from-env = ''
          regex-edit '(<project[^>]+>)' '\1<property name="build.sysclasspath" value="ignore"/>' build.xml
        '';
        update-asm = ''
          srcs() { find . -type f \( -name '*.java' -o -name '*.kt' \) -print0; }
          srcs | xargs -0 regex-edit --lines --all --optional '([^A-Za-z0-9])org\.jetbrains\.asm4([^A-Za-z0-9])' '\1org.jetbrains.org.objectweb.asm\2'
          srcs | xargs -0 regex-edit --lines --optional '(new InstructionAdapter\()(.+\)\s+\{\s*)$' '\1org.jetbrains.org.objectweb.asm.Opcodes.ASM4, \2'
          srcs | xargs -0 regex-edit --lines --optional '(new MethodNode\()(.+\)\s+\{\s*)$' '\1org.jetbrains.org.objectweb.asm.Opcodes.ASM4, \2'
        '';
        # build.xml expects exact file names in dependencies directory
        prepare-ant-lib = ''
          mkdir -p dependencies
          ln -s ${ant}/share/ant/lib/ant.jar dependencies/ant.jar
        '';
        prepare-dependencies = ''
          mkdir -p dependencies
          ln -s ${jar inputs.jline} dependencies/jline.jar
          ln -s ${jar inputs.cli-parser} dependencies/cli-parser-1.1.1.jar
        '';
        prepare-idea-core-libs = linkJars "ideaSDK/core" [
          inputs.cli-parser
          inputs.guava
          inputs.core.passthru.asm
          inputs.annotations
          inputs.core
          java.picocontainer-1
          java.jetbrains-trove4j
        ];
        prepare-protobuf-lib = ''
          mkdir -p ideaSDK/lib
          ln -s ${jar inputs.protobuf} ideaSDK/lib/protobuf-2.5.0.jar
        '';
      };
    in
    map
      (name: {
        inherit name;
        script = s.${name};
      })
      [
        "remove-js-compiler-cli"
        "remove-js-compiler"
        "fix-jar-task"
        "remove-targets"
        "fix-value-order"
        "disable-classpath-from-env"
        "update-asm"
        "prepare-ant-lib"
        "prepare-dependencies"
        "prepare-idea-core-libs"
        "prepare-protobuf-lib"
      ];

  # Steps are functions of the inputs, so that switching to a newer IntelliJ
  # SDK automatically relinks everything.
  base = {
    version = "0.6.786";
    inherit jdk;
    bootstrap = null;
    patches = [ "kotlin-0.6.786-sdk-139.patch" ];
    inputs = inputsFor intellij."139" { };
    stepsFn = baseSteps;
    antFlags = [
      "-Dgenerate.javadoc=false"
      "-Dshrink=false"
      "-Dbuild.number=0.6.786"
    ];
  };

  build = cfg: mkKotlin (cfg // { steps = cfg.stepsFn cfg.inputs; });

  # Derive the config of the next version, bootstrapped with `prev`.
  next =
    prev: version: patches:
    {
      inputs ? (i: i),
      steps ? (s: s),
      jdk ? null,
      src ? null,
    }:
    let
      pcfg = prev.cfg;
    in
    pcfg
    // {
      inherit version patches;
      bootstrap = prev;
      inputs = inputs pcfg.inputs;
      stepsFn = i: steps (pcfg.stepsFn i);
      antFlags = [
        "-Dbootstrap.build.no.tests=true"
        "-Dgenerate.javadoc=false"
        "-Dshrink=false"
        "-Dbuild.number=${version}"
      ];
    }
    // lib.optionalAttrs (jdk != null) { inherit jdk; }
    // lib.optionalAttrs (src != null) { inherit src; };

  step =
    prev: version: patches: mods:
    build (next prev version patches mods);

  addLast =
    name: script: s:
    s ++ [ { inherit name script; } ];

  # Like `step`, with extra config attributes.
  buildWith =
    extra: prev: version: patches: mods:
    build (next prev version patches mods // extra);

  p786 = [ "kotlin-0.6.786-sdk-139.patch" ];
  p1932 = p786 ++ [ "kotlin-0.6.1932-remove-ant-k2js.patch" ];
  p2451 = p1932 ++ [
    "kotlin-0.6.2451-fix-class-path.patch"
    "kotlin-0.6.2451-sdk-139.patch"
  ];
  p638 = [
    "kotlin-0.6.1932-remove-ant-k2js.patch"
    "kotlin-0.6.2451-fix-class-path.patch"
  ];
  p409 = p638 ++ [ "kotlin-0.8.409-asm.patch" ];
  p1444 = [
    "kotlin-0.6.1932-remove-ant-k2js.patch"
    "kotlin-0.8.1444-fix-class-path.patch"
    "kotlin-0.8.409-asm.patch"
  ];
  p921 = [
    "kotlin-0.9.21-remove-ant-k2js.patch"
    "kotlin-0.8.1444-fix-class-path.patch"
    "kotlin-0.8.409-asm.patch"
  ];
  p823 = [
    "kotlin-0.10.300-remove-ant-k2js.patch"
    "kotlin-0.10.823-asm.patch"
  ];
  p1426 = p823 ++ [ "kotlin-0.10.1426-pack-jar.patch" ];
  p15394 = p1426 ++ [ "kotlin-0.15.394-remove-rmi-k2js.patch" ];
  p4091 = p1426 ++ [ "kotlin-1.0.0-beta-4091-remove-k2js.patch" ];
  p5604 = [
    "kotlin-1.0.0-beta-5604-remove-k2js.patch"
    "kotlin-0.10.823-asm.patch"
    "kotlin-0.10.1426-pack-jar.patch"
    "kotlin-1.0.0-beta-4091-remove-k2js.patch"
  ];
  p2022 = [
    "kotlin-1.0.0-beta-5604-remove-k2js.patch"
    "kotlin-0.10.1426-pack-jar.patch"
    "kotlin-1.0.0-beta-4091-remove-k2js.patch"
    "kotlin-1.1.0-dev-2022-jdom.patch"
  ];
  p3204 = p2022 ++ [ "kotlin-1.1.0-dev-3204-sdk172.patch" ];
  p4287 = [
    "kotlin-1.0.0-beta-5604-remove-k2js.patch"
    "kotlin-0.10.1426-pack-jar.patch"
    "kotlin-1.0.0-beta-4091-remove-k2js.patch"
    "kotlin-1.1.0-dev-3204-sdk172.patch"
  ];
  p5623 = [
    "kotlin-1.0.0-beta-5604-remove-k2js.patch"
    "kotlin-0.10.1426-pack-jar.patch"
    "kotlin-1.1.0-dev-3204-sdk172.patch"
    "kotlin-1.1.0-dev-5623-remove-k2js.patch"
  ];
  p6445 = p5623 ++ [ "kotlin-1.1.0-dev-6445-remove-k2js-2.patch" ];
  p1_1_2_dev = p5623 ++ [
    "kotlin-1.1.2-dev-141-remove-k2js-2.patch"
    "kotlin-1.1.2-dev-141-remove-proguard.patch"
    "kotlin-1.1.2-dev-141-sdk172-2.patch"
  ];
  p1_1_2 = [
    "kotlin-1.0.0-beta-5604-remove-k2js.patch"
    "kotlin-0.10.1426-pack-jar.patch"
    "kotlin-1.1.2-eap-44-pack-jar-2.patch"
    "kotlin-1.1.0-dev-3204-sdk172.patch"
    "kotlin-1.1.2-eap-44-remove-k2js.patch"
    "kotlin-1.1.2-dev-141-remove-k2js-2.patch"
    "kotlin-1.1.2-dev-141-remove-proguard.patch"
  ];

  same =
    prev: version: patches:
    step prev version patches { };

  p113 = [ "../own/kotlin-1.1.3-dev-1317.patch" ];

  chain = lib.fix (k: {
    "0.6.786" = build base;

    "0.6.1364" = step k."0.6.786" "0.6.1364" p786 {
      steps =
        s:
        ops.addAfter "prepare-idea-core-libs" "prepare-idea-core-libs-log4j-api"
          (linkJars "ideaSDK/core" [ java.log4j-1 ])
          (
            ops.replace "prepare-ant-lib" ''
              mkdir -p dependencies/ant-1.7/lib
              ln -s ${ant}/share/ant/lib/ant.jar dependencies/ant-1.7/lib/ant.jar
            '' s
          );
    };

    "0.6.1932" = step k."0.6.1364" "0.6.1932" p1932 {
      steps =
        s:
        lib.pipe s [
          (addLast "copy-runtime-annotations" ''
            cp -r runtime/src/org/jetbrains/annotations/. core/util.runtime/src/org/jetbrains/
          '')
          (addLast "remove-k2js" ''
            rm build-tools/ant/src/org/jetbrains/jet/buildtools/ant/Kotlin2JsCompilerTask.kt
          '')
          (addLast "prepare-idea-jps-libs" ''
            mkdir -p ideaSDK/jps
            ln -s ${jar intellij."139".jps-model-impl} ideaSDK/jps/jps-model.jar
          '')
        ];
    };

    "0.6.2107" = step k."0.6.1932" "0.6.2107" p1932 {
      steps =
        s:
        lib.pipe s [
          (ops.delete "copy-runtime-annotations")
          (ops.addAfter "remove-js-compiler" "remove-js-compiler-fixup-1" "mkdir -p js/js.dart-ast/src")
          # TODO (TarCV): This should not be needed
          (addLast "add-noverify" ''export ANT_OPTS="$ANT_OPTS -noverify"'')
        ];
    };

    "0.6.2451" = step k."0.6.2107" "0.6.2451" p2451 {
      inputs = i: i // { inherit jdk-annotations; };
      steps = addLast "prepare-annotations-lib" ''
        mkdir -p dependencies/annotations
        ln -s ${jar jdk-annotations} dependencies/annotations/kotlin-jdk-annotations.jar
      '';
    };

    "0.6.2516" = same k."0.6.2451" "0.6.2516" p2451;
    "0.7.333" = same k."0.6.2516" "0.7.333" (p2451 ++ [ "kotlin-0.7.333-asm.patch" ]);
    "0.7.638" = step k."0.7.333" "0.7.638" p638 { steps = ops.delete "update-asm"; };
    "0.7.1214" = same k."0.7.638" "0.7.1214" p638;
    "0.8.84" = same k."0.7.1214" "0.8.84" p638;
    "0.8.409" = same k."0.8.84" "0.8.409" p409;
    "0.8.418" = same k."0.8.409" "0.8.418" p409;
    "0.8.422" = same k."0.8.418" "0.8.422" p409;
    "0.8.1444" = same k."0.8.422" "0.8.1444" p1444;

    "0.9.21" = step k."0.8.1444" "0.9.21" p921 {
      steps = ops.replace "remove-k2js" "rm build-tools/ant/src/org/jetbrains/jet/buildtools/ant/Kotlin2JsTask.kt";
    };
    "0.9.738" = same k."0.9.21" "0.9.738" p921;
    "0.9.1204" = step k."0.9.738" "0.9.1204" p921 {
      inputs = i: i // { kotlin = k."0.9.738"; };
    };

    "0.10.300" =
      step k."0.9.1204" "0.10.300"
        [
          "kotlin-0.10.300-remove-ant-k2js.patch"
          "kotlin-0.8.409-asm.patch"
        ]
        {
          inputs = i: i // { kotlin = k."0.9.1204"; };
          steps = ops.replace "remove-k2js" "rm ant/src/org/jetbrains/kotlin/ant/Kotlin2JsTask.kt";
        };

    "0.10.823" = step k."0.10.300" "0.10.823" p823 {
      inputs = i: removeAttrs i [ "kotlin" ];
      steps = ops.replace "remove-js-compiler-cli" "rm -r compiler/cli/src/org/jetbrains/kotlin/cli/js";
    };

    "0.10.1023" = step k."0.10.823" "0.10.1023" p823 {
      inputs = _: inputsFor intellij."141" { inherit jdk-annotations; };
    };
    "0.10.1336" = same k."0.10.1023" "0.10.1336" p823;

    "0.10.1426" = step k."0.10.1336" "0.10.1426" p1426 {
      steps =
        s:
        lib.pipe s [
          (ops.addAfter "prepare-dependencies" "prepare-protobuf-api" ''
            mkdir -p dependencies
            ln -s ${jar java.protobuf.java-2_5} dependencies/protobuf-2.5.0-lite.jar
          '')
          (ops.addAfter "prepare-dependencies" "prepare-idea-libs" ''
            mkdir -p ideaSDK/lib
            ln -s ${jar java.jna-platform} ideaSDK/lib/jna-utils.jar
            ln -s ${jar java.jakarta-oro} ideaSDK/lib/oromatcher.jar
          '')
          (ops.addAfter "prepare-dependencies" "prepare-lib-inject" ''
            mkdir -p lib
            ln -s ${jar java.javax-inject} lib/javax.inject.jar
          '')
        ];
    };
    "0.10.1464" = same k."0.10.1426" "0.10.1464" p1426;
    "0.11.153" = same k."0.10.1464" "0.11.153" p1426;
    "0.11.873" = same k."0.11.153" "0.11.873" p1426;
    "0.11.992" = same k."0.11.873" "0.11.992" p1426;
    "0.11.1014" = same k."0.11.992" "0.11.1014" p1426;
    "0.11.1201" = same k."0.11.1014" "0.11.1201" p1426;
    "0.11.1393" = same k."0.11.1201" "0.11.1393" p1426;

    "0.12.108" = step k."0.11.1393" "0.12.108" p1426 {
      steps =
        s:
        lib.pipe s [
          (ops.addAfter "prepare-dependencies" "prepare-jarjar-dependency" ''
            mkdir -p dependencies
            ln -s ${jar java.jarjar} dependencies/jarjar.jar
          '')
          (ops.addAfter "prepare-idea-libs" "prepare-idea-lib-asm" ''
            mkdir -p ideaSDK/lib
            ln -s ${jar java.jetbrains-asm-5} ideaSDK/lib/asm-all.jar
          '')
        ];
    };
    "0.12.115" = same k."0.12.108" "0.12.115" p1426;
    "0.12.176" = same k."0.12.115" "0.12.176" p1426;
    "0.12.470" = step k."0.12.176" "0.12.470" p1426 {
      steps = ops.replace "prepare-ant-lib" ''
        mkdir -p dependencies/ant-1.8/lib
        ln -s ${ant}/share/ant/lib/ant.jar dependencies/ant-1.8/lib/ant.jar
      '';
    };

    "0.12.1077" = step k."0.12.470" "0.12.1077" p1426 {
      inputs = _: inputsFor intellij."143" { inherit jdk-annotations; };
      steps =
        s:
        lib.pipe s [
          (addLast "prepare-jansi-libs" ''
            mkdir -p dependencies
            ln -s ${jar java.jansi-1} dependencies/jansi.jar
            ln -s ${jar java.jansi-native} dependencies/jansi-native.jar
          '')
          # This version updated to a newer jar with a different file name,
          # while the inherited steps already use that newer version under the
          # old name.
          (ops.addAfter "prepare-idea-libs" "prepare-idea-libs-jna" ''
            mv ideaSDK/lib/jna-utils.jar ideaSDK/lib/jna-platform.jar
          '')
        ];
    };
    "0.12.1250" = same k."0.12.1077" "0.12.1250" p1426;
    "0.12.1306" = same k."0.12.1250" "0.12.1306" p1426;
    "0.13.177" = same k."0.12.1306" "0.13.177" p1426;
    "0.13.791" = same k."0.13.177" "0.13.791" p1426;
    "0.13.899" = same k."0.13.791" "0.13.899" p1426;
    "0.13.1118" = same k."0.13.899" "0.13.1118" p1426;
    "0.13.1304" = same k."0.13.1118" "0.13.1304" p1426;
    "0.14.209" = step k."0.13.1304" "0.14.209" p1426 { steps = ops.delete "fix-value-order"; };
    "0.14.398" = same k."0.14.209" "0.14.398" p1426;
    "0.15.8" = same k."0.14.398" "0.15.8" p1426;

    "0.15.394" = step k."0.15.8" "0.15.394" p15394 {
      steps = ops.addAfter "prepare-idea-libs" "prepare-idea-libs-native-platform" ''
        ln -s ${jar java.native-platform} dependencies/native-platform-uberjar.jar
      '';
    };
    "0.15.541" = same k."0.15.394" "0.15.541" p15394;
    "0.15.604" = same k."0.15.541" "0.15.604" p15394;
    "0.15.723" = same k."0.15.604" "0.15.723" p15394;
    "1.0.0-beta-2055" = same k."0.15.723" "1.0.0-beta-2055" p15394;
    "1.0.0-beta-3070" = same k."1.0.0-beta-2055" "1.0.0-beta-3070" p15394;
    "1.0.0-beta-4091" = same k."1.0.0-beta-3070" "1.0.0-beta-4091" p4091;
    "1.0.0-beta-5010" = step k."1.0.0-beta-4091" "1.0.0-beta-5010" p4091 {
      steps = ops.addAfter "prepare-idea-libs" "prepare-idea-libs-junit" ''
        ln -s ${jar java.junit4} libraries/lib/junit-4.11.jar
      '';
    };
    "1.0.0-beta-5604" = same k."1.0.0-beta-5010" "1.0.0-beta-5604" p5604;
    "1.0.0-dev-162" = same k."1.0.0-beta-5604" "1.0.0-dev-162" p5604;
    "1.0.0" = same k."1.0.0-dev-162" "1.0.0" p5604;
    # Sources contain non-ASCII characters from here on (Guix builds in a
    # UTF-8 locale).
    "1.0.3-dev-184" = build (next k."1.0.0" "1.0.3-dev-184" p5604 { } // { utf8 = true; });
    "1.0.3-dev-371" = same k."1.0.3-dev-184" "1.0.3-dev-371" p5604;

    "1.1.0-dev-1023" =
      step k."1.0.3-dev-371" "1.1.0-dev-1023" (p5604 ++ [ "kotlin-1.1.0-dev-1023-jdom.patch" ])
        {
          steps = ops.addAfter "prepare-dependencies" "prepare-dependencies-cli-parser-fixup" ''
            mv dependencies/cli-parser-1.1.1.jar dependencies/cli-parser-1.1.2.jar
          '';
        };

    "1.1.0-dev-2022" = step k."1.1.0-dev-1023" "1.1.0-dev-2022" p2022 {
      inputs = i: i // { protobuf = java.protobuf.java-2_6-kotlin; };
      steps =
        s:
        lib.pipe s [
          (ops.delete "prepare-protobuf-lib")
          (ops.replace "prepare-protobuf-api" ''
            mkdir -p dependencies
            ln -s ${jar java.protobuf.java-2_6-kotlin} dependencies/protobuf-2.6.1.jar
            ln -s ${jar java.protobuf.java-2_6-kotlin} dependencies/protobuf-2.6.1-lite.jar
          '')
        ];
    };
    "1.1.0-dev-2830" = same k."1.1.0-dev-2022" "1.1.0-dev-2830" p2022;

    "1.1.0-dev-3204" = step k."1.1.0-dev-2830" "1.1.0-dev-3204" p3204 {
      inputs =
        _:
        inputsFor intellij."172" {
          inherit jdk-annotations;
          protobuf = java.protobuf.java-2_6-kotlin;
        };
    };
    "1.1.0-dev-3868" = same k."1.1.0-dev-3204" "1.1.0-dev-3868" p3204;
    "1.1.0-dev-4287" = same k."1.1.0-dev-3868" "1.1.0-dev-4287" p4287;
    "1.1.0-dev-5008" = same k."1.1.0-dev-4287" "1.1.0-dev-5008" p4287;
    "1.1.0-dev-5623" = same k."1.1.0-dev-5008" "1.1.0-dev-5623" p5623;
    "1.1.0-dev-5815" = same k."1.1.0-dev-5623" "1.1.0-dev-5815" p5623;
    "1.1.0-dev-6445" = same k."1.1.0-dev-5815" "1.1.0-dev-6445" p6445;
    "1.1.2-dev-141" = same k."1.1.0-dev-6445" "1.1.2-dev-141" p1_1_2_dev;

    "1.1.2-eap-44" = step k."1.1.2-dev-141" "1.1.2-eap-44" p1_1_2 {
      inputs = i: i // { inherit (java) xpp3; };
      steps = ops.addAfter "prepare-idea-core-libs" "prepare-idea-core-libs-2" ''
        ${linkJars "ideaSDK/core" [
          java.jdom-1
          java.iq80-snappy
          java.xpp3
          java.xstream
        ]}
        ln -s ${jar java.jna} ideaSDK/core/jna.jar
        # file names of Guix' jars, referenced by the pack-jar-2 patch
        ln -sf ${jar java.jetbrains-asm-6} ideaSDK/core/asm-6.0.jar
        ln -sf ${jar java.guava-20} ideaSDK/core/guava-20.0.jar
        ln -sf ${jar java.jdom-1} ideaSDK/core/jdom-1.1.3.jar
        ln -sf ${jar java.log4j-1} ideaSDK/core/java-log4j-1.2-api.jar
        ln -sf ${jar java.iq80-snappy} ideaSDK/core/snappy-0.4.jar
        ln -sf ${jar java.xpp3} ideaSDK/core/xpp3-1.1.4.jar
        for f in intellij-annotations intellij-core picocontainer jetbrains-trove4j xstream jna; do
          [ -e ideaSDK/core/$f.jar ] || { echo "missing ideaSDK/core/$f.jar"; exit 1; }
        done
      '';
    };

    "1.1.2-5" = step k."1.1.2-eap-44" "1.1.2-5" p1_1_2 {
      steps =
        s:
        lib.pipe s [
          (addLast "set-jdk-variables" "export JDK_16=${jdk.home or jdk}")
          (ops.delete "remove-js-compiler")
        ];
    };

    # ---- Beyond TarCV/kotlin-guix ----

    # From here on build.xml delegates the runtime (stdlib, reflect, ...) to
    # Gradle; splice the Ant targets of 1.1.2 back in.
    "1.1.3-dev-1317" =
      buildWith
        {
          mainPatch = false;
          install = relocateReflect;
        }
        k."1.1.2-5"
        "1.1.3-dev-1317"
        p113
        {
          steps =
            s:
            lib.pipe s [
              (addLast "ant-runtime" (antRuntime { }))
              # the forked Ant would not see our CLASSPATH
              (addLast "no-compiler-fork" ''
                sed -i '/<target name="dist"/,/description/ s/,compiler-fork,/,compiler,/' build.xml
              '')
              (addLast "prepare-javaslang" ''
                ln -s ${jar java.javaslang} dependencies/javaslang-2.0.6.jar
              '')
            ];
        };

    # Written against an ASM 6 snapshot; 6.0 final renamed V1_9 to V9.
    "1.1.3" = step k."1.1.3-dev-1317" "1.1.3" p113 {
      steps = addLast "asm-6-final" ''
        grep -rlZ 'V1_9' --include=*.kt --include=*.java . | xargs -0 -r sed -i 's/\bV1_9\b/V9/g'
      '';
    };

    # From here on: no per-version patch, scripted edits instead (see
    # `scriptedEdits`), and the JS compiler is kept.
    # json-org and kotlinx.coroutines (compiled with the previous Kotlin).
    "1.1.4" = buildWith { dynamicFlags = true; } k."1.1.3" "1.1.4" [ ] {
      steps =
        s:
        lib.pipe s [
          (ops.delete "remove-js-compiler-cli")
          (ops.delete "remove-k2js")
          (ops.replace "ant-runtime" (antRuntime {
            fragment = ../../patches/own/runtime-targets-1.1.4.xml;
          }))
          (addLast "scripted-edits" scriptedEdits)
          (addLast "fresh-script-runtime" (freshRuntime "script-runtime" [ "core/script.runtime/src" ]))
          (addLast "prepare-deps-1.1.4" ''
            ln -s ${jar kotlinLibs.json-org} dependencies/json-org.jar
            ln -s ${
              jar (kotlinLibs.kotlinx-coroutines-core-0_14 k."1.1.3")
            } dependencies/kotlinx-coroutines-core.jar
          '')
        ];
    };

    "1.1.51" = step k."1.1.4" "1.1.51" [ ] {
      steps = addLast "prepare-deps-1.1.51" ''
        ln -s ${jar kotlinLibs.jline3} dependencies/jline3.jar
      '';
    };

    "1.1.60" = step k."1.1.51" "1.1.60" [ ] { };
    "1.2.0" = step k."1.1.60" "1.2.0" [ ] {
      steps = ops.replace "ant-runtime" (antRuntime {
        fragment = ../../patches/own/runtime-targets-1.2.xml;
      });
    };
    "1.2.10" = step k."1.2.0" "1.2.10" [ ] {
      steps = addLast "jvm-target-1.8" ''
        sed -i -e 's|<compilerarg value="-version"/>|& <compilerarg line="-jvm-target 1.8"/>|' build.xml
      '';
    };
    "1.2.21" = step k."1.2.10" "1.2.21" [ ] {
      steps = ops.replace "ant-runtime" (antRuntime {
        fragment = ../../patches/own/runtime-targets-1.2.21.xml;
      });
    };
    "1.2.31" = step k."1.2.21" "1.2.31" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "ant-runtime" (antRuntime {
          fragment = ../../patches/own/runtime-targets-1.2.31.xml;
        }))
        (addLast "compiler-xml-location" ''
          # compiler.xml moved from idea/src to compiler/cli/src
          sed -i 's|<fileset dir="idea/src">|<fileset dir="compiler/cli/src">|' build.xml
        '')
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."181")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };

    # build.xml was removed from the repository in 1.2.40: reuse that of 1.2.31.
    "1.2.40" = step k."1.2.31" "1.2.40" [ ] {
      steps =
        s:
        [
          {
            name = "restore-build-xml";
            script = ''
              cp ${kotlinSources."1.2.31"}/build.xml ${kotlinSources."1.2.31"}/common.xml .
              chmod u+w build.xml common.xml
              # new modules since 1.2.31
              sed -i -e 's|<include name="core/deserialization/src"/>|& <include name="core/metadata/src"/> <include name="core/metadata.jvm/src"/> <include name="compiler/psi/src"/>|' \
                -e 's|<fileset dir="core/deserialization/src"/>|& <fileset dir="core/metadata/src"/> <fileset dir="core/metadata.jvm/src"/> <fileset dir="compiler/psi/src"/>|' build.xml
            '';
          }
        ]
        ++ (lib.flip lib.pipe [
          (ops.replace "ant-runtime" (antRuntime {
            fragment = ../../patches/own/runtime-targets-1.2.40.xml;
          }))
          (addLast "compiler-xml-location-1.2.40" ''
            # compiler.xml is back in idea/src
            sed -i 's|<fileset dir="compiler/cli/src">|<fileset dir="idea/src">|' build.xml
          '')
        ] s);
    };

    "1.2.41" = step k."1.2.40" "1.2.41" [ ] { };
    "1.2.50-eap-17" = step k."1.2.41" "1.2.50-eap-17" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "read-deserialized-contracts" ''
          sed -i 's|<compilerarg value="-version"/>|& <compilerarg line="-Xread-deserialized-contracts -Xeffect-system"/>|' build.xml
        '')
        (ops.replace "ant-runtime" (antRuntime {
          fragment = ../../patches/own/runtime-targets-1.2.50.xml;
        }))
        (addLast "explicit-ir-function-type" ''
          # the old inference gives IrElement for the common supertype
          sed -i 's|val syntheticFunction = if (isConstructor)|val syntheticFunction: IrFunction = if (isConstructor)|' \
            compiler/ir/backend.jvm/src/org/jetbrains/kotlin/backend/jvm/lower/SyntheticAccessorLowering.kt
        '')
        (addLast "fresh-stdlib" freshStdlib)
      ];
    };
    "1.2.50-eap-62" = step k."1.2.50-eap-17" "1.2.50-eap-62" [ ] {
      # Sources written for the new inference, which the (eap-17) bootstrap
      # compiler cannot compile the compiler with (codegen errors).
      steps = addLast "avoid-new-inference" ''
        sed -i 's|nextChar()?.apply(sb::append)|nextChar()?.let { sb.append(it) }|' \
          compiler/cli/cli-common/src/org/jetbrains/kotlin/cli/common/arguments/preprocessCommandLineArguments.kt
        sed -i 's|flatMapTo(HashSet()) { modulesInfo|flatMapTo(HashSet<org.jetbrains.kotlin.daemon.common.IncrementalModuleEntry>()) { modulesInfo|; s|modules.mapTo(HashSet()) { it.buildHistoryFile }|modules.mapTo(HashSet<File>()) { it.buildHistoryFile }|' \
          compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/multiproject/ModulesApiHistory.kt
      '';
    };
    "1.2.50" = step k."1.2.50-eap-62" "1.2.50" [ ] { };
    "1.2.51" = step k."1.2.50" "1.2.51" [ ] { };
    "1.2.60" = step k."1.2.51" "1.2.60" [ ] {
      steps = stdlibFlags "-Xuse-experimental=kotlin.Experimental";
    };
    "1.2.61" = step k."1.2.60" "1.2.61" [ ] { };
    "1.2.70" = step k."1.2.61" "1.2.70" [ ] {
      steps = lib.flip lib.pipe [
        # no V1_9 left (grep fails under pipefail)
        (ops.delete "asm-6-final")
        (stdlibFlags "-Xuse-experimental=kotlin.Experimental -Xuse-experimental=kotlin.ExperimentalMultiplatform")
        (addLast "new-inference" ''
          sed -i 's|<compilerarg line="-Xread-deserialized-contracts -Xeffect-system"/>|<compilerarg line="-Xread-deserialized-contracts -Xeffect-system -Xnew-inference"/>|' build.xml
          # callable references to vararg constructors
          grep -rlE '::(Js|Jvm)MetadataVersion\)' build-common/src | xargs sed -i -E 's/\?\.let\(::(Js|Jvm)MetadataVersion\)/?.let { \1MetadataVersion(*it) }/'
          # references to inline library functions crash codegen with -Xnew-inference
          grep -rlE '\((Collection|List|Map|Array|Iterable|CharSequence|String)(<[^>()]*>)?::\w+\)' core compiler build-common js --include=*.kt \
            | xargs regex-edit --lines --all '\.(takeIf|takeUnless|filter|filterNot|dropLastWhile|use)\((?:Collection|List|Map|Array|Iterable|CharSequence|String)(?:<[^>()]*>)?::(\w+)\)' '.\1 { it.\2() }'
        '')
        (addLast "kotlin-annotations-jvm" ''
          mkdir -p build/annotations-jvm lib
          $JAVA_HOME/bin/javac -nowarn -d build/annotations-jvm $(find libraries/tools/kotlin-annotations-jvm/src -name '*.java')
          $JAVA_HOME/bin/jar cf lib/kotlin-annotations-jvm.jar -C build/annotations-jvm .
          sed -i '/<target name="\(core\|reflection\)">/,/<\/target>/ s|<pathelement path="''${protobuf.jar}"/>|&\n<pathelement path="''${basedir}/lib/kotlin-annotations-jvm.jar"/>|' build.xml
          grep -c 'lib/kotlin-annotations-jvm.jar' build.xml
        '')
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."182")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };
    "1.2.71" = step k."1.2.70" "1.2.71" [ ] { };
    "1.3.0" = step k."1.2.71" "1.3.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "ant-runtime" (antRuntime {
          fragment = ../../patches/own/runtime-targets-1.3.0.xml;
        }))
        (ops.replace "fresh-stdlib" freshStdlib13)
        (addLast "no-coroutines-in-compiler" ''
          # The fresh stdlib's coroutines do not match the real one (see
          # freshStdlib13): no coroutines in the compiler built by 1.2.71.
          sed -i 's|<compilerarg line="-Xread-deserialized-contracts|<compilerarg line="-Xskip-metadata-version-check -Xread-deserialized-contracts|' build.xml
          sed -i '/SequenceScope<T>.yieldIfNotNull/d' core/util.runtime/src/org/jetbrains/kotlin/utils/collections.kt
          sed -i '/^import org.jetbrains.kotlin.utils.yieldIfNotNull$/d' compiler/frontend/src/org/jetbrains/kotlin/types/expressions/DoubleColonExpressionResolver.kt
          # unsigned types are 1.3 API (the compiler is compiled as Kotlin 1.2)
          sed -i -e 's/-> UByte.MAX_VALUE.toLong()/-> 0xFFL/' -e 's/-> UShort.MAX_VALUE.toLong()/-> 0xFFFFL/' -e 's/-> UInt.MAX_VALUE.toLong()/-> 0xFFFFFFFFL/' \
            core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerValueTypeConstructor.kt
          f=compiler/frontend/src/org/jetbrains/kotlin/types/expressions/DoubleColonExpressionResolver.kt
          python3 - compiler/frontend/src/org/jetbrains/kotlin/analyzer/AnalyzerFacade.kt $f <<'PY'
          import re, sys

          def edit(path, f):
              s = open(path, encoding="latin-1").read()
              open(path, "w", encoding="latin-1").write(f(s))

          def balanced(s, i):  # the end of the parenthesized group at s[i] == "("
              depth = 0
              for j in range(i, len(s)):
                  depth += {"(": 1, ")": -1}.get(s[j], 0)
                  if depth == 0:
                      return j + 1
              raise ValueError("unbalanced")

          # sequence { ... yield(x) ... }.toList()  ->  mutableListOf<...>().apply { ... add(x) ... }
          def facade(s):
              m = re.search(r"sequence \{(.*?)\}\.toList\(\)", s, re.S)
              body = re.sub(r"\byield\(", "add(", m.group(1))
              return s[: m.start()] + "mutableListOf<ModuleDescriptorImpl>().apply {" + body + "}" + s[m.end() :]

          # the sequence of resolution results becomes a list of thunks, computed in the loop
          def resolver(s):
              m = re.search(r"val resultSequence = sequence \{(.*?)(\n *// TODO: Maybe it makes sense)", s, re.S)
              body = m.group(1).replace("return@sequence", "return@apply")
              out, i = [], 0
              for y in re.finditer(r"yieldIfNotNull(?=\()", body):
                  if y.start() < i:
                      continue
                  end = balanced(body, y.end())
                  out += [body[i : y.start()], "add { ", body[y.end() : end], " }"]
                  i = end
              body = "".join(out) + body[i:]
              s = s[: m.start()] + "val resultSequence = mutableListOf<() -> ResolutionResultsAndTraceCommitCallback?>().apply {" + body + m.group(2) + s[m.end() :]
              return s.replace("for (result in resultSequence) {", "for (thunk in resultSequence) {\n            val result = thunk() ?: continue", 1)

          edit(sys.argv[1], facade)
          edit(sys.argv[2], resolver)
          PY
          grep -q 'thunk()' $f
          ! grep -n 'sequence {' compiler/frontend/src/org/jetbrains/kotlin/analyzer/AnalyzerFacade.kt $f
          # no kotlinx.coroutines: block on the experimental coroutine
          f=compiler/frontend.script/src/org/jetbrains/kotlin/script/AsyncDependencyResolverWrapper.kt
          sed -i 's|^import kotlinx.coroutines.runBlocking|import kotlin.coroutines.experimental.*|' $f
          regex-edit '(?s)\)\: DependenciesResolver\.ResolveResult\s*= runBlocking \{ (delegate\.resolveAsync\(scriptContents, environment\)) \}' '): DependenciesResolver.ResolveResult {
                  val latch = java.util.concurrent.CountDownLatch(1)
                  var res: DependenciesResolver.ResolveResult? = null
                  var error: Throwable? = null
                  val block: suspend () -> DependenciesResolver.ResolveResult = { \1 }
                  block.startCoroutine(object : Continuation<DependenciesResolver.ResolveResult> {
                      override val context: CoroutineContext get() = EmptyCoroutineContext
                      override fun resume(value: DependenciesResolver.ResolveResult) { res = value; latch.countDown() }
                      override fun resumeWithException(exception: Throwable) { error = exception; latch.countDown() }
                  })
                  latch.await()
                  error?.let { throw it }
                  return res!!
              }' $f
          ! grep -n runBlocking $f
          # 1.3.0's effect system takes a local `fun equals(other: Any?)` for Any.equals (crash)
          sed -i -e 's/    fun equals(other: Any?): Boolean =/    fun equalsImpl(other: Any?): Boolean =/' -e 's/-> equals(args.single())/-> equalsImpl(args.single())/' \
            core/reflection.jvm/src/kotlin/reflect/jvm/internal/calls/AnnotationConstructorCaller.kt
        '')
      ];
    };
    "1.3.11" = step k."1.3.0" "1.3.11" [ ] {
      steps = lib.flip lib.pipe [
        # the 1.3.0 stdlib has all the compiler needs
        (ops.delete "fresh-stdlib")
        (ops.replace "no-coroutines-in-compiler" ''
          # no kotlinx.coroutines: block on the coroutine
          f=compiler/frontend.script/src/org/jetbrains/kotlin/script/AsyncDependencyResolverWrapper.kt
          sed -i 's|^import kotlinx.coroutines.runBlocking|import kotlin.coroutines.*|' $f
          regex-edit '(?s)\)\: DependenciesResolver\.ResolveResult\s*= runBlocking \{ (delegate\.resolveAsync\(scriptContents, environment\)) \}' '): DependenciesResolver.ResolveResult {
                  val latch = java.util.concurrent.CountDownLatch(1)
                  var res: DependenciesResolver.ResolveResult? = null
                  var error: Throwable? = null
                  val block: suspend () -> DependenciesResolver.ResolveResult = { \1 }
                  block.startCoroutine(Continuation(EmptyCoroutineContext) { r -> r.fold({ res = it }, { error = it }); latch.countDown() })
                  latch.await()
                  error?.let { throw it }
                  return res!!
              }' $f
          ! grep -n runBlocking $f
          # the effect system takes a local `fun equals(other: Any?)` for Any.equals (crash)
          sed -i -e 's/    fun equals(other: Any?): Boolean =/    fun equalsImpl(other: Any?): Boolean =/' -e 's/-> equals(args.single())/-> equalsImpl(args.single())/' \
            core/reflection.jvm/src/kotlin/reflect/jvm/internal/calls/AnnotationConstructorCaller.kt
        '')
      ];
    };
    "1.3.21" = step k."1.3.11" "1.3.21" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar intellij."183".core.passthru.asm} $f
          done
        '')
        (addLast "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.java/src"
          "compiler/frontend.script/src"
          "compiler/cli/cli-common/src"
          "compiler/daemon/daemon-common/src"
          "compiler/daemon/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/ir/backend.jvm/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
        ]))
        (addLast "core-annotations" ''
          # org.jetbrains.annotations for the core/reflection Java sources
          sed -i 's|^<pathelement path="''${basedir}/lib/kotlin-annotations-jvm.jar"/>|&\n<pathelement path="''${basedir}/ideaSDK/core/intellij-annotations.jar"/>|' build.xml
          grep -c 'core/intellij-annotations.jar"/>' build.xml
        '')
        (addLast "resources-dirs" ''
          sed -i 's|<arg value="-Xuse-experimental=kotlin.contracts.ExperimentalContracts"/>|&\n            <arg value="-Xcommon-sources=libraries/kotlin.test/annotations-common/src/main/kotlin,libraries/kotlin.test/common/src/main/kotlin"/>|' build.xml
          sed -i 's|<fileset dir="idea/src">|<fileset dir="idea/resources">|' build.xml
          # kotlin-reflect.jar
          regex-edit --lines '^(\s*)<fileset dir="\$\{basedir\}/(core/[^"/]+)/src" includes="META-INF/services/\*\*"/>' '\g<0>\n\1<fileset dir="''${basedir}/\2/resources" includes="META-INF/services/**"/>' build.xml
        '')
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."183")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };
    "1.3.31" = step k."1.3.21" "1.3.31" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "ant-resources" ''
          sed -i 's|<fileset dir="''${basedir}/ant/src" includes="\*\*/\*.xml"/>|<fileset dir="''${basedir}/ant/resources" includes="**/*.xml"/>|' build.xml
          grep -q 'ant/resources' build.xml
        '')
        (addLast "no-scripting-plugin" ''
          # the daemon loads the scripting plugin (not in kotlin-compiler.jar) if present
          f=compiler/daemon/src/org/jetbrains/kotlin/daemon/KotlinRemoteReplService.kt
          sed -i '/^import org.jetbrains.kotlin.scripting.compiler.plugin.ScriptingCompilerConfigurationComponentRegistrar$/d' $f
          sed -i 's|ScriptingCompilerConfigurationComponentRegistrar()|Class.forName("org.jetbrains.kotlin.scripting.compiler.plugin.ScriptingCompilerConfigurationComponentRegistrar").newInstance() as ComponentRegistrar|' $f
          # new inference of 1.3.21
          sed -i 's|^\( *\)val serializer = JsAstSerializer(if (shouldValidateJsAst) ::validateJsAst else null)|\1var validator: ((JsProgramFragment, Set<JsName>) -> Unit)? = null\n\1if (shouldValidateJsAst) validator = { f, n -> validateJsAst(f, n) }\n\1val serializer = JsAstSerializer(validator)|' \
            js/js.translator/src/org/jetbrains/kotlin/js/facade/K2JSTranslator.kt
        '')
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/frontend.script/src"
          "compiler/cli/cli-common/src"
          "compiler/daemon/daemon-common/src"
          "compiler/daemon/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
        ]))
      ];
    };
    "1.3.41" = step k."1.3.31" "1.3.41" [ ] {
      steps = lib.flip lib.pipe [
        # frontend.script is no longer part of the compiler
        (ops.replace "no-coroutines-in-compiler" ''
          # the effect system takes a local `fun equals(other: Any?)` for Any.equals (crash)
          sed -i -e 's/    fun equals(other: Any?): Boolean =/    fun equalsImpl(other: Any?): Boolean =/' -e 's/-> equals(args.single())/-> equalsImpl(args.single())/' \
            core/reflection.jvm/src/kotlin/reflect/jvm/internal/calls/AnnotationConstructorCaller.kt
        '')
        (addLast "inference-fixes" ''
          # constructs the 1.3.31 compiler cannot infer
          sed -i 's|capabilities + (multiTargetPlatform?.let { mapOf(MultiTargetPlatform.CAPABILITY to it) } ?: emptyMap())|capabilities + (multiTargetPlatform?.let { mapOf<ModuleDescriptor.Capability<*>, Any?>(MultiTargetPlatform.CAPABILITY to it) } ?: emptyMap<ModuleDescriptor.Capability<*>, Any?>())|' \
            core/descriptors/src/org/jetbrains/kotlin/descriptors/impl/ModuleDescriptorImpl.kt
          sed -i 's|types.reduce { left: SimpleType?, right -> fold(left, right, mode) }|types.reduce<SimpleType?, SimpleType> { left, right -> fold(left, right, mode) }|' \
            core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
          grep -q 'reduce<SimpleType?' core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
        '')
        (addLast "streamex-new" ''
          # SDK 191 needs StreamEx.toArray(IntFunction), added after 0.6.2
          for f in ideaSDK/core/streamex*.jar; do ln -sf ${jar java.streamex} $f; done
        '')
        (addLast "more-heap" ''export ANT_OPTS="$ANT_OPTS -Xmx5g"'')
        (addLast "core-type-system" ''
          sed -i '/<target name="core">/,/<\/target>/ s|^\( *\)<include name="core/descriptors.jvm/src"/>|&\n\1<include name="core/type-system/src"/>|' build.xml
          grep -q 'core/type-system/src' build.xml
        '')
        (ops.replace "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar intellij."191".core.passthru.asm} $f
          done
        '')
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/cli/cli-common/src"
          "compiler/daemon/daemon-common/src"
          "compiler/daemon/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/ir/serialization.common/src"
          "compiler/ir/serialization.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
          "core/type-system/src"
          "compiler/fir/cones/src"
          "compiler/fir/resolve/src"
          "compiler/fir/tree/src"
          "compiler/fir/tree/visitors"
          "compiler/fir/psi2fir/src"
          "compiler/fir/fir2ir/src"
        ]))
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."191")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };
    "1.3.50" = step k."1.3.41" "1.3.50" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/cli/cli-common/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/ir/serialization.common/src"
          "compiler/ir/serialization.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
          "core/type-system/src"
          "compiler/fir/cones/src"
          "compiler/fir/resolve/src"
          "compiler/fir/tree/src"
          "compiler/fir/tree/visitors"
          "compiler/fir/psi2fir/src"
          "compiler/fir/fir2ir/src"
          "compiler/cli/cli-js/src"
          "compiler/fir/java/src"
          "compiler/util-io/src"
          "compiler/util-klib/src"
        ]))
      ];
    };
    "1.3.61" = step k."1.3.50" "1.3.61" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "inference-fixes" ''
          sed -i 's|types.reduce { left: SimpleType?, right: SimpleType? -> fold(left, right, mode) }|types.reduce<SimpleType?, SimpleType> { left, right -> fold(left, right, mode) }|' \
            core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
          grep -q 'reduce<SimpleType?' core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
        '')
        (addLast "preloader-java8" ''
          sed -i '/<target name="preloader">/,/<\/target>/ s|source="1.6" target="1.6"|source="1.8" target="1.8"|' build.xml
          grep -q 'source="1.8" target="1.8"' build.xml
        '')
        (addLast "jvm-default" ''
          sed -i -e 's|<compilerarg value="-version"/>|& <compilerarg line="-Xjvm-default=enable"/>|' build.xml
          grep -q 'Xjvm-default=enable' build.xml
        '')
        (ops.replace "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar intellij."192".core.passthru.asm} $f
          done
        '')
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/cli/cli-common/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/ir/serialization.common/src"
          "compiler/ir/serialization.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
          "core/type-system/src"
          "compiler/fir/cones/src"
          "compiler/fir/resolve/src"
          "compiler/fir/tree/src"
          "compiler/fir/tree/visitors"
          "compiler/fir/psi2fir/src"
          "compiler/fir/fir2ir/src"
          "compiler/cli/cli-js/src"
          "compiler/fir/java/src"
          "compiler/util-io/src"
          "compiler/util-klib/src"
          "compiler/util-klib-metadata/src"
          "compiler/ir/backend.wasm/src"
          "core/descriptors.runtime/src"
        ]))
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."192")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };
    "1.3.72" = step k."1.3.61" "1.3.72" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "inference-fixes" ''
          sed -i 's|types.reduce { left: SimpleType?, right: SimpleType? -> fold(left, right, mode) }|types.reduce<SimpleType?, SimpleType> { left, right -> fold(left, right, mode) }|' \
            core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
          grep -q 'reduce<SimpleType?' core/descriptors/src/org/jetbrains/kotlin/resolve/constants/IntegerLiteralTypeConstructor.kt
        '')
        (addLast "mixed-named-args" ''
          # 1.4 language feature "named arguments in their own position" is not known to the 1.3.61 compiler: drop the names
          # (carried forward: not every version has every call, or every file)
          regex-edit --optional 'shouldCheckExpectActual = false,(\s+dependenciesContainer)' 'false,\1' compiler/cli/cli-common/src/org/jetbrains/kotlin/analyzer/common/CommonResolverForModuleFactory.kt
          f=compiler/fir/lightTree/src/org/jetbrains/kotlin/fir/lightTree/converter/DeclarationsConverter.kt
          regex-edit --optional 'source = null,(\s+ConeClassLikeTypeImpl\()' 'null,\1' $f
          regex-edit --optional --all 'member = (false|parentNode\?\.tokenType != KT_FILE), stubMode' '\1, stubMode' $f
          f=compiler/fir/psi2fir/src/org/jetbrains/kotlin/fir/builder/RawFirBuilder.kt
          regex-edit --optional --all 'member = (false|!property\.isTopLevel), stubMode' '\1, stubMode' $f
          f=compiler/fir/resolve/src/org/jetbrains/kotlin/fir/FirCallResolver.kt
          regex-edit --optional 'explicitReceiver = null,(\s+delegatedConstructorCall\.arguments,\s+)isSafeCall = false,(\s+)typeArguments = typeArguments,' 'null,\1false,\2typeArguments,' $f
          regex-edit --optional 'dispatchReceiverValue = null,(\s+)implicitExtensionReceiverValue = null,(\s+ExplicitReceiverKind)' 'null,\1null,\2' $f
          f=compiler/fir/resolve/src/org/jetbrains/kotlin/fir/scopes/impl/FirIntegerLiteralTypeScope.kt
          regex-edit --optional --all 'source = null,(\s+session,)' 'null,\1' $f
          regex-edit --optional 'receiverTypeRef = null,(\s+ALL_OPERATORS)' 'null,\1' $f
          regex-edit --optional 'isErrorTypeEqualsToAnything = false, isStubTypeEqualsToAnything = false, ' 'false, false, ' compiler/fir/resolve/src/org/jetbrains/kotlin/fir/scopes/impl/FirSuperTypeScope.kt
          regex-edit --optional 'isErrorTypeEqualsToAnything = false, isStubTypeEqualsToAnything = false, ' 'false, false, ' compiler/fir/resolve/src/org/jetbrains/kotlin/fir/SessionUtils.kt
          regex-edit --optional 'argumentName = null,(\s+outerCallContext)' 'null,\1' compiler/frontend/src/org/jetbrains/kotlin/resolve/calls/tower/KotlinResolutionCallbacksImpl.kt
          regex-edit --optional 'forceToSkipNullabilityAnnotation = false,(\s+methodIndex\n    \))' 'false,\1' compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/ultraLightMethods.kt
          regex-edit --optional 'hasBoundExtensionReceiver = (candidate\.extensionReceiver != null,)' '\1' compiler/resolution/src/org/jetbrains/kotlin/resolve/calls/components/CallableReferenceResolver.kt
          regex-edit --optional 'topLevelType = null, context' 'null, context' compiler/resolution/src/org/jetbrains/kotlin/resolve/calls/inference/components/VariableFixationFinder.kt
        '')
        (ops.replace "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar intellij."193".core.passthru.asm} $f
          done
        '')
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/cli/cli-common/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/ir/serialization.common/src"
          "compiler/ir/serialization.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
          "core/type-system/src"
          "compiler/fir/cones/src"
          "compiler/fir/resolve/src"
          "compiler/fir/tree/src"
          "compiler/fir/psi2fir/src"
          "compiler/fir/fir2ir/src"
          "compiler/cli/cli-js/src"
          "compiler/fir/java/src"
          "compiler/fir/lightTree/src"
          "compiler/fir/tree/gen"
          "compiler/ir/serialization.jvm/src"
          "compiler/util-io/src"
          "compiler/util-klib/src"
          "compiler/util-klib-metadata/src"
          "compiler/ir/backend.wasm/src"
          "core/descriptors.runtime/src"
        ]))
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."193")
            annotations
            javac2
            core
            jps-model-impl
            ;
        };
    };
    "1.4.0-M1" = step k."1.3.72" "1.4.0-M1" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "language-1.4" ''
          sed -i -e 's|<compilerarg value="-version"/>|& <compilerarg line="-language-version 1.4 -api-version 1.3"/>|' build.xml
          grep -q 'language-version 1.4' build.xml
        '')
        (addLast "incremental-module-entry" ''
          sed -i 's|org.jetbrains.kotlin.daemon.common.IncrementalModuleEntry|org.jetbrains.kotlin.incremental.IncrementalModuleEntry|' \
            compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/multiproject/ModulesApiHistory.kt
        '')
        (addLast "builtins-reflect" ''
          # the kotlin.reflect interfaces moved from core/builtins to the stdlib sources; the builtins
          # serializer still gets them (reflect.kotlin_builtins)
          mkdir -p builtins-cherry
          for f in libraries/stdlib/src/kotlin/reflect/*.kt; do
            case $f in */typeOf.kt|*/KClasses.kt) ;; *) cp $f builtins-cherry/ ;; esac
          done
          sed -i '/<target name="serialize-builtins">/,/<\/target>/ s|^\( *\)<arg value="core/builtins/src"/>|&\n\1<arg value="builtins-cherry"/>|' build.xml
          grep -q 'builtins-cherry' build.xml
        '')
        (addLast "no-fir" noFir)
        (ops.replace "compiler-dirs" (compilerDirs [
          "compiler/util/src"
          "compiler/container/src"
          "compiler/resolution/src"
          "compiler/serialization/src"
          "compiler/psi/src"
          "compiler/frontend/src"
          "compiler/frontend.common/src"
          "compiler/frontend.java/src"
          "compiler/cli/cli-common/src"
          "compiler/ir/ir.tree/src"
          "compiler/ir/ir.psi2ir/src"
          "compiler/ir/backend.common/src"
          "compiler/ir/backend.jvm/src"
          "compiler/ir/backend.js/src"
          "compiler/ir/serialization.common/src"
          "compiler/ir/serialization.js/src"
          "compiler/backend-common/src"
          "compiler/backend/src"
          "compiler/plugin-api/src"
          "compiler/light-classes/src"
          "compiler/cli/src"
          "compiler/builtins-serializer/src"
          "compiler/javac-wrapper/src"
          "compiler/incremental-compilation-impl/src"
          "js/js.ast/src"
          "js/js.serializer/src"
          "js/js.parser/src"
          "js/js.frontend/src"
          "js/js.translator/src"
          "js/js.inliner/src"
          "js/js.dce/src"
          "build-common/src"
          "core/metadata/src"
          "core/metadata.jvm/src"
          "core/descriptors/src"
          "core/descriptors.jvm/src"
          "core/deserialization/src"
          "core/util.runtime/src"
          "core/type-system/src"
          "compiler/cli/cli-js/src"
          "compiler/ir/serialization.jvm/src"
          "compiler/util-io/src"
          "compiler/util-klib/src"
          "compiler/util-klib-metadata/src"
          "compiler/ir/backend.wasm/src"
          "core/descriptors.runtime/src"
          "native/frontend/src"
        ]))
      ];
    };
    "1.4.0-M2" = step k."1.4.0-M1" "1.4.0-M2" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs dirs14))
        (addLast "compiler-version" ''
          # META-INF/compiler.version, read by KotlinCompilerVersion
          mkdir -p compiler/compiler.version/resources/META-INF
          echo -n "1.4.0-bootstrap" > compiler/compiler.version/resources/META-INF/compiler.version
          regex-edit '(\n(\s*)<fileset dir="\$\{basedir\}/[^"]*" includes="META-INF/services/\*\*"[^>]*/>)' '\n\2<fileset dir="''${basedir}/compiler/compiler.version/resources" includes="META-INF/compiler.version"/>\1' build.xml
          grep -q 'compiler.version/resources' build.xml
        '')
      ];
    };
    "1.4.0-M3" = step k."1.4.0-M2" "1.4.0-M3" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "builtins-reflect-jvm-annotations" ''
          # the M2 serializer cannot resolve JVM annotations in the cherry-picked reflect sources
          sed -i -e '/^import kotlin.jvm.Jvm/d' -e '/^ *@Jvm\(Field\|Static\)$/d' builtins-cherry/*.kt
          ! grep -q '@Jvm' builtins-cherry/*.kt
        '')
        (addLast "stdlib-jdk8-types" ''
          # upstream compiles this against JDK 6 (no Type.getTypeName, no AnnotatedElement in TypeVariable)
          f=libraries/stdlib/jvm/src/kotlin/reflect/TypesJVM.kt
          regex-edit '(private interface TypeImpl : Type \{\n[^\n]*\n)    fun getTypeName\(\): String' '\1    override fun getTypeName(): String' $f
          regex-edit '(    override fun getBounds\(\): Array<Type> = [^\n]*\n)' '\1\n    override fun <T : Annotation?> getAnnotation(annotationClass: Class<T>): T? = null\n    override fun getAnnotations(): Array<Annotation> = emptyArray()\n    override fun getDeclaredAnnotations(): Array<Annotation> = emptyArray()\n    override fun getAnnotatedBounds(): Array<java.lang.reflect.AnnotatedType> = emptyArray()\n' $f
          grep -q getAnnotatedBounds $f
        '')
        (addLast "api-1.4" ''
          sed -i 's|-language-version 1.4 -api-version 1.3|-language-version 1.4 -api-version 1.4|' build.xml
          grep -q 'api-version 1.4' build.xml
        '')
        (addLast "fresh-stdlib" freshBuiltins)
      ];
    };
    "1.4.0-rc" = step k."1.4.0-M3" "1.4.0-rc" [ ] { steps = ops.delete "stdlib-jdk8-types"; };
    "1.4.0" = step k."1.4.0-rc" "1.4.0" [ ] { };
    "1.4.21" = step k."1.4.0" "1.4.21" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar intellij."201".core.passthru.asm} $f
          done
        '')
        (ops.replace "no-fir" noFir2)
        (addLast "duplicate-javaslang" ''
          rm compiler/frontend/src/org/jetbrains/kotlin/util/javaslang/javaslangAdapters.kt
        '')
        (addLast "opt-in" ''
          sed -i 's|-language-version 1.4 -api-version 1.4"/>|-language-version 1.4 -api-version 1.4 -Xopt-in=kotlin.RequiresOptIn -Xopt-in=org.jetbrains.kotlin.ir.ObsoleteDescriptorBasedAPI"/>|' build.xml
          grep -q ObsoleteDescriptorBasedAPI build.xml
        '')
        (addLast "core-compiler-common" ''
          sed -i -e '/<target name="core">/,/<\/target>/ { s|^\( *\)<include name="core/type-system/src"/>|\1<include name="core/compiler.common/src"/>\n\1<include name="core/compiler.common.jvm/src"/>|; s|^\( *\)<pathelement path="''${protobuf.jar}"/>|&\n\1<pathelement path="''${basedir}/ideaSDK/core/asm-6.0.jar"/>| }' build.xml
          grep -q 'core/compiler.common/src' build.xml
        '')
        (ops.replace "compiler-dirs" (compilerDirs dirs1421))
      ];
      inputs =
        i:
        i
        // {
          inherit (intellij."201") javac2 core jps-model-impl;
          # 18.x has TYPE_USE annotations, which Kotlin applies to array elements
          inherit (intellij."193") annotations;
        };
    };
    "1.4.32" = step k."1.4.21" "1.4.32" [ ] {
      steps = lib.flip lib.pipe [
        # SDK 202 would need fastutil and the split-off util modules: stay on SDK 201 but with ASM 8 (records)
        (ops.replace "sdk-asm" ''
          for f in ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-all*.jar; do
            ln -sf ${jar java.jetbrains-asm-8} $f
          done
        '')
        # the stdlib's version requirements (e.g. ULong ops need 1.4.30) are checked against this string
        (addLast "compiler-version-1432" ''
          echo -n "1.4.32" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
        (addLast "no-202-api" ''
          sed -i 's|LanguageLevel.JDK_15_PREVIEW|LanguageLevel.HIGHEST|' compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/JavaLanguageLevel.kt
          sed -i 's|classifierTypes(psi.permitsListTypes)|classifierTypes(emptyArray())|' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt
          sed -i 's|return owner.getPsi().hasModifierProperty(PsiModifier.SEALED);|return false;|' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementUtil.java
          # MAX_VALUE of the unsigned types is stdlib 1.4.30 API
          sed -i -e 's/UByte.MAX_VALUE.toLong()/0xFFL/' -e 's/UShort.MAX_VALUE.toLong()/0xFFFFL/' -e 's/UInt.MAX_VALUE.toLong()/0xFFFFFFFFL/' \
            core/descriptors/src/org/jetbrains/kotlin/resolve/constants/PrimitiveTypeUtil.kt
          grep -q 'classifierTypes(emptyArray())' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt
        '')
        (ops.replace "compiler-dirs" (compilerDirs dirs1432))
        (addLast "extensions-xml" ''
          # META-INF/extensions/compiler.xml: without it the packed compiler only works from a source checkout
          regex-edit '(\n(\s*)<fileset dir="\$\{basedir\}/compiler/compiler.version/resources" includes="META-INF/compiler.version"/>)' '\n\2<fileset dir="''${basedir}/compiler/cli/cli-common/resources" includes="META-INF/extensions/**"/>\1' build.xml
          grep -q 'META-INF/extensions' build.xml
        '')
        (addLast "core-deserialization-common" ''
          sed -i '/<target name="core">/,/<\/target>/ s|^\( *\)<include name="core/deserialization/src"/>|&\n\1<include name="core/deserialization.common/src"/>\n\1<include name="core/deserialization.common.jvm/src"/>|' build.xml
          grep -q 'core/deserialization.common/src' build.xml
        '')
      ];
    };
    "1.5.0-M1" = step k."1.4.32" "1.5.0-M1" [ ] {
      steps = lib.flip lib.pipe [
        (addLast "language-1.5" ''
          sed -i 's|-language-version 1.4 -api-version 1.4|-language-version 1.5 -api-version 1.5|' build.xml
          grep -q 'api-version 1.5' build.xml
        '')
        # SDK 202 API in the sources, SDK 201 is what we have
        # 1.5 dropped the experimental-coroutines stdlib; keep the (empty) target so later targets still work
        (addLast "no-experimental-coroutines" ''
          regex-edit '(?s)(<target name="stdlib">).*?(</target>)' '\1<mkdir dir="''${output}/classes/stdlib"/>\2' build.xml
          grep -q 'name="stdlib"><mkdir' build.xml
        '')
        (addLast "compiler-version-150" ''
          echo -n "1.5.0-M1" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
        (addLast "no-202-api-2" ''
          sed -i 's|PsiAugmentProvider.collectAugments(element, type, null)|PsiAugmentProvider.collectAugments(element, type)|' compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/lightClassPlatformUtils.kt
          sed -i 's|Interner.createStringInterner()|com.intellij.util.containers.StringInterner()|; s|MultiMap.createConcurrent<K, V>()|MultiMap.createConcurrentSet<K, V>()|' compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
          grep -q StringInterner compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
        '')
        (addLast "suppress-api-not-available" ''
          # the 1.4.32 compiler does not take 1.4.30 stdlib API as available even with -api-version 1.5
          for f in compiler/ir/backend.common/src/org/jetbrains/kotlin/backend/common/lower/loops/HeaderInfo.kt \
                   compiler/ir/backend.common/src/org/jetbrains/kotlin/backend/common/lower/loops/ProgressionType.kt \
                   compiler/ir/serialization.common/src/org/jetbrains/kotlin/backend/common/serialization/CityHash.kt; do
            if grep -q '^@file:Suppress(' $f; then
              regex-edit '(?m)^@file:Suppress\(' '@file:Suppress("API_NOT_AVAILABLE", ' $f
            else
              regex-edit '(?m)^package ' '@file:Suppress("API_NOT_AVAILABLE")\npackage ' $f
            fi
            grep -q 'API_NOT_AVAILABLE' $f
          done
        '')
      ];
    };

    "1.5.0-M2" = step k."1.5.0-M1" "1.5.0-M2" [ ] {
      steps = lib.flip lib.pipe [
        # Int.mod/floorDiv are stdlib 1.5 API, missing from the previous stdlib: drop constant folding for them
        (addLast "no-mod-floordiv" ''
          sed -i '/^ *"\(mod\|floorDiv\)" -> return /d' compiler/frontend/src/org/jetbrains/kotlin/resolve/constants/evaluate/OperationsMapGenerated.kt
          ! grep -q '"floorDiv" ->' compiler/frontend/src/org/jetbrains/kotlin/resolve/constants/evaluate/OperationsMapGenerated.kt
        '')
        # the 1.5 stdlib is JVM 1.8 bytecode with inline functions
        (addLast "jvm-target-1.8" ''
          sed -i -e 's|-jvm-target 1.6|-jvm-target 1.8|' build.xml
          grep -q 'jvm-target 1.8' build.xml
        '')
        (ops.delete "suppress-api-not-available")
        (ops.replace "compiler-version-150" ''
          echo -n "1.5.0-M2" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "1.5.0-RC" = step k."1.5.0-M2" "1.5.0-RC" [ ] {
      steps = lib.flip lib.pipe [
        # the 1.5.0-M2 compiler emits invalid invokedynamic method handles for bound references to interface methods
        (addLast "sam-conversions-class" ''
          sed -i -e 's|-jvm-target 1.8|-jvm-target 1.8 -Xsam-conversions=class|' build.xml
          grep -q 'sam-conversions=class' build.xml
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.5.0-RC" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "1.5.0" = step k."1.5.0-RC" "1.5.0" [ ] {
      steps = lib.flip lib.pipe [
        # minBy/maxBy became errors in the 1.5 stdlib
        (addLast "minby-or-null" ''
          sed -i 's/\.minBy {/.minByOrNull {/; s/\.maxBy {/.maxByOrNull {/' compiler/cli/src/org/jetbrains/kotlin/cli/jvm/JvmRuntimeVersionsConsistencyChecker.kt
          grep -q minByOrNull compiler/cli/src/org/jetbrains/kotlin/cli/jvm/JvmRuntimeVersionsConsistencyChecker.kt
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.5.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.1.20" = step k."2.1.0" "2.1.20" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs (dirs2120 ++ firDirs2120)))
        # APIs of newer IntelliJ SDKs (applyIf, addIfNotNull, elementType) and a duplicated constant
        (addLast "no-223-api-2120" ''
          sed -i '/^const val CONTINUATION_VARIABLE_NAME = /d' compiler/backend/src/org/jetbrains/kotlin/codegen/coroutines/coroutineCodegenUtil.kt
          sed -i 's|collectSources(configuration, projectEnvironment, messageCollector)|collectSources(configuration, projectEnvironment.project, messageCollector)|' compiler/cli/src/org/jetbrains/kotlin/cli/metadata/AbstractFirMetadataSerializer.kt
          f=compiler/ir/ir.tree/src/org/jetbrains/kotlin/ir/util/RenderIrElement.kt
          sed -i 's|^import com.intellij.util.applyIf$||' $f
          printf '\nprivate inline fun <T> T.applyIf(condition: Boolean, body: T.() -> T): T = if (condition) body() else this\n' >> $f
          sed -i 's|^import com.intellij.util.containers.addIfNotNull$|import org.jetbrains.kotlin.utils.addIfNotNull|' compiler/ir/serialization.common/src/org/jetbrains/kotlin/backend/common/serialization/NonLinkingIrInlineFunctionDeserializer.kt
          f=compiler/psi/src/org/jetbrains/kotlin/psi/psiUtil/psiUtils.kt
          sed -i 's|^import com.intellij.psi.util.elementType$||' $f
          printf '\nprivate val PsiElement?.elementType: com.intellij.psi.tree.IElementType? get() = this?.node?.elementType\n' >> $f
          sed -i 's|new AnnotationRemapper(null, |new AnnotationRemapper(|' compiler/backend/src/org/jetbrains/kotlin/codegen/inline/RemappingClassBuilder.java
          if grep -q 'const val CONTINUATION_VARIABLE_NAME' compiler/backend/src/org/jetbrains/kotlin/codegen/coroutines/coroutineCodegenUtil.kt; then exit 1; fi
        '')
        (ops.replace "no-scripting-plugin" ''
          f=compiler/daemon/src/org/jetbrains/kotlin/daemon/KotlinRemoteReplService.kt
          sed -i '/^import org.jetbrains.kotlin.scripting.compiler.plugin.ScriptingCompilerConfigurationComponentRegistrar$/d' $f
          sed -i 's|ScriptingCompilerConfigurationComponentRegistrar()|Class.forName("org.jetbrains.kotlin.scripting.compiler.plugin.ScriptingCompilerConfigurationComponentRegistrar").newInstance() as ComponentRegistrar|' $f
        '')
        (ops.replace "no-202-api" ''
          d=compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl
          sed -i 's|psi.permitsListTypes|arrayOf<com.intellij.psi.PsiClassType>()|' $d/JavaClassImpl.kt
          sed -i 's|return owner.getPsi().hasModifierProperty(PsiModifier.SEALED);|return false;|' $d/JavaElementUtil.java
          sed -i 's|return createTypeSource(psiTypeParameterSource.psi.permitsListTypes\[permittedTypeIndex\])|throw UnsupportedOperationException("sealed Java classes")|' $d/source/JavaElementSourceFactory.kt
          if grep -rq 'PsiModifier.SEALED' $d; then exit 1; fi
        '')
        (ops.replace "fir-by-k1" ''
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|& -Xopt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals -Xopt-in=org.jetbrains.kotlin.types.model.K2Only|' build.xml
          grep -q 'fir.symbols.SymbolInternals' build.xml
          # SDK 201 API (the 2.1.20 FIR is compiled by K2: the K1 workarounds of 2.1.0 are not needed)
          sed -i 's|override fun getType(): TypeInfo {|override fun getType(doResolve: Boolean): TypeInfo {|' compiler/fir/java/src/org/jetbrains/kotlin/fir/java/FirJavaElementFinder.kt
          sed -i 's#source?.psi.let { it is PsiMethod \&\& JavaPsiRecordUtil.isCanonicalConstructor(it) }#false#' compiler/fir/java/src/org/jetbrains/kotlin/fir/java/FirJavaFacade.kt
        '')
        # compiled by the K2-capable 2.1.0 (also for 2.2.0): language 2.1 (K2), with the 2.2 features the sources use
        (addLast "k2-language" ''
          sed -i 's|-language-version 1.9 -api-version 1.9|-language-version 2.1 -api-version 2.0 -Xwhen-guards -Xmulti-dollar-interpolation -Xnon-local-break-continue -Xcontext-parameters -Xopt-in=org.jetbrains.kotlin.backend.konan.InternalKotlinNativeApi -Xopt-in=kotlin.contracts.ExperimentalContracts|' build.xml
          grep -q 'language-version 2.1' build.xml
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.1.20" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.4.0" = step k."2.3.0" "2.4.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs (dirs240 ++ firDirs240)))
        # 2.4 moved more files between modules: put them where the inherited patch steps expect them
        (ops.addAfter "relocate-modules" "relocate-modules-240" ''
                    while read new old; do
                      [ -e "$new" ] || continue
                      mkdir -p "$(dirname "$old")"
                      mv "$new" "$old"
                    done <<'LIST'
          compiler/frontend/src/org/jetbrains/kotlin/analyzer/common/CommonResolverForModuleFactory.kt compiler/cli/cli-common/src/org/jetbrains/kotlin/analyzer/common/CommonResolverForModuleFactory.kt
          compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/common/arguments/preprocessCommandLineArguments.kt compiler/cli/cli-common/src/org/jetbrains/kotlin/cli/common/arguments/preprocessCommandLineArguments.kt
          compiler/cli/cli-jvm/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          compiler/cli/cli-jvm/src/org/jetbrains/kotlin/cli/jvm/compiler/cliCompilerUtils.kt compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/cliCompilerUtils.kt
          compiler/cli/cli-metadata/src/org/jetbrains/kotlin/cli/pipeline/metadata/MetadataFrontendPipelinePhase.kt compiler/cli/src/org/jetbrains/kotlin/cli/pipeline/metadata/MetadataFrontendPipelinePhase.kt
          core/language.targets.jvm/src/org/jetbrains/kotlin/config/JvmTarget.kt compiler/config.jvm/src/org/jetbrains/kotlin/config/JvmTarget.kt
          compiler/resolution.common/src/org/jetbrains/kotlin/resolve/calls/inference/components/VariableFixationFinder.kt compiler/resolution/src/org/jetbrains/kotlin/resolve/calls/inference/components/VariableFixationFinder.kt
          core/names/src/org/jetbrains/kotlin/name/FqNameUnsafe.kt core/compiler.common/src/org/jetbrains/kotlin/name/FqNameUnsafe.kt
          LIST
        '')
        # upstream fixed the IrDeclarationOrigin initialization cycle itself
        (ops.delete "origin-init-cycle")
        (ops.replace "context-before-annotations" ''
          # an annotation line (arguments nested up to three deep), a context list line
          ann='^[ \t]*@[A-Za-z][\w.]*(?:\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\))?[ \t]*\n'
          ctx='^[ \t]*context\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)[ \t]*\n'
          for f in $(grep -rlE '^[ \t]*context\(' --include=*.kt compiler core js native wasm analysis | grep -v testData); do
            regex-edit --all --optional "(?m)((?:$ann)+)($ctx)" '\2\1' $f
          done
          grep -q 'context(context: DiagnosticContext)' compiler/frontend.common/src/org/jetbrains/kotlin/diagnostics/KtDiagnosticReportHelpers.kt
        '')
        (ops.replace "psi-merged-java" ''
          sed -i 's#^    internal \(tailrec fun isDeclaredInsideValueArgument\|fun StubOutputStream.writeNullableBoolean\|fun StubInputStream.readNullableBoolean\)#    \1#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/StubUtils.kt
          sed -i 's#\$[a-z_]*psi_impl##' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/*.java
          sed -i 's#createStub(@NotNull \(KtImportDirective\|KtUserType\) psi, StubElement<?> parentStub)#createStub(@NotNull \1 psi, StubElement parentStub)#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtImportDirectiveElementType.java compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtUserTypeElementType.java
          if grep -rq 'psi_impl' compiler/psi/src; then exit 1; fi
        '')
        # the JS parser is ANTLR-based now: regenerate it with the (tunnelvisionlabs) ANTLR chain and ship the runtime
        (addLast "antlr-js-parser" ''
          ln -sf ${jar antlr.tvl-antlr4-runtime} ideaSDK/core/antlr4-runtime.jar
          ln -sf ${jar antlr.tvl-antlr4-runtime-annotations} ideaSDK/core/antlr4-runtime-annotations.jar
          sed -i 's|^\( *\)<zipfileset src="''${basedir}/ideaSDK/core/trove4j.jar"/>|&\n\1<zipfileset src="''${basedir}/ideaSDK/core/antlr4-runtime.jar"/>\n\1<zipfileset src="''${basedir}/ideaSDK/core/antlr4-runtime-annotations.jar"/>|' build.xml
          grep -q 'core/antlr4-runtime.jar' build.xml
          g=$PWD/js/js.parser/src/org/jetbrains/kotlin/js/parser/antlr/generated
          rm -f $g/*
          (cd js/js.parser/src/main/antlr && ${antlr.tvl-antlr4}/bin/antlr4 -visitor -package org.jetbrains.kotlin.js.parser.antlr.generated -o $g JavaScriptLexer.g4 JavaScriptParser.g4)
          test -f $g/JavaScriptParser.java
        '')
        (addLast "explicit-backing-fields" ''
          sed -i 's|-Xwhen-guards|-Xwhen-guards -Xexplicit-backing-fields|' build.xml
          grep -q 'Xexplicit-backing-fields' build.xml
        '')
        # 2.4 sources use language 2.4 features (explicit backing fields on overrides, contracts on getters, ...)
        (addLast "language-24" ''
          sed -i 's|-language-version 2.2 -api-version 2.2|-language-version 2.4 -api-version 2.3 -Xsuppress-version-warnings|; s|-Xopt-in=kotlin.contracts.ExperimentalContracts|& -Xopt-in=org.jetbrains.kotlin.K1Deprecation|' build.xml
          grep -q 'language-version 2.4' build.xml
          sed -i 's|<arg value="-Xopt-in=kotlin.contracts.ExperimentalContracts[^"]*"/>|&|' build.xml
        '')
        # APIs of newer IntelliJ SDKs, and the 2.3 patches that no longer apply
        (addLast "api-24-fixes" ''
                    # MockProject is a copy of a newer SDK class here; the SDK's own will do
                    rm compiler/cli/cli-base/src/com/intellij/mock/MockProject.kt
                    rm compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/DumbJavaModuleGraphHelper.java compiler/cli/src/com/intellij/openapi/progress/impl/CoreProgressManager.java
                    f=compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreApplicationEnvironment.kt
                    regex-edit '(?s)        if \(application\.getService\(JavaModuleGraphHelper::class\.java\) == null\) \{\n.*?\n        \}\n' "" $f
                    regex-edit '(?m)^import com\.intellij\.psi\.JavaModuleGraphHelper\n' "" $f
                    f=compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreEnvironment.kt
                    sed -i '/PsiJavaModuleModificationTracker/d' $f
                    if grep -q 'JavaModuleGraphHelper' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreApplicationEnvironment.kt; then exit 1; fi
                    # KParameter.Kind.CONTEXT is there now
                    f=compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/state/reflection/KParameterState.kt
                    sed -i 's|^\( *\)KParameter.Kind.EXTENSION_RECEIVER -> |\1@Suppress("OPT_IN_USAGE_ERROR") KParameter.Kind.CONTEXT -> append("context parameter ''${irParameter.name}")\n&|' $f
                    # collectSources keeps its VfsBasedProjectEnvironment
                    f=compiler/cli/src/org/jetbrains/kotlin/cli/common/GroupedKtSources.kt
                    sed -i 's|^import com.intellij.openapi.vfs.isFile$|import org.jetbrains.kotlin.cli.jvm.compiler.VfsBasedProjectEnvironment|; s|virtualFile\.isFile|!virtualFile.isDirectory|' $f
                    # compiler/cri-impl and friends
                    f=compiler/fir/raw-fir/psi2fir/src/org/jetbrains/kotlin/fir/builder/PsiRawFirBuilder.kt
                    sed -i 's|^import com.intellij.psi.util.childrenOfType$||' $f
                    printf '\nprivate inline fun <reified T : com.intellij.psi.PsiElement> com.intellij.psi.PsiElement.childrenOfType(): List<T> =\n    com.intellij.psi.util.PsiTreeUtil.getChildrenOfTypeAsList(this, T::class.java)\n' >> $f
                    sed -i 's|other\.elementType == elementType|other.stubType == stubType|' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/impl/KotlinPlaceHolderWithTextStubImpl.kt
                    f=compiler/ir/backend.wasm/src/org/jetbrains/kotlin/backend/wasm/ir2wasm/WasmCompiledModuleFragment.kt
                    sed -i 's|^import com.intellij.util.containers.reverse$||' $f
                    printf '\nprivate fun <K, V> Map<K, V>.reverse(): Map<V, K> = entries.associate { it.value to it.key }\n' >> $f
                    grep -rl 'import com.intellij.util.containers.addIfNotNull' compiler js native build-common | xargs -r sed -i 's|^import com.intellij.util.containers.addIfNotNull$|import org.jetbrains.kotlin.utils.addIfNotNull|'
                    # the JS parser is generated by tunnelvisionlabs' ANTLR (4.7.4) here: a few API differences
                    sed -i 's|parser\.tokenStream as CommonTokenStream|parser.inputStream as CommonTokenStream|' js/js.parser/src/org/jetbrains/kotlin/js/parser/JsParser.kt
                    cat > js/js.parser/src/org/jetbrains/kotlin/js/parser/antlr/RecognizerExtensions.kt <<'KT'
          package org.jetbrains.kotlin.js.parser.antlr

          import org.jetbrains.kotlin.js.parser.CodePosition
          import org.jetbrains.kotlin.js.parser.ErrorReporter
          import org.antlr.v4.runtime.ANTLRErrorListener
          import org.antlr.v4.runtime.BaseErrorListener
          import org.antlr.v4.runtime.Lexer
          import org.antlr.v4.runtime.Parser
          import org.antlr.v4.runtime.RecognitionException
          import org.antlr.v4.runtime.Recognizer
          import org.antlr.v4.runtime.Token

          internal fun Lexer.addErrorListener(reporter: ErrorReporter) {
              addErrorListener(object : ANTLRErrorListener<Int> {
                  override fun <T : Int> syntaxError(
                      recognizer: Recognizer<T, *>,
                      offendingSymbol: T?,
                      line: Int,
                      charPositionInLine: Int,
                      msg: String,
                      e: RecognitionException?,
                  ) {
                      reporter.error(msg, CodePosition(line, charPositionInLine), CodePosition(line, charPositionInLine))
                  }
              })
          }

          internal fun Parser.addErrorListener(reporter: ErrorReporter) {
              addErrorListener(object : BaseErrorListener() {
                  override fun <T : Token> syntaxError(
                      recognizer: Recognizer<T, *>,
                      offendingSymbol: T?,
                      line: Int,
                      charPositionInLine: Int,
                      msg: String,
                      e: RecognitionException?,
                  ) {
                      reporter.error(msg, CodePosition(line, charPositionInLine), CodePosition(line, charPositionInLine))
                  }
              })
          }
          KT
        '')
        # what the 2.3.0 compiler cannot do with 2.4 sources: explicit backing fields on overrides (use mutable property
        # types instead), `return` in expression bodies, and the CRI (needs the kotlinx.serialization plugin)
        (addLast "api-24-fixes-2" ''
          f=compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/IncrementalJvmCompilerRunnerBase.kt
          regex-edit '(?m)^import org\.jetbrains\.kotlin\.buildtools\.internal\.cri\.CriDataSerializerImpl\n' "" $f
          regex-edit '(?s)(        reporter\.info \{ "Generating Compiler Reference Index\.\.\." \}\n)\n        val serializer = CriDataSerializerImpl\(\).*?(\n    \}\n\}\s*)\Z' '\1\2' $f
          if grep -q CriDataSerializerImpl $f; then exit 1; fi
          sed -i 's|Map<KtSourceFile?, List<KtDiagnostic>>$|Map<KtSourceFile?, MutableList<KtDiagnostic>>|' compiler/frontend.common/src/org/jetbrains/kotlin/diagnostics/impl/DiagnosticsCollectorImpl.kt
          f=compiler/cli/cli-metadata/src/org/jetbrains/kotlin/cli/metadata/K1MetadataKlibSerializer.kt
          regex-edit '    override val moduleInfos: List<ModuleInfo>\n        field = ' '    private val klibModuleInfos = ' $f
          regex-edit '(    override val friendModuleInfos)' '    override val moduleInfos: List<ModuleInfo> get() = klibModuleInfos\n\n\1' $f
          regex-edit --all '= moduleInfos\.filter' '= klibModuleInfos.filter' $f
          grep -q 'private val klibModuleInfos' $f
          for f in \
            compiler/fir/checkers/src/org/jetbrains/kotlin/fir/analysis/checkers/config/ComposedLanguageVersionSettingsCheckers.kt \
            compiler/fir/resolve/src/org/jetbrains/kotlin/fir/resolve/calls/candidate/Candidate.kt \
            compiler/fir/resolve/src/org/jetbrains/kotlin/fir/resolve/inference/FirPCLAInferenceSession.kt \
            compiler/fir/semantics/src/org/jetbrains/kotlin/fir/resolve/dfa/cfg/CFGNode.kt \
            compiler/frontend.common/src/org/jetbrains/kotlin/diagnostics/impl/DiagnosticsCollectorImpl.kt \
            compiler/util-klib-metadata/src/org/jetbrains/kotlin/library/metadata/resolver/impl/KotlinResolvedLibraryImpl.kt
          do
            regex-edit --all '(?m)^(\s*(?:override )?val \w+: )(List|Set|Map)<([^\n]*)>\n\s+field = ' '\1Mutable\2<\3> = ' $f
            if grep -q '^\s*field = ' $f; then exit 1; fi
          done
          sed -i 's|    protected fun mangleTypeArguments(tBuilder: StringBuilder, type: Type, declarationSiteSession: Session) =|    protected fun mangleTypeArguments(tBuilder: StringBuilder, type: Type, declarationSiteSession: Session): Unit =|' compiler/ir/serialization.common/src/org/jetbrains/kotlin/backend/common/serialization/mangle/BaseKotlinMangleComputer.kt
          sed -i 's|addIfNotNull(exportModule)|exportModule?.let { add(it) }|' js/js.config/src/org/jetbrains/kotlin/js/artifacts/JsArtifactProducer.kt
        '')
        (addLast "psi-merged-java-2" ''
          sed -i 's#^    internal \(fun StubOutputStream.writeContract\|fun StubInputStream.readContract\)#    \1#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/StubUtils.kt
          sed -i 's#\$[a-z_]*psi_impl##' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/*.java
          sed -i 's#List<StubElement<?>> childrenStubs = stub.getChildrenStubs();#List<? extends StubElement> childrenStubs = stub.getChildrenStubs();#' compiler/psi/src/org/jetbrains/kotlin/psi/KtStringTemplateEntry.java
          sed -i 's#other.getElementType()#other.getStubType()#; s#this.getElementType()#this.getStubType()#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/impl/KotlinPlaceHolderStubImpl.java
          if grep -rq 'psi_impl' compiler/psi/src; then exit 1; fi
        '')
        (addLast "cli-resources-240" ''
          sed -i 's|compiler/cli/cli-common/resources|compiler/cli/cli-base/resources|g' build.xml
          ! grep -q 'cli-common/resources' build.xml
        '')
        # the stdlib's Java runtime sources use JetBrains annotations
        (addLast "javac-annotations-240" ''
          sed -i 's|^\( *\)<pathelement location="@{output}"/>$|&\n\1<pathelement location="''${basedir}/ideaSDK/core/annotations.jar"/>|' build.xml
          grep -q 'core/annotations.jar"/>' build.xml
        '')
        # core got new modules (names, language settings)
        (addLast "core-modules-240" ''
          sed -i 's|^\( *\)<include name="core/util.runtime/src"/>$|&\n\1<include name="core/names/src"/>\n\1<include name="core/language.model/src"/>\n\1<include name="core/language.targets/src"/>\n\1<include name="core/language.targets.jvm/src"/>\n\1<include name="core/language.version-settings/src"/>\n\1<include name="compiler/compiler.version/src"/>|' build.xml
          grep -q 'core/language.model/src' build.xml
        '')
        # JvmTarget (patched in compiler/config.jvm by the inherited steps) belongs to core now
        (addLast "jvm-target-core-240" ''
          mv compiler/config.jvm/src/org/jetbrains/kotlin/config/JvmTarget.kt core/language.targets.jvm/src/org/jetbrains/kotlin/config/JvmTarget.kt
        '')
        (addLast "reflect-opt-in-240" ''
          sed -i 's|moduleName="kotlin-reflection" additionalOptions="|&-opt-in=kotlin.ExperimentalContextParameters |' build.xml
          grep -q 'opt-in=kotlin.ExperimentalContextParameters' build.xml
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.4.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.3.0" = step k."2.2.0" "2.3.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs (dirs230 ++ firDirs230)))
        (ops.replace "no-213-api-java" ''
          sed -i 's|NotNullLazyValue.atomicLazy(|com.intellij.openapi.util.AtomicNotNullLazyValue.createValue(|' compiler/frontend/src/org/jetbrains/kotlin/resolve/diagnostics/DiagnosticsElementsCache.java
          sed -i 's|NotNullLazyValue.lazy(|NotNullLazyValue.createValue(|' compiler/psi/src/org/jetbrains/kotlin/idea/KotlinFileType.java compiler/psi/src/org/jetbrains/kotlin/idea/KotlinModuleFileType.java
          f=compiler/cli/src/org/jetbrains/kotlin/cli/common/messages/PlainTextMessageRenderer.kt
          sed -i '/import org.fusesource.jansi.internal.CLibrary/d; s|CLibrary.isatty(CLibrary.STDERR_FILENO) != 0|System.console() != null|' $f
          if grep -q CLibrary $f; then exit 1; fi
        '')
        (addLast "opt-ins-230" ''
          sed -i 's|-Xopt-in=kotlin.contracts.ExperimentalContracts|& -Xopt-in=kotlin.ExperimentalSubclassOptIn|' build.xml
          grep -q 'ExperimentalSubclassOptIn' build.xml
        '')
        # 2.3 sources call the stdlib's context(a, b) { } (@SinceKotlin("2.2"))
        (addLast "language-22" ''
          sed -i 's|-language-version 2.1 -api-version 2.0|-language-version 2.2 -api-version 2.2|' build.xml
          grep -q 'api-version 2.2' build.xml
        '')
        # KParameter.Kind.CONTEXT is not in the bootstrap's stdlib; api 2.2 makes toLowerCase an error
        (addLast "api-22-fixes" ''
          regex-edit '(?s)\s*// Can.t use `@OptIn.*?KParameter\.Kind\.CONTEXT,\s*-> append\("context parameter \$\{irParameter\.name\}"\)' "" compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/state/reflection/KParameterState.kt
          if grep -q 'Kind.CONTEXT' compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/state/reflection/KParameterState.kt; then exit 1; fi
          sed -i 's|this?.toLowerCase()|this?.lowercase()|' native/utils/src/org/jetbrains/kotlin/konan/target/Configurables.kt
          grep -rl '^import com.intellij.psi.util.elementType$' compiler --include=*.kt | grep -v psiUtil/psiUtils.kt | xargs -r sed -i 's|^import com.intellij.psi.util.elementType$|import org.jetbrains.kotlin.psi.psiUtil.elementType|'
        '')
        # psi-impl is merged into the psi module: its internal helpers are called from Java by mangled name;
        # SDK 201's IStubElementType.createStub takes a raw StubElement
        (addLast "psi-merged-java" ''
          sed -i 's#^    internal \(tailrec fun isDeclaredInsideValueArgument\|fun StubOutputStream.writeNullableBoolean\|fun StubInputStream.readNullableBoolean\)#    \1#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/StubUtils.kt
          sed -i 's|\$psi_impl||' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/*.java
          sed -i 's#createStub(@NotNull \(KtImportDirective\|KtUserType\) psi, StubElement<?> parentStub)#createStub(@NotNull \1 psi, StubElement parentStub)#' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtImportDirectiveElementType.java compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtUserTypeElementType.java
          if grep -rq 'psi_impl' compiler/psi/src; then exit 1; fi
        '')
        # the Ant tasks were dropped from the Kotlin repository in 2.3; the build still drives its own `kotlinc` Ant task
        # (runner, daemon-client) from the bootstrap's kotlin-ant.jar, so hand that jar on
        (addLast "no-ant-tools" ''
          regex-edit '(?s)<target name="ant-tools">.*?</target>' '<target name="ant-tools"><copy file="''${bootstrap.compiler.home}/lib/kotlin-ant.jar" todir="''${kotlin-home}/lib"/></target>' build.xml
          grep -q 'target name="ant-tools"><copy' build.xml
        '')
        # the 2.3 stdlib uses @IgnorableReturnValue (see libraries/stdlib/build.gradle.kts)
        (addLast "return-value-checker" ''
          sed -i 's|-Xcompile-builtins-as-part-of-stdlib|& -Xreturn-value-checker=full|' build.xml
          grep -q 'return-value-checker' build.xml
        '')
        # the 2.3 compiler ignores -Xopt-in (deprecated); kotlin.test uses unnamed locals and @IgnorableReturnValue
        (addLast "kotlin-test-230" ''
          sed -i 's|<arg value="-Xopt-in=kotlin.contracts.ExperimentalContracts[^"]*"/>|<arg value="-opt-in=kotlin.contracts.ExperimentalContracts"/> <arg value="-opt-in=kotlin.ExperimentalSubclassOptIn"/> <arg value="-Xreturn-value-checker=full"/> <arg value="-XXLanguage:+UnnamedLocalVariables"/>|' build.xml
          grep -q 'UnnamedLocalVariables' build.xml
        '')
        # core and reflection use context parameters now
        (addLast "core-context-parameters" ''
          sed -i 's|moduleName="kotlin-core" additionalOptions="|&-Xcontext-parameters |; s|moduleName="kotlin-reflection" additionalOptions="|&-Xcontext-parameters |' build.xml
          grep -c 'additionalOptions="-Xcontext-parameters' build.xml | grep -q 2
        '')
        # more APIs of newer IntelliJ SDKs (VirtualFile.toNioPath, asSafely, containers.addIfNotNull) and a duplicate declaration
        (addLast "no-223-api-230" ''
          sed -i 's|it\.file\.toNioPath()|java.nio.file.Paths.get(it.file.path)|' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/config/JvmContentRoots.kt compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/cliCompilerUtils.kt
          f=compiler/fir/fir-jvm/src/org/jetbrains/kotlin/fir/java/JavaUtils.kt
          sed -i 's|^import com.intellij.util.asSafely$||' $f
          printf '\nprivate inline fun <reified T> Any?.asSafely(): T? = this as? T\n' >> $f
          grep -rl 'import com.intellij.util.containers.addIfNotNull' compiler | xargs -r sed -i 's|^import com.intellij.util.containers.addIfNotNull$|import org.jetbrains.kotlin.utils.addIfNotNull|'
          sed -i 's|^private val PsiElement?.elementType|val PsiElement?.elementType|' compiler/psi/src/org/jetbrains/kotlin/psi/psiUtil/psiUtils.kt
          regex-edit '(?s)/\*\*\n \* The containing symbol is resolved using the declaration-site session.*?\n    \}\n\n' "" compiler/fir/resolve/src/org/jetbrains/kotlin/fir/resolve/ResolveUtils.kt
          if grep -q 'fun FirCallableDeclaration.getContainingClass' compiler/fir/resolve/src/org/jetbrains/kotlin/fir/resolve/ResolveUtils.kt; then exit 1; fi
        '')
        (ops.replace "new-inference" ''
          sed -i 's|<compilerarg line="-Xread-deserialized-contracts -Xeffect-system"/>|<compilerarg line="-Xread-deserialized-contracts -Xeffect-system -Xnew-inference"/>|' build.xml
        '')
        # 2.3 merged and split modules (psi, resolution.common.jvm, ...): put the files back where the inherited
        # patch steps expect them (everything is one compilation anyway)
        (ops.addAfter "restore-build-xml" "relocate-modules" ''
                    for d in parser psi-api psi-frontend-utils psi-impl psi-utils; do
                      cp -rn compiler/psi/$d/src/. compiler/psi/src/
                      rm -rf compiler/psi/$d/src
                    done
                    while read new old; do
                      [ -e "$new" ] || continue
                      mkdir -p "$(dirname "$old")"
                      mv "$new" "$old"
                    done <<'LIST'
          compiler/ir/backend.common/src/org/jetbrains/kotlin/backend/common/BackendException.kt compiler/backend-common/src/org/jetbrains/kotlin/backend/common/BackendException.kt
          compiler/frontend/src/org/jetbrains/kotlin/backend/common/SimpleMemberScope.kt compiler/backend-common/src/org/jetbrains/kotlin/backend/common/SimpleMemberScope.kt
          compiler/util/src/org/jetbrains/kotlin/backend/common/output/output.kt compiler/backend-common/src/org/jetbrains/kotlin/backend/common/output/output.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/kotlin/VirtualFileFinder.kt compiler/frontend.java/src/org/jetbrains/kotlin/load/kotlin/VirtualFileFinder.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/kotlin/VirtualFileFinderFactory.kt compiler/frontend.java/src/org/jetbrains/kotlin/load/kotlin/VirtualFileFinderFactory.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/JdkClasses.kt compiler/frontend.java/src/org/jetbrains/kotlin/resolve/jvm/JdkClasses.kt
          compiler/backend/src/org/jetbrains/kotlin/resolve/jvm/diagnostics/JvmDeclarationOrigin.kt compiler/frontend.java/src/org/jetbrains/kotlin/resolve/jvm/diagnostics/JvmDeclarationOrigin.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/asJava/KtClsJavaBasedLightClass.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/asJava/KtClsJavaBasedLightClass.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/asJava/KtLightClassMarker.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/asJava/KtLightClassMarker.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/asJava/SyntheticElementUtils.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/asJava/SyntheticElementUtils.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaAnnotationImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaAnnotationImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaAnnotationOwnerImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaAnnotationOwnerImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaArrayTypeImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaArrayTypeImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassifierImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassifierImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassifierTypeImpl.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassifierTypeImpl.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaConstructorImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaConstructorImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementCollectionFromPsiArrayUtil.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementCollectionFromPsiArrayUtil.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementUtil.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementUtil.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaFieldImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaFieldImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaMemberImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaMemberImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaMethodImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaMethodImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaModifierListOwnerImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaModifierListOwnerImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaPackageImpl.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaPackageImpl.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaPrimitiveTypeImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaPrimitiveTypeImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaRecordComponentImpl.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaRecordComponentImpl.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaTypeImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaTypeImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaTypeParameterImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaTypeParameterImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaValueParameterImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaValueParameterImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaWildcardTypeImpl.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaWildcardTypeImpl.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/NotEvaluatedConstAware.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/NotEvaluatedConstAware.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/VirtualFileBoundJavaClass.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/VirtualFileBoundJavaClass.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/annotationArgumentsImpl.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/annotationArgumentsImpl.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classNamesUtil.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classNamesUtil.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/javaPsiUtils.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/javaPsiUtils.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Annotations.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Annotations.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryClassSignatureParser.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryClassSignatureParser.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryJavaClass.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryJavaClass.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/ClassifierResolutionContext.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/ClassifierResolutionContext.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Methods.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Methods.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Other.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Other.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Types.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/Types.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/commonMixins.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/commonMixins.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementPsiSource.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementPsiSource.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementSourceFactory.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementSourceFactory.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementTypeSource.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaElementTypeSource.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaSourceFactoryOwner.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/source/JavaSourceFactoryOwner.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinCliJavaFileManager.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinCliJavaFileManager.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinFinderMarker.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinFinderMarker.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinJavaPsiFacade.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinJavaPsiFacade.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinSafeClassFinder.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinSafeClassFinder.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/NotFoundPackagesCachingStrategy.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/NotFoundPackagesCachingStrategy.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/TopPackageNamesProvider.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/TopPackageNamesProvider.kt
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/util/ConstUtils.java compiler/resolution.common.jvm/src/org/jetbrains/kotlin/util/ConstUtils.java
          compiler/frontend.common.jvm/src/org/jetbrains/kotlin/util/vavr/vavrAdapters.kt compiler/resolution.common.jvm/src/org/jetbrains/kotlin/util/vavr/vavrAdapters.kt
          js/js.config/src/org/jetbrains/kotlin/js/config/SourceMapNamesPolicy.kt js/js.frontend/src/org/jetbrains/kotlin/js/config/SourceMapNamesPolicy.kt
          js/js.config/gen/org/jetbrains/kotlin/js/config/JSConfigurationKeys.kt js/js.frontend/gen/org/jetbrains/kotlin/js/config/JSConfigurationKeys.kt
          compiler/fir/resolve/src/org/jetbrains/kotlin/fir/scopes/impl/FirActualizingScope.kt compiler/fir/providers/src/org/jetbrains/kotlin/fir/scopes/impl/FirActualizingScope.kt
          compiler/fir/tree/gen/org/jetbrains/kotlin/fir/expressions/builder/FirArgumentListBuilder.kt compiler/fir/tree/src/org/jetbrains/kotlin/fir/expressions/builder/FirArgumentListBuilder.kt
          compiler/fir/tree/gen/org/jetbrains/kotlin/fir/expressions/impl/FirArgumentListImpl.kt compiler/fir/tree/src/org/jetbrains/kotlin/fir/expressions/impl/FirArgumentListImpl.kt
          LIST
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.3.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.2.0" = step k."2.1.20" "2.2.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs (dirs220 ++ firDirs220)))
        # the sources use context parameters only (the two experimental features exclude each other)
        (addLast "context-parameters-only" ''
          sed -i 's| -Xcontext-receivers||g; s|-Xcontext-receivers ||g' build.xml
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals|& -Xopt-in=org.jetbrains.kotlin.fir.declarations.DirectDeclarationsAccess -Xopt-in=org.jetbrains.kotlin.DeprecatedForRemovalCompilerApi -Xopt-in=org.jetbrains.kotlin.fir.scopes.ScopeFunctionRequiresPrewarm -Xopt-in=org.jetbrains.kotlin.fir.types.UnexpandedTypeCheck|' build.xml
          if grep -q 'Xcontext-receivers' build.xml; then exit 1; fi
        '')
        # the 2.1.20 parser only accepts a context list in front of the annotations of a declaration
        (addLast "context-before-annotations" ''
          # an annotation line (arguments nested up to three deep), a context list line
          ann='^[ \t]*@[A-Za-z][\w.]*(?:\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\))?[ \t]*\n'
          ctx='^[ \t]*context\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)[ \t]*\n'
          for f in $(grep -rlE '^[ \t]*context\(' --include=*.kt compiler core js native wasm analysis | grep -v testData); do
            regex-edit --all --optional "(?m)((?:$ann)+)($ctx)" '\2\1' $f
          done
          grep -q 'context(_: DiagnosticContext)' compiler/frontend.common/src/org/jetbrains/kotlin/diagnostics/KtDiagnosticReportHelpers.kt
          if grep -B1 -A0 'context(_: DiagnosticContext)' compiler/frontend.common/src/org/jetbrains/kotlin/diagnostics/KtDiagnosticReportHelpers.kt | grep -q '^)'; then exit 1; fi
        '')
        # APIs of newer IntelliJ SDKs / ASM 9
        (addLast "no-223-api-220" ''
                    sed -i 's|Opcodes.ASM9|Opcodes.ASM8|' build-common/src/org/jetbrains/kotlin/incremental/impl/InstanceOwnerRecordingClassVisitor.kt
                    f=compiler/cli/src/org/jetbrains/kotlin/cli/common/utils.kt
                    sed -i '/^import com.intellij.openapi.application.runWriteAction$/d; s|^        runWriteAction {$|        ApplicationManager.getApplication().runWriteAction(Runnable {|' $f
                    regex-edit '(runWriteAction\(Runnable \{\n\s*Disposer\.dispose\(disposable\)\n\s*\})' '\1)' $f
                    sed -i 's|collectSources(configuration, projectEnvironment, messageCollector)|collectSources(configuration, projectEnvironment.project, messageCollector)|' compiler/cli/src/org/jetbrains/kotlin/cli/pipeline/metadata/MetadataFrontendPipelinePhase.kt
                    f=compiler/ir/serialization.js/src/org/jetbrains/kotlin/ir/backend/js/checkers/declarations/JsKlibPossibleFileClashWarning.kt
                    sed -i '/^import com.intellij.util.containers.without$/d; s|\.without(key)|.filterKeys { it != key }|' $f
                    cat > compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/LightClassesLazyCreator.kt <<'KT'
          package org.jetbrains.kotlin.asJava.classes

          import com.intellij.openapi.project.Project

          class LightClassesLazyCreator(private val project: Project) : KotlinClassInnerStuffCache.LazyCreator() {
              override fun <T : Any> get(initializer: () -> T, dependencies: List<Any>): Lazy<T> = lazy(LazyThreadSafetyMode.PUBLICATION, initializer)
          }
          KT
                    f=compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtBlockStringTemplateEntryElementType.kt
                    sed -i '/^import com.intellij.psi.util.childrenOfType$/d; s|psi.childrenOfType<KtExpression>()|com.intellij.psi.util.PsiTreeUtil.getChildrenOfTypeAsList(psi, KtExpression::class.java)|' $f
                    f=compiler/resolution.common.jvm/src/org/jetbrains/kotlin/asJava/KtClsJavaBasedLightClass.kt
                    sed -i '/^import org.jetbrains.annotations.ApiStatus$/d; /^@ApiStatus.Internal$/d' $f
                    if grep -q 'ApiStatus' $f; then exit 1; fi
        '')
        # 2.2: the builtins are compiled as part of the stdlib, which itself writes the .kotlin_builtins
        # (libraries/stdlib/build.gradle.kts); there is no separate serialization any more
        (addLast "builtins-as-part-of-stdlib" ''
          regex-edit '(?s)<target name="serialize-builtins">.*?</target>' '<target name="serialize-builtins"><mkdir dir="''${output}/builtins"/></target>' build.xml
          regex-edit '(?s)(<target name="builtins">.*?<src>\n)' '\1                <include name="libraries/stdlib/jvm/builtins"/>\n' build.xml
          regex-edit '(?s)(<target name="builtins">.*?)<class-path>\s*<pathelement path="\$\{output}/builtins"/>\s*</class-path>' '\1<class-path><pathelement path="''${output}/classes/none"/></class-path>' build.xml
          regex-edit '(?s)(<target name="builtins">.*?</new-kotlinc>)' '\1<mkdir dir="''${output}/builtins"/><move todir="''${output}/builtins"><fileset dir="''${output}/classes/builtins" includes="**/*.kotlin_builtins"/></move>' build.xml
          sed -i 's|-Xstdlib-compilation|-Xstdlib-compilation -Xoutput-builtins-metadata -Xcompile-builtins-as-part-of-stdlib -Xcontext-parameters|' build.xml
          grep -q 'Xoutput-builtins-metadata' build.xml
          sed -n '/<target name="builtins">/,/<\/target>/p' build.xml | grep libraries/stdlib/jvm/builtins
        '')
        # kotlin-reflect uses kotlin-metadata (kotlin.metadata.*) in 2.2: compile its sources into the reflection module
        (addLast "reflect-metadata" ''
          regex-edit '(?s)(<target name="reflection">\s*<new-kotlinc output="[^"]*" moduleName="kotlin-reflection" additionalOptions=")([^"]*)(">\s*<src>\n)' '\1\2 -Xallow-kotlin-package\3                <include name="libraries/kotlinx-metadata/src"/>\n                <include name="libraries/kotlinx-metadata/jvm/src"/>\n' build.xml
          sed -n '/<target name="reflection">/,/<\/target>/p' build.xml | grep kotlinx-metadata/jvm/src
        '')
        (ops.replace "no-223-api-2120" ''
          sed -i '/^const val CONTINUATION_VARIABLE_NAME = /d' compiler/backend/src/org/jetbrains/kotlin/codegen/coroutines/coroutineCodegenUtil.kt
          f=compiler/ir/ir.tree/src/org/jetbrains/kotlin/ir/util/RenderIrElement.kt
          sed -i 's|^import com.intellij.util.applyIf$||' $f
          printf '\nprivate inline fun <T> T.applyIf(condition: Boolean, body: T.() -> T): T = if (condition) body() else this\n' >> $f
          sed -i 's|^import com.intellij.util.containers.addIfNotNull$|import org.jetbrains.kotlin.utils.addIfNotNull|' compiler/fir/checkers/src/org/jetbrains/kotlin/fir/analysis/checkers/declaration/FirCyclicTypeBoundsChecker.kt
          f=compiler/psi/src/org/jetbrains/kotlin/psi/psiUtil/psiUtils.kt
          sed -i 's|^import com.intellij.psi.util.elementType$||' $f
          printf '\nprivate val PsiElement?.elementType: com.intellij.psi.tree.IElementType? get() = this?.node?.elementType\n' >> $f
          sed -i 's|new AnnotationRemapper(null, |new AnnotationRemapper(|' compiler/backend/src/org/jetbrains/kotlin/codegen/inline/RemappingClassBuilder.java
          if grep -q 'const val CONTINUATION_VARIABLE_NAME' compiler/backend/src/org/jetbrains/kotlin/codegen/coroutines/coroutineCodegenUtil.kt; then exit 1; fi
        '')
        (ops.replace "fir-by-k1" ''
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|& -Xopt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals -Xopt-in=org.jetbrains.kotlin.types.model.K2Only|' build.xml
          grep -q 'fir.symbols.SymbolInternals' build.xml
          # SDK 201 API
          sed -i 's|override fun getType(): TypeInfo {|override fun getType(doResolve: Boolean): TypeInfo {|' compiler/fir/fir-jvm/src/org/jetbrains/kotlin/fir/java/FirJavaElementFinder.kt
          sed -i 's#source?.psi.let { it is PsiMethod \&\& JavaPsiRecordUtil.isCanonicalConstructor(it) }#false#' compiler/fir/fir-jvm/src/org/jetbrains/kotlin/fir/java/FirJavaFacade.kt
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.2.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.1.0" = step k."2.0.0" "2.1.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs (dirs210 ++ firDirs210)))
        (ops.delete "duplicate-javaslang")
        # real K2: FIR is built (by the K1-only 2.0.0), so the K1-only stubs go away
        (ops.delete "no-fir")
        (ops.delete "k1-only")
        (addLast "immutable-collections" ''
          ln -sf ${
            jar (kotlinLibs.kotlinx-collections-immutable k."2.0.0")
          } ideaSDK/core/kotlinx-collections-immutable.jar
          sed -i 's|^\( *\)<zipfileset src="''${basedir}/ideaSDK/core/trove4j.jar"/>|&\n\1<zipfileset src="''${basedir}/ideaSDK/core/kotlinx-collections-immutable.jar"/>|' build.xml
          grep -q 'core/kotlinx-collections-immutable.jar' build.xml
        '')
        (ops.replace "no-213-api" ''
          rm compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/DummyJavaFileCodeStyleFacadeFactory.kt
          sed -i '/JavaFileCodeStyleFacade/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreApplicationEnvironment.kt
          sed -i '/hasConfiguredAnnotationRoot/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/MockExternalAnnotationsManager.kt
          f=build-common/src/org/jetbrains/kotlin/incremental/storage/LazyStorage.kt
          sed -i '/import com.intellij.util.io.AppendablePersistentMap/d; s|AppendablePersistentMap.ValueDataAppender|PersistentHashMap.ValueDataAppender|' $f
          f=wasm/wasm.ir/src/org/jetbrains/kotlin/wasm/ir/convertors/WasmIrToBinary.kt
          sed -i '/import kotlinx.collections.immutable/d; s|private var offsets = persistentListOf<Box>()|private var offsets: List<Box> = emptyList()|' $f
          rm -rf compiler/ir/serialization.js/src/org/jetbrains/kotlin/fir
        '')
        (addLast "vavr" ''
          ln -s ${jar java.vavr} dependencies/vavr-0.10.4.jar
          sed -i 's|javaslang-2.0.6.jar|vavr-0.10.4.jar|g' build.xml
          rm compiler/frontend/src/org/jetbrains/kotlin/util/vavr/vavrAdapters.kt
          grep -q 'vavr-0.10.4.jar' build.xml
        '')
        (addLast "no-223-api" ''
          # `when` guard conditions are a 2.1 language feature
          sed -i "s|'\\.' if !isBacktick -> return index|'.' -> if (!isBacktick) return index|" core/compiler.common/src/org/jetbrains/kotlin/name/FqNameUnsafe.kt
          if grep -q "if !isBacktick ->" core/compiler.common/src/org/jetbrains/kotlin/name/FqNameUnsafe.kt; then exit 1; fi
          # PsiTypes replaced the PsiType constants
          for f in $(grep -rl 'PsiTypes' --include=*.kt --include=*.java analysis compiler core | grep -v '/tests\?/'); do
            sed -i -E 's/PsiTypes\.(boolean|byte|char|double|float|int|long|short|void|null)Type\(\)/PsiType.\U\1/g; s/import com\.intellij\.psi\.PsiTypes$/import com.intellij.psi.PsiType/' $f
          done
          if grep -rq 'PsiTypes' --include=*.kt analysis/light-classes-base compiler/light-classes compiler/util; then
            grep -rn 'PsiTypes' --include=*.kt analysis/light-classes-base compiler/light-classes compiler/util; exit 1
          fi
          for f in $(grep -rl 'import com.intellij.psi.PsiType$' --include=*.kt analysis/light-classes-base compiler/light-classes compiler/util); do
            awk '!(/^import / && seen[$0]++)' $f > $f.new && mv $f.new $f
          done
          sed -i 's|ClassLoader.getPlatformClassLoader()|(ClassLoader::class.java.getMethod("getPlatformClassLoader").invoke(null) as ClassLoader)|' compiler/build-tools/kotlin-build-tools-jdk-utils/src/main/kotlin/org/jetbrains/kotlin/buildtools/internal/classLoaderUtils.kt
          rm compiler/cli/cli-base/src/com/intellij/openapi/util/ObjectNode.java
          sed -i '/import com.intellij.util.containers.CollectionFactory;/d; s|CollectionFactory.createFilePathSet()|new java.util.HashSet<String>()|' compiler/util/src/org/jetbrains/kotlin/utils/JavaSdkUtil.java
          grep -rl 'IntellijInternalApi' --include=*.kt analysis compiler | xargs -r sed -i '/IntellijInternalApi/d'
          f=analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/classes/ClassContentFinderCache.kt
          regex-edit '(?m)^import [^\n]*thisLogger\n' "" $f
          regex-edit '(?s)thisLogger\(\)\.logErrorWithAttachment\("([^"]*)"\) \{.*?\n\s*\}' 'com.intellij.openapi.diagnostic.Logger.getInstance(ClassContentFinderCache::class.java).error("\1")' $f
          f=compiler/frontend.common-psi/src/org/jetbrains/kotlin/diagnostics/PositioningStrategies.kt
          sed -i '/^import com.intellij.psi.util.descendants$/d' $f
          printf '\nprivate fun PsiElement.descendants(): Sequence<PsiElement> = children.asSequence().flatMap { sequenceOf(it) + it.descendants() }\n' >> $f
          rm compiler/cli/cli-base/src/com/intellij/openapi/vfs/virtualFileSetFactory.kt
          sed -i '/VirtualFileSetFactory\|InternalPersistentJavaLanguageLevelReaderService/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreEnvironment.kt
          sed -i 's/override fun getNioPath/fun getNioPath/; s/override fun findFileByNioFile/fun findFileByNioFile/' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/common/localfs/KotlinLocalFileSystem.kt
          f=compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/ultraLightUtils.kt
          regex-edit 'StubBuildingVisitor\.GUESSING_PROVIDER' 'StubBuildingVisitor.GUESSING_MAPPER' $f
          regex-edit 'SignatureParsing\.CharIterator\(canonicalSignature\)' 'java.text.StringCharacterIterator(canonicalSignature)' $f
          regex-edit 'val typeInfo = SignatureParsing\.parseTypeStringToTypeInfo\(signature, GUESSING_PROVIDER\)\n\s*val typeText = typeInfo\.text\(\) \?: return PsiType\.NULL' 'val typeText = SignatureParsing.parseTypeString(signature, GUESSING_MAPPER) ?: return PsiType.NULL' $f
          sed -i 's/GUESSING_PROVIDER/GUESSING_MAPPER/' $f
          sed -i 's|containerSource ?: super.source|containerSource ?: SourceElement.NO_SOURCE|' compiler/util-klib-metadata/src/org/jetbrains/kotlin/library/metadata/KlibMetadataPackageFragment.kt
          f=compiler/ir/serialization.native/src/org/jetbrains/kotlin/backend/konan/serialization/IrUtils.kt
          regex-edit 'val containerSource = if \(topLevelDeclaration is AbstractFir2IrLazyDeclaration<\*>\)\n\s*getSourceElementFromFir\(topLevelDeclaration\)\n\s*else\n\s*getSourceElementFromDescriptor\(topLevelDeclaration\)' 'val containerSource = getSourceElementFromDescriptor(topLevelDeclaration)' $f
          regex-edit '(?s)private fun getSourceElementFromFir\(.*?\n    \}\n\n' "" $f
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|& -Xopt-in=org.jetbrains.kotlin.ir.util.JvmIrInlineExperimental|' build.xml
          grep -q JvmIrInlineExperimental build.xml
        '')
        # core/builtins and core/runtime.jvm are gone: the builtins live in the stdlib sources (as `actual`s)
        (addLast "builtins-in-stdlib" ''
          mkdir -p builtins-native builtins-native-src/annotation builtins-native-src/internal
          for f in libraries/stdlib/jvm/builtins/*.kt; do
            sed 's/\bactual //' $f > builtins-native/$(basename $f)
          done
          for f in Unit.kt ArrayIntrinsics.kt; do sed 's/\bactual //' libraries/stdlib/jvm/src/kotlin/$f > builtins-native-src/$f; done
          cp libraries/stdlib/src/kotlin/Function.kt libraries/stdlib/src/kotlin/Annotations.kt builtins-native-src/
          cp libraries/stdlib/src/kotlin/annotation/Annotations.kt builtins-native-src/annotation/
          cp libraries/stdlib/src/kotlin/internal/AnnotationsBuiltin.kt builtins-native-src/internal/
          sed -i 's|<arg value="core/builtins/native"/>|<arg value="builtins-native"/>|; s|<arg value="core/builtins/src"/>|<arg value="builtins-native-src"/>|; s|<include name="core/builtins/src"/>|<include name="libraries/stdlib/jvm/builtins"/>|; /<include name="core\/runtime.jvm\/src"\/>/d' build.xml
          if grep -q 'core/builtins\|runtime.jvm/src"' build.xml; then exit 1; fi
        '')
        (ops.replace "no-203-api" ''
          f=compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/KotlinClassInnerStuffCache.kt
          sed -i 's|PsiKeyword.SEALED|"sealed"|; s|PsiAugmentProvider.collectAugments(element, type, null)|PsiAugmentProvider.collectAugments(element, type)|' $f
          if grep -q 'PsiKeyword.SEALED\|element, type, null' $f; then exit 1; fi
        '')
        (ops.replace "no-202-api-2" ''
          sed -i 's|Interner.createStringInterner()|com.intellij.util.containers.StringInterner()|; s|MultiMap.createConcurrent<K, V>()|MultiMap.createConcurrentSet<K, V>()|' compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
          grep -q StringInterner compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
        '')
        # the FIR modules need far more than 5g (the JVM thrashes in GC otherwise)
        (addLast "more-heap-fir" ''export ANT_OPTS="$ANT_OPTS -Xmx14g"'')
        # the stdlib is compiled by K2 itself, with the flags of libraries/stdlib/build.gradle.kts
        (addLast "stdlib-k2-flags" ''
          sed -i 's|-Xbuiltins-from-sources|-Xstdlib-compilation -Xdont-warn-on-error-suppression -Xexpect-actual-classes -Xsuppress-missing-builtins-error -Xno-new-java-annotation-targets -Xallow-kotlin-package|' build.xml
          grep -q 'Xstdlib-compilation' build.xml
          # as in libraries/stdlib/build.gradle.kts the builtins (jvm/builtins) are only serialized, not compiled with the stdlib
          sed -i '/<include name="libraries\/stdlib\/jvm\/builtins"\/>/d' build.xml
          if grep -q 'include name="libraries/stdlib/jvm/builtins"' build.xml; then exit 1; fi
        '')
        # FIR sources compiled by the K1-only 2.0.0 and against SDK 201
        (addLast "fir-by-k1" ''
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|& -Xopt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals -Xopt-in=org.jetbrains.kotlin.types.model.K2Only|' build.xml
          grep -q 'fir.symbols.SymbolInternals' build.xml
          f=compiler/fir/resolve/src/org/jetbrains/kotlin/fir/resolve/transformers/body/resolve/FirExpressionsResolveTransformer.kt
          regex-edit 'when \(data\) \{\n(\s*)is ResolutionMode\.WithExpectedType if data\.arrayLiteralPosition != null ->' 'when {\n\1data is ResolutionMode.WithExpectedType && data.arrayLiteralPosition != null ->' $f
          grep -q 'data is ResolutionMode.WithExpectedType && data.arrayLiteralPosition' $f
          f=compiler/cli/src/org/jetbrains/kotlin/cli/metadata/FirLegacyMetadataSerializer.kt
          sed -i 's|content.membersPerFile.getOrPut(firFile) { mutableListOf() } += declaration|content.membersPerFile.getOrPut(firFile) { mutableListOf() }.add(declaration as FirMemberDeclaration)|' $f
          grep -q 'declaration as FirMemberDeclaration' $f
          grep -q '^import org.jetbrains.kotlin.fir.declarations.FirMemberDeclaration' $f || sed -i '0,/^import org.jetbrains.kotlin.fir.declarations/s//import org.jetbrains.kotlin.fir.declarations.FirMemberDeclaration\n&/' $f
          f=compiler/fir/java/src/org/jetbrains/kotlin/fir/java/FirJavaElementFinder.kt
          sed -i 's|override fun getType(): TypeInfo {|override fun getType(doResolve: Boolean): TypeInfo {|' $f
          f=compiler/fir/java/src/org/jetbrains/kotlin/fir/java/FirJavaFacade.kt
          sed -i 's#source?.psi.let { it is PsiMethod \&\& JavaPsiRecordUtil.isCanonicalConstructor(it) }#false#' $f
          sed -i 's|collectSources(compilerConfiguration, projectEnvironment, messageCollector)|collectSources(compilerConfiguration, projectEnvironment.project, messageCollector)|' compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/pipeline/jvmCompilerPipelineLightTree.kt
          sed -i 's|collectSources(configuration, projectEnvironment, messageCollector)|collectSources(configuration, projectEnvironment.project, messageCollector)|' compiler/cli/src/org/jetbrains/kotlin/cli/metadata/AbstractFirMetadataSerializer.kt
          sed -i 's|convertConstructorDelegationCall(delegatedConstructorNode, classWrapper, isExpect)|convertConstructorDelegationCall(delegatedConstructorNode!!, classWrapper, isExpect)|' compiler/fir/raw-fir/light-tree2fir/src/org/jetbrains/kotlin/fir/lightTree/converter/LightTreeRawFirDeclarationBuilder.kt
          grep -q 'delegatedConstructorNode!!' compiler/fir/raw-fir/light-tree2fir/src/org/jetbrains/kotlin/fir/lightTree/converter/LightTreeRawFirDeclarationBuilder.kt
          f=compiler/fir/java/src/org/jetbrains/kotlin/fir/java/enhancement/SignatureEnhancement.kt
          sed -i 's|typeParameterSubstitutor.substituteOrNull(newReturnTypeRef.coneType)|typeParameterSubstitutor!!.substituteOrNull(newReturnTypeRef.coneType)|' $f
          grep -q 'typeParameterSubstitutor!!' $f
        '')
        # IrDeclarationOriginImpl implements an interface with a default method, so initializing it first
        # initializes IrDeclarationOrigin, whose companion reads IrDeclarationOriginImpl.Companion (still null)
        (addLast "origin-init-cycle" ''
                    f=compiler/ir/ir.tree/src/org/jetbrains/kotlin/ir/declarations/IrDeclarationOrigin.kt
                    sed -i -e 's# by IrDeclarationOriginImpl\.Synthetic$# by SyntheticOriginDelegate#' -e 's# by IrDeclarationOriginImpl$# by OriginDelegate#' $f
                    cat >> $f <<'KT'

          object OriginDelegate : PropertyDelegateProvider<Any?, ReadOnlyProperty<Any?, IrDeclarationOriginImpl>> {
              override fun provideDelegate(thisRef: Any?, property: KProperty<*>): ReadOnlyProperty<Any?, IrDeclarationOriginImpl> =
                  IrDeclarationOriginImpl(property.name)
          }

          object SyntheticOriginDelegate : PropertyDelegateProvider<Any?, ReadOnlyProperty<Any?, IrDeclarationOriginImpl>> {
              override fun provideDelegate(thisRef: Any?, property: KProperty<*>): ReadOnlyProperty<Any?, IrDeclarationOriginImpl> =
                  IrDeclarationOriginImpl(property.name, isSynthetic = true)
          }
          KT
                    if grep -q ' by IrDeclarationOriginImpl' $f; then exit 1; fi
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.1.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "2.0.0" = step k."1.9.0" "2.0.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs dirs200))
        (ops.delete "no-fir-reporter")
        # without FIR the default language version 2.0 must still use the classic frontend
        (addLast "k1-only" ''
          f=compiler/cli/src/org/jetbrains/kotlin/cli/common/arguments.kt
          sed -i 's|put(CommonConfigurationKeys.USE_FIR, usesK2)|put(CommonConfigurationKeys.USE_FIR, false)|' $f
          grep -q 'USE_FIR, false' $f
        '')
        (addLast "no-213-api-3" ''
          f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit --optional '(?s)\.apply \{\n\s*if \(firJvmBackendClassResolver != null\) \{.*?\n\s*\}\n\s*\}\.build\(\)' '.build()' $f
          regex-edit --optional '(?s)\.let \{\n\s*if \(it is JvmIrCodegenFactory\.JvmIrBackendInput && firJvmBackendExtension != null\) \{.*?\} else it\n\s*\}' "" $f
          ! grep -q 'firJvmBackendExtension != null\|firJvmBackendClassResolver != null' $f
          regex-edit --optional '@Deprecated\("Moved to the \x27:core:descriptors\x27 module", level = DeprecationLevel\.HIDDEN\)\nfun AnnotationDescriptor\.argumentValue[^\n]*\n' "" compiler/frontend/src/org/jetbrains/kotlin/resolve/AnnotationUtil.kt
          ! grep -q 'fun AnnotationDescriptor.argumentValue' compiler/frontend/src/org/jetbrains/kotlin/resolve/AnnotationUtil.kt
          sed -i 's|it.fileSystem.getNioPath(it)?.toFile()|File(it.path)|' compiler/ir/ir.actualization/src/main/kotlin/org/jetbrains/kotlin/backend/common/actualizer/ExpectActualCollector.kt
          sed -i 's|Topic(KotlinCodeFragmentImportModificationListener::class.java, Topic.BroadcastDirection.TO_CHILDREN, true)|Topic("KotlinCodeFragmentImportModificationListener", KotlinCodeFragmentImportModificationListener::class.java, Topic.BroadcastDirection.TO_CHILDREN)|' compiler/psi/src/org/jetbrains/kotlin/psi/KtCodeFragment.kt
          grep -q 'Topic("Kotlin' compiler/psi/src/org/jetbrains/kotlin/psi/KtCodeFragment.kt
        '')
        (addLast "no-213-api-java-2" ''
          sed -i 's#SearchScope.isEmptyScope(\(scope\|searchScope\))#(\1 == com.intellij.psi.search.GlobalSearchScope.EMPTY_SCOPE)#' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinJavaPsiFacade.java
          sed -i 's#PsiFieldImpl.getDetachedInitializer(variable)#(variable instanceof PsiFieldImpl ? ((PsiFieldImpl) variable).getDetachedInitializer() : variable.getInitializer())#' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/util/ConstUtils.java
          if grep -q 'SearchScope.isEmptyScope' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/resolve/jvm/KotlinJavaPsiFacade.java; then exit 1; fi
          grep -q 'instanceof PsiFieldImpl' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/util/ConstUtils.java
        '')
        # the K2 compiler uses fastutil all over
        (addLast "fastutil" ''
          ln -sf ${jar java.fastutil} ideaSDK/core/fastutil.jar
          sed -i 's|^\( *\)<zipfileset src="''${basedir}/ideaSDK/core/trove4j.jar"/>|&\n\1<zipfileset src="''${basedir}/ideaSDK/core/fastutil.jar"/>|' build.xml
          grep -q 'core/fastutil.jar' build.xml
        '')
        (addLast "no-213-api-2" ''
          f=analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/LightClassUtil.kt
          sed -i '/import com.intellij.openapi.util.NlsSafe/d; s|@NlsSafe ||' $f
          sed -i 's|ExternalIntegerKeyDescriptor.INSTANCE|ExternalIntegerKeyDescriptor()|' build-common/src/org/jetbrains/kotlin/incremental/storage/IdToFileMap.kt
          f=compiler/cli/src/org/jetbrains/kotlin/cli/common/GroupedKtSources.kt
          regex-edit '(?m)^import [^\n]*VfsBasedProjectEnvironment\n' "" $f
          regex-edit --optional '(?s)fun collectSources\(\n    compilerConfiguration: CompilerConfiguration,\n    projectEnvironment: VfsBasedProjectEnvironment,.*?\n\}\n\n' "" $f
          ! grep -q 'NlsSafe\|VfsBasedProjectEnvironment' analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/LightClassUtil.kt $f
        '')
        (ops.replace "no-213-api" ''
          sed -i 's|\.map { it\.toFile() }||; s|getJdkClassesRoots(Paths.get(javaHome), true)|getJdkClassesRoots(File(javaHome), true)|; s|getJdkClassesRoots(jdkHome.toPath(), false)|getJdkClassesRoots(jdkHome, false)|; s|getJdkClassesRoots(javaRoot.toPath(), !isJdk)|getJdkClassesRoots(javaRoot, !isJdk)|' compiler/util/src/org/jetbrains/kotlin/utils/PathUtil.kt
          rm compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/DummyJavaFileCodeStyleFacadeFactory.kt
          sed -i '/JavaFileCodeStyleFacade/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreApplicationEnvironment.kt
          sed -i '/hasConfiguredAnnotationRoot/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/MockExternalAnnotationsManager.kt
          f=build-common/src/org/jetbrains/kotlin/incremental/storage/LazyStorage.kt
          sed -i '/import com.intellij.util.io.AppendablePersistentMap/d; s|AppendablePersistentMap.ValueDataAppender|PersistentHashMap.ValueDataAppender|' $f
          f=wasm/wasm.ir/src/org/jetbrains/kotlin/wasm/ir/convertors/WasmIrToBinary.kt
          sed -i '/import kotlinx.collections.immutable/d; s|private var offsets = persistentListOf<Box>()|private var offsets: List<Box> = emptyList()|' $f
          rm -rf compiler/ir/serialization.js/src/org/jetbrains/kotlin/fir
        '')
        (ops.replace "no-202-api" ''
          d=compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl
          sed -i 's|psi.permitsListTypes|arrayOf<com.intellij.psi.PsiClassType>()|' $d/JavaClassImpl.kt
          sed -i 's|return owner.getPsi().hasModifierProperty(PsiModifier.SEALED);|return false;|' $d/JavaElementUtil.java
          sed -i 's|return createTypeSource(psiTypeParameterSource.psi.permitsListTypes\[permittedTypeIndex\])|throw UnsupportedOperationException("sealed Java classes")|' $d/source/JavaElementSourceFactory.kt
          ! grep -rq 'permitsListTypes\|PsiModifier.SEALED' $d
        '')
        (ops.replace "no-fir" ''
          d=compiler/cli/src/org/jetbrains/kotlin/cli
          rm -r $d/jvm/compiler/pipeline
          rm $d/common/FirSessionConstructionUtils.kt $d/metadata/FirMetadataSerializer.kt
          rm $d/jvm/compiler/FirKotlinToJvmBytecodeCompiler.kt $d/jvm/compiler/VfsBasedProjectEnvironment.kt $d/jvm/compiler/firFindMainClass.kt
          rm compiler/ir/serialization.js/src/org/jetbrains/kotlin/fir/backend/js/FirJsKotlinMangler.kt
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/IncrementalFirJvmCompilerRunner.kt
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/incrementalFirCacheUtils.kt
          stub='throw UnsupportedOperationException("FIR is not part of the bootstrap build")'
          # the diagnostics reporter is shared with K1; drop its FIR error factories
          f=$d/common/fir/FirDiagnosticsCompilerResultsReporter.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit --all 'diagnosticsCollector\.diagnostics\.any \{ it\.factory == FirErrors\.\w+ \}' 'false' $f
          # utils.kt: light tree package check
          f=$d/common/utils.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit '(?s)\nfun checkKotlinPackageUsageForLightTree\(.*?(\nfun <PathProvider)' '\1' $f
          # cliCompilerUtils.kt: FIR session helpers
          f=$d/jvm/compiler/cliCompilerUtils.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit '(?s)\nfun createContextForIncrementalCompilation\(.*\Z' '\n' $f
          sed -i '/FirMetadataSerializer/d' $d/metadata/K2MetadataCompiler.kt
          # KotlinToJVMBytecodeCompiler: classic frontend only
          f=$d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit --all '(?m)^import [^\n]*(?:\.fir\.|FirKotlinToJvmBytecodeCompiler|\.pipeline\.)[^\n]*\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(useFrontendIR\) \{.*?\n        \} else \{' 'if (useFrontendIR) {\n            @STUB@\n        } else {' $f
          regex-edit '(?s)    private fun runFrontendAndGenerateIrForMultiModuleChunkUsingFrontendIR\(.*?(    private fun runFrontendAndGenerateIrUsingClassicFrontend)' '\1' $f
          regex-edit '(?s)    private fun Fir2IrActualizedResult\.codegenFactoryWithJvmIrBackendInput\(.*?\n    \}\n\n' "" $f
          regex-edit --all ': Fir(?:JvmBackendClassResolver|JvmBackendExtension)\?' ': Nothing?' $f
          regex-edit '        FirDiagnosticsCompilerResultsReporter' '        org.jetbrains.kotlin.cli.common.fir.FirDiagnosticsCompilerResultsReporter' $f
          f=$d/jvm/K2JVMCompiler.kt
          regex-edit --all '(?m)^import [^\n]*\.pipeline\.[^\n]*\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(chunk\.size == 1 &&\s*configuration\.getBoolean\(CommonConfigurationKeys\.USE_FIR\) &&\s*configuration\.getBoolean\(CommonConfigurationKeys\.USE_LIGHT_TREE\)\s*\) \{.*?\} else \{' 'if (false) {\n                @STUB@\n            } else {' $f
          f=compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/CompilerRunnerUtils.kt
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(useK2 && args\.useFirIC && args\.useFirLT[^\n]*\n\s*IncrementalFirJvmCompilerRunner\(.*?\n\s*\)\n(\s*)else' 'if (false) @STUB@\n\1else' $f
          # JS: K1 only
          f=compiler/cli/cli-js/src/org/jetbrains/kotlin/cli/js/K2JsIrCompiler.kt
          regex-edit '(?m)^import [^\n]*Fir2KlibMetadataSerializer\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)(    private fun processSourceModuleWithK2\([^)]*\): ModulesStructure \{\n).*?(\n    class IcCachesArtifacts)' '\1        @STUB@\n    }\n\2' $f
          f=compiler/cli/cli-js/src/org/jetbrains/kotlin/cli/js/klib/jsCompilerPipeline.kt
          cat > $f <<'KT'
          package org.jetbrains.kotlin.cli.js.klib

          import org.jetbrains.kotlin.cli.common.CLIConfigurationKeys
          import org.jetbrains.kotlin.cli.common.fir.FirDiagnosticsCompilerResultsReporter
          import org.jetbrains.kotlin.cli.common.messages.MessageCollector
          import org.jetbrains.kotlin.config.CompilerConfiguration
          import org.jetbrains.kotlin.diagnostics.impl.BaseDiagnosticsCollector

          internal fun reportCollectedDiagnostics(
              compilerConfiguration: CompilerConfiguration,
              diagnosticsReporter: BaseDiagnosticsCollector,
              messageCollector: MessageCollector
          ) {
              val renderName = compilerConfiguration.getBoolean(CLIConfigurationKeys.RENDER_DIAGNOSTIC_INTERNAL_NAME)
              FirDiagnosticsCompilerResultsReporter.reportToMessageCollector(diagnosticsReporter, messageCollector, renderName)
          }
          KT
          # native serialization: no Fir2Ir lazy declarations
          f=compiler/ir/serialization.native/src/org/jetbrains/kotlin/backend/konan/serialization/KonanFakeOverrideClassFilter.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit 'return this\.isBound && this\.owner is Fir2IrLazyClass[^\n]*' 'return false' $f
          f=compiler/ir/serialization.native/src/org/jetbrains/kotlin/backend/konan/serialization/IrUtils.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit 'this\.isFromFirDeserializedInteropLibrary\(\) \|\| ' "" $f
          regex-edit '(?s)private fun DeclarationDescriptor\.isFromFirDeserializedInteropLibrary\(\).*?\n\}\n\n' "" $f
          grep -q 'not part of the bootstrap build' $d/jvm/K2JVMCompiler.kt $d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt compiler/cli/cli-js/src/org/jetbrains/kotlin/cli/js/K2JsIrCompiler.kt compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/CompilerRunnerUtils.kt
          ! grep -rq 'kotlin\.fir\.\(declarations\|lazy\|pipeline\|session\|backend\|analysis\|packageFqName\)\|IncrementalFirJvm\|\.pipeline\.\|FirMetadataSerializer\|FirKotlinToJvm' $d compiler/incremental-compilation-impl/src compiler/cli/cli-js/src compiler/ir/serialization.native/src
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "2.0.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "1.9.0" = step k."1.8.0" "1.9.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs dirs190))
        # more SDK 201 vs 213 differences, in Java sources
        (addLast "no-213-api-java" ''
          f=analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/classes/ClassInnerStuffCache.java
          regex-edit --optional --lines --all 'collectAugments\((myClass, \w+\.class), (?:null|name)\)' 'collectAugments(\1)' $f
          regex-edit --optional --lines 'Interner\.createWeakInterner\(\)' '(Interner) new com.intellij.util.containers.WeakInterner()' $f
          ! grep -q 'createWeakInterner' $f
          sed -i 's|NotNullLazyValue.atomicLazy(|com.intellij.openapi.util.AtomicNotNullLazyValue.createValue(|' compiler/frontend/src/org/jetbrains/kotlin/resolve/diagnostics/DiagnosticsElementsCache.java
          sed -i 's|NotNullLazyValue.lazy(|NotNullLazyValue.createValue(|' compiler/psi/src/org/jetbrains/kotlin/idea/KotlinFileType.java compiler/psi/src/org/jetbrains/kotlin/idea/KotlinModuleFileType.java
          f=compiler/cli/src/org/jetbrains/kotlin/cli/common/messages/PlainTextMessageRenderer.java
          sed -i '/import org.fusesource.jansi.internal.CLibrary;/d; s|CLibrary.isatty(CLibrary.STDERR_FILENO) != 0|System.console() != null|' $f
          ! grep -q CLibrary $f
        '')
        (addLast "unsafe-cast-opt-in" ''
          sed -i 's|-Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|& -Xopt-in=org.jetbrains.kotlin.utils.addToStdlib.UnsafeCastFunction|' build.xml
          grep -q 'UnsafeCastFunction' build.xml
        '')
        # SDK 201 instead of SDK 213, and no FIR/JS-FIR/wasm-immutable-collections
        (addLast "no-213-api" ''
          sed -i 's|\.map { it\.toFile() }||; s|getJdkClassesRoots(Paths.get(javaHome), true)|getJdkClassesRoots(File(javaHome), true)|; s|getJdkClassesRoots(jdkHome.toPath(), false)|getJdkClassesRoots(jdkHome, false)|; s|getJdkClassesRoots(javaRoot.toPath(), !isJdk)|getJdkClassesRoots(javaRoot, !isJdk)|' compiler/util/src/org/jetbrains/kotlin/utils/PathUtil.kt
          regex-edit '(ExtensionPoint\.Kind\.INTERFACE),\s*false' '\1' compiler/util/src/org/jetbrains/kotlin/extensions/ProjectExtensionDescriptor.kt compiler/util/src/org/jetbrains/kotlin/extensions/ApplicationExtensionDescriptor.kt
          rm compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/DummyJavaFileCodeStyleFacadeFactory.kt
          sed -i '/JavaFileCodeStyleFacade/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreApplicationEnvironment.kt
          sed -i '/hasConfiguredAnnotationRoot/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/MockExternalAnnotationsManager.kt
          f=compiler/ir/serialization.common/src/org/jetbrains/kotlin/backend/common/serialization/IrInterningService.kt
          sed -i '/import it.unimi.dsi.fastutil/d; s|ObjectOpenHashSet<String>()|HashMap<String, String>()|; s|ObjectOpenHashSet<Name>()|HashMap<Name, Name>()|; s|strings.addOrGet(string)|strings.getOrPut(string) { string }|; s|names.addOrGet(name)|names.getOrPut(name) { name }|' $f
          f=build-common/src/org/jetbrains/kotlin/incremental/storage/CachingLazyStorage.kt
          sed -i '/import com.intellij.util.io.AppendablePersistentMap/d; s|AppendablePersistentMap.ValueDataAppender|PersistentHashMap.ValueDataAppender|' $f
          f=wasm/wasm.ir/src/org/jetbrains/kotlin/wasm/ir/convertors/WasmIrToBinary.kt
          sed -i '/import kotlinx.collections.immutable/d; s|private var offsets = persistentListOf<Box>()|private var offsets: List<Box> = emptyList()|' $f
          rm -r compiler/ir/serialization.js/src/org/jetbrains/kotlin/fir
          f=compiler/cli/cli-js/src/org/jetbrains/kotlin/cli/js/K2JsIrCompiler.kt
          STUB='throw UnsupportedOperationException("FIR is not part of the bootstrap build")' regex-edit --subst-var STUB '(?s)val analyzedOutput = compileModuleToAnalyzedFir\(.*?(\n        return moduleStructure)' '@STUB@\1' $f
          grep -q 'not part of the bootstrap build' $f
        '')
        (addLast "builtins-was-experimental" ''
          cp libraries/stdlib/src/kotlin/annotations/WasExperimental.kt builtins-cherry/
        '')
        (ops.replace "no-203-api" ''
          f=analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/classes/KotlinClassInnerStuffCache.kt
          sed -i 's|PsiKeyword.SEALED|"sealed"|' $f
          ! grep -q PsiKeyword.SEALED $f
        '')
        (ops.replace "no-202-api" ''
          sed -i 's|classifierTypes(psi.permitsListTypes)|classifierTypes(emptyArray())|' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt
          sed -i 's|return owner.getPsi().hasModifierProperty(PsiModifier.SEALED);|return false;|' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaElementUtil.java
          grep -q 'classifierTypes(emptyArray())' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/JavaClassImpl.kt
        '')
        (ops.replace "no-fir" ''
          d=compiler/cli/src/org/jetbrains/kotlin/cli
          rm -r $d/common/fir $d/jvm/compiler/pipeline
          rm $d/common/FirSessionConstructionUtils.kt $d/metadata/FirMetadataSerializer.kt
          rm $d/jvm/compiler/FirKotlinToJvmBytecodeCompiler.kt $d/jvm/compiler/VfsBasedProjectEnvironment.kt
          rm compiler/cli/cli-js/src/org/jetbrains/kotlin/cli/js/klib/compilerPipeline.kt
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/IncrementalFirJvmCompilerRunner.kt
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/incrementalFirCacheUtils.kt
          stub='throw UnsupportedOperationException("FIR is not part of the bootstrap build")'
          f=$d/jvm/compiler/cliCompilerUtils.kt
          regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\.[^\n]*\n' "" $f
          regex-edit '(?s)\nfun createContextForIncrementalCompilation\(.*\Z' '\n' $f
          sed -i '/FirMetadataSerializer/d' $d/metadata/K2MetadataCompiler.kt
          f=$d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit '(?m)^import [^\n]*FirDiagnosticsCompilerResultsReporter\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)val projectEnvironment =\s*VfsBasedProjectEnvironment\(.*?buildFile, chunk\s*\)' '@STUB@' $f
          regex-edit '(?s)FirDiagnosticsCompilerResultsReporter\.reportToMessageCollector\(.*?\n        \)\n' "" $f
          sed -i '/FirExtensionRegistrarAdapter/d' compiler/cli/cli-base/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreEnvironment.kt
          f=$d/jvm/K2JVMCompiler.kt
          regex-edit --all '(?m)^import [^\n]*\.pipeline\.[^\n]*\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(configuration\.getBoolean\(CommonConfigurationKeys\.USE_FIR\) && configuration\.getBoolean\(CommonConfigurationKeys\.USE_LIGHT_TREE\)\)\s*\{.*?\n            \} else \{' 'if (false) {\n                @STUB@\n            } else {' $f
          f=compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/CompilerRunnerUtils.kt
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(useK2 && args\.useFirIC && args\.useFirLT[^\n]*\n\s*IncrementalFirJvmCompilerRunner\(.*?\n\s*\)\n(\s*)else' 'if (false) @STUB@\n\1else' $f
          grep -q 'not part of the bootstrap build' $d/jvm/K2JVMCompiler.kt $d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt $f
          ! grep -rq 'kotlin\.fir\.\|cli\.common\.fir\|IncrementalFirJvm\|\.pipeline\.\|FirMetadataSerializer' $d compiler/incremental-compilation-impl/src compiler/cli/cli-base/src
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.9.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
        (addLast "language-1.9" ''
          sed -i 's|-language-version 1.8 -api-version 1.8|-language-version 1.9 -api-version 1.9|' build.xml
          grep -q 'api-version 1.9' build.xml
        '')
        # core has Java default methods (ValidateableDescriptor)
        (addLast "javac-8" ''
          sed -i 's|source="1.6" target="1.6"|source="1.8" target="1.8"|' build.xml
          ! grep -q 'source="1.6"' build.xml
        '')
        # the stdlib's platform implementations moved into the jdk7/jdk8 source sets
        (addLast "stdlib-jdk78" ''
          regex-edit '(?s)(<target name="builtins">.*?<include name="libraries/stdlib/jvm/src"/>\n)' '\1                <include name="libraries/stdlib/jdk7/src"/>\n                <include name="libraries/stdlib/jdk8/src"/>\n' build.xml
          grep -q 'stdlib/jdk8/src' build.xml
        '')
      ];
    };

    "1.8.0" = step k."1.7.0" "1.8.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs dirs180))
        (ops.delete "fresh-stdlib")
        (addLast "context-receivers-core" ''
          regex-edit --lines '(<new-kotlinc output="[^"]*" moduleName="[^"]*")>' '\1 additionalOptions="-Xcontext-receivers -Xjvm-default=all">' build.xml
          grep -q 'moduleName="kotlin-core" additionalOptions="-Xcontext-receivers' build.xml
        '')
        # IntRange etc. moved from the builtins to the stdlib sources
        (addLast "builtins-from-sources" ''
          sed -i 's|additionalOptions="-Xmulti-platform|additionalOptions="-Xbuiltins-from-sources -Xmulti-platform|' build.xml
          grep -q 'Xbuiltins-from-sources' build.xml
        '')
        # SDK 203 API / -Xjvm-default=all applied to every module (upstream skips some)
        (addLast "no-203-api-3" ''
          sed -i 's|AnnotationDescriptor.DefaultImpls.getFqName(this)|AnnotationDescriptor.super.getFqName()|' core/descriptors/src/org/jetbrains/kotlin/descriptors/annotations/AnnotationDescriptorImpl.java
          sed -i 's|"kotlin." + getDebugName()|"kotlin." + super.toString()|' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtStubElementType.java
          regex-edit '    @Override\n(    boolean isWhitespaceOrComment)' '\1' compiler/psi/src/org/jetbrains/kotlin/parsing/SemanticWhitespaceAwarePsiBuilder.java
          grep -q 'super.toString' compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements/KtStubElementType.java
          ! grep -B1 'boolean isWhitespaceOrComment' compiler/psi/src/org/jetbrains/kotlin/parsing/SemanticWhitespaceAwarePsiBuilder.java | grep -q Override
        '')
        # javac target 1.6 cannot emit the interface invokespecial of AnnotationDescriptor.super.getFqName()
        (addLast "annotation-fqname" ''
          f=core/descriptors/src/org/jetbrains/kotlin/descriptors/annotations/AnnotationDescriptorImpl.java
          regex-edit --lines 'AnnotationDescriptor\.super\.getFqName\(\)' 'fqNameDefault(this)' $f
          regex-edit '    @Nullable\n    @Override\n(    public FqName getFqName\(\) \{)' '    private static FqName fqNameDefault(AnnotationDescriptor d) {\n        org.jetbrains.kotlin.descriptors.ClassDescriptor c = org.jetbrains.kotlin.resolve.descriptorUtil.DescriptorUtilsKt.getAnnotationClass(d);\n        if (c == null || org.jetbrains.kotlin.types.error.ErrorUtils.isError(c)) return null;\n        return org.jetbrains.kotlin.resolve.descriptorUtil.DescriptorUtilsKt.fqNameOrNull(c);\n    }\n\n    @Nullable\n\1' $f
          grep -q 'static FqName fqNameDefault' $f
          ! grep -B1 'public FqName getFqName' $f | grep -q Override
        '')
        (ops.delete "interpreter-dup-utils")
        (addLast "flags-1.8" ''
          sed -i 's|-Xjvm-default=enable|-Xjvm-default=all|; s|-language-version 1.7 -api-version 1.7|& -Xcontext-receivers -Xopt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi|' build.xml
          grep -q 'Xcontext-receivers' build.xml
        '')
        (addLast "no-203-api-2" ''
          f=compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/classpathDiff/ClasspathSnapshotSerializer.kt
          sed -i 's|Interner.createWeakInterner<|com.intellij.util.containers.WeakInterner<|' $f
          ! grep -q createWeakInterner $f
        '')
        # the primitive iterators moved from the builtins to the stdlib sources
        (addLast "builtins-primitive-iterators" ''
          cp libraries/stdlib/src/kotlin/collections/PrimitiveIterators.kt builtins-cherry/
          cp libraries/stdlib/src/kotlin/annotations/ExperimentalStdlibApi.kt builtins-cherry/
          cp libraries/stdlib/src/kotlin/annotations/OptIn.kt builtins-cherry/
          for f in libraries/stdlib/src/kotlin/ranges/*.kt; do
            [ "$(basename $f)" = Ranges.kt ] || cp $f builtins-cherry/
          done
        '')
        (ops.replace "no-203-api" ''
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/incrementalFirCacheUtils.kt
          f=analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/classes/KotlinClassInnerStuffCache.kt
          sed -i 's|PsiKeyword.SEALED|"sealed"|' $f
          ! grep -q PsiKeyword.SEALED $f
        '')
        (ops.replace "no-202-api-2" ''
          sed -i 's|PsiAugmentProvider.collectAugments(element, type, null)|PsiAugmentProvider.collectAugments(element, type)|' analysis/light-classes-base/src/org/jetbrains/kotlin/asJava/classes/lightClassPlatformUtils.kt
          sed -i 's|Interner.createStringInterner()|com.intellij.util.containers.StringInterner()|; s|MultiMap.createConcurrent<K, V>()|MultiMap.createConcurrentSet<K, V>()|' compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
          grep -q StringInterner compiler/util/src/org/jetbrains/kotlin/utils/platformUtils.kt
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.8.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
        (addLast "language-1.8" ''
          sed -i 's|-language-version 1.7 -api-version 1.7|-language-version 1.8 -api-version 1.8|' build.xml
          grep -q 'api-version 1.8' build.xml
        '')
      ];
    };

    "1.7.0" = step k."1.6.21" "1.7.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.replace "compiler-dirs" (compilerDirs dirs170))
        # -Xuse-experimental is gone in 1.7
        (addLast "opt-in-flag" ''
          sed -i 's|-Xuse-experimental=|-Xopt-in=|g' build.xml
          ! grep -q 'Xuse-experimental' build.xml
        '')
        (addLast "jsr305" ''
          ln -sf ${jar java.jsr305} ideaSDK/core/jsr305.jar
        '')
        (addLast "no-203-api" ''
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/incrementalFirCacheUtils.kt
          f=compiler/light-classes/src/org/jetbrains/kotlin/asJava/classes/KotlinClassInnerStuffCache.kt
          sed -i 's|PsiKeyword.SEALED|"sealed"|' $f
          ! grep -q PsiKeyword.SEALED $f
        '')
        (ops.replace "no-fir" ''
          d=compiler/cli/src/org/jetbrains/kotlin/cli
          rm -r $d/common/fir $d/jvm/compiler/pipeline
          rm $d/jvm/compiler/FirKotlinToJvmBytecodeCompiler.kt $d/jvm/compiler/VfsBasedProjectEnvironment.kt
          rm compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/IncrementalFirJvmCompilerRunner.kt
          stub='throw UnsupportedOperationException("FIR is not part of the bootstrap build")'
          f=$d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit '(?m)^import [^\n]*FirDiagnosticsCompilerResultsReporter\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)val projectEnvironment =\s*VfsBasedProjectEnvironment\(.*?buildFile, chunk, extendedAnalysisMode\s*\)' '@STUB@' $f
          regex-edit '(?s)FirDiagnosticsCompilerResultsReporter\.reportToMessageCollector\(.*?\n        \)\n' "" $f
          f=$d/jvm/compiler/KotlinCoreEnvironment.kt
          sed -i '/FirExtensionRegistrarAdapter/d' $f
          f=$d/jvm/K2JVMCompiler.kt
          regex-edit --all '(?m)^import [^\n]*\.pipeline\.[^\n]*\n' "" $f
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(configuration\.getBoolean\(CommonConfigurationKeys\.USE_FIR\) && arguments\.useFirLT.*?\n            \} else \{' 'if (false) {\n                @STUB@\n            } else {' $f
          f=compiler/incremental-compilation-impl/src/org/jetbrains/kotlin/incremental/IncrementalJvmCompilerRunner.kt
          STUB="$stub" regex-edit --subst-var STUB '(?s)if \(args\.useK2 && args\.useFirIC && args\.useFirLT[^\n]*\n\s*IncrementalFirJvmCompilerRunner\(.*?\n\s*\)\n(\s*)else' 'if (false) @STUB@\n\1else' $f
          grep -q 'not part of the bootstrap build' $d/jvm/K2JVMCompiler.kt $d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt $f
          ! grep -rq 'kotlin\.fir\.\|cli\.common\.fir\|IncrementalFirJvm\|\.pipeline\.' $d compiler/incremental-compilation-impl/src
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.7.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
        (addLast "language-1.7" ''
          sed -i 's|-language-version 1.6 -api-version 1.6|-language-version 1.7 -api-version 1.7|' build.xml
          grep -q 'api-version 1.7' build.xml
        '')
      ];
    };

    "1.6.21" = step k."1.6.0" "1.6.21" [ ] {
      steps = lib.flip lib.pipe [
        (ops.delete "minby-or-null")
        (addLast "language-1.6" ''
          sed -i 's|-language-version 1.5 -api-version 1.5|-language-version 1.6 -api-version 1.6|' build.xml
          grep -q 'api-version 1.6' build.xml
        '')
        (addLast "gson" ''
          ln -sf ${jar java.gson} ideaSDK/core/gson.jar
        '')
        # ASM 8 / SDK 201 instead of ASM 9 / SDK 203
        (addLast "no-asm9-api-2" ''
          sed -i 's|Opcodes\.V16|60|g' compiler/config.jvm/src/org/jetbrains/kotlin/config/JvmTarget.kt
          sed -i 's|classVisitor.visitPermittedSubclass(|classVisitor.visitPermittedSubtypeExperimental(|' compiler/ir/backend.jvm/codegen/src/org/jetbrains/kotlin/backend/jvm/codegen/ClassCodegen.kt
          f=build-common/src/org/jetbrains/kotlin/incremental/IncrementalJvmCache.kt
          sed -i '/^import com.intellij.util.containers.CollectionFactory$/d; s|THashSet(CollectionFactory.createFilePathSet())|THashSet<String>()|' $f
          ! grep -q CollectionFactory $f
        '')
        (addLast "no-fir-reporter" ''
          f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          sed -i '/FirDiagnosticsCompilerResultsReporter/d' $f
          ! grep -q FirDiagnosticsCompilerResultsReporter $f
        '')
        (ops.replace "compiler-dirs" (compilerDirs dirs1621))
        (ops.replace "compiler-version-150" ''
          echo -n "1.6.21" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "1.6.0" = step k."1.5.31" "1.6.0" [ ] {
      steps = lib.flip lib.pipe [
        (ops.delete "explicit-ir-function-type")
        (addLast "compiler-xml-cli-common" ''
          sed -i 's|<fileset dir="idea/resources">|<fileset dir="compiler/cli/cli-common/resources">|' build.xml
          grep -q 'dir="compiler/cli/cli-common/resources">' build.xml
        '')
        # IStubElementType.createStub takes a raw StubElement in SDK 201 (StubElement<?> in 203)
        (addLast "raw-stub-element" ''
          d=compiler/psi/src/org/jetbrains/kotlin/psi/stubs/elements
          sed -i 's|createStub(@NotNull T psi, StubElement<?> parentStub)|createStub(@NotNull T psi, StubElement parentStub)|' $d/KtModifierListElementType.java $d/KtPlaceHolderStubElementType.java
          grep -q 'T psi, StubElement parentStub' $d/KtPlaceHolderStubElementType.java
        '')
        # the ir.interpreter.* and ir.util.* star imports of Wrapper.kt clash: prefer the interpreter's own helpers explicitly
        (ops.replace "interpreter-dup-utils" ''
          f=compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/state/Wrapper.kt
          sed -i '0,/^import org.jetbrains.kotlin.ir.interpreter.\*/s||import org.jetbrains.kotlin.ir.interpreter.*\nimport org.jetbrains.kotlin.ir.interpreter.isThrowable\nimport org.jetbrains.kotlin.ir.interpreter.isKFunction\nimport org.jetbrains.kotlin.ir.interpreter.isFunction\nimport org.jetbrains.kotlin.ir.interpreter.isTypeParameter|' $f
          grep -q 'interpreter.isThrowable' $f
        '')
        (ops.replace "compiler-dirs" (compilerDirs dirs160))
        (ops.replace "no-fir" ''
          d=compiler/cli/src/org/jetbrains/kotlin/cli
          rm $d/jvm/compiler/FirKotlinToJvmBytecodeCompiler.kt $d/jvm/compiler/PsiBasedProjectEnvironment.kt
          rm -r $d/common/fir
          f=$d/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit '(?s)val projectEnvironment =\s*PsiBasedProjectEnvironment\(.*?buildFile, chunk, extendedAnalysisMode\s*\)' 'throw UnsupportedOperationException("FIR is not part of the bootstrap build")' $f
          grep -q 'not part of the bootstrap build' $f
          ! grep -rq 'kotlin\.fir\.' $d
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.6.0" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };

    "1.5.31" = step k."1.5.0" "1.5.31" [ ] {
      steps = lib.flip lib.pipe [
        (ops.delete "no-mod-floordiv")
        (addLast "no-asm9-api" ''
          sed -i 's|override fun visitPermittedSubclass(|override fun visitPermittedSubtypeExperimental(|' compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryJavaClass.kt
          grep -q visitPermittedSubtypeExperimental compiler/resolution.common.jvm/src/org/jetbrains/kotlin/load/java/structure/impl/classFiles/BinaryJavaClass.kt
        '')
        # these resolve ambiguously against the identical public ones in ir.util (star-imported next to ir.interpreter.*)
        (addLast "interpreter-dup-utils" ''
          sed -i '/^internal fun IrType\.\(isUnsigned\|isFunction\|isKFunction\|isTypeParameter\|isThrowable\)() = /d' compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/Utils.kt
          ! grep -q 'fun IrType.isThrowable' compiler/ir/ir.interpreter/src/org/jetbrains/kotlin/ir/interpreter/Utils.kt
        '')
        (ops.replace "compiler-dirs" (compilerDirs dirs1531))
        # the FIR entry point moved to its own file
        (ops.replace "no-fir" ''
          rm compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/FirKotlinToJvmBytecodeCompiler.kt
          rm -r compiler/cli/src/org/jetbrains/kotlin/cli/common/fir
          f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
          regex-edit 'return FirKotlinToJvmBytecodeCompiler\.compileModulesUsingFrontendIR\([^\n]*\)' 'throw UnsupportedOperationException("FIR is not part of the bootstrap build")' $f
          grep -q 'not part of the bootstrap build' $f
          ! grep -rq 'kotlin\.fir\.' compiler/cli/src
        '')
        (ops.replace "compiler-version-150" ''
          echo -n "1.5.31" > compiler/compiler.version/resources/META-INF/compiler.version
        '')
      ];
    };
  });

  # Version independent replacements for the per-version patches of TarCV
  # (for Kotlin >= 1.1.4).
  scriptedEdits = ''
    export JDK_16=$JAVA_HOME JDK_17=$JAVA_HOME JDK_18=$JAVA_HOME
    # Jars packed into kotlin-compiler.jar: provide them under the names
    # build.xml uses.
    for n in $(grep -oE 'ideaSDK/core/[^"/]+\.jar' build.xml | sed 's|ideaSDK/core/||' | sort -u); do
      [ -e ideaSDK/core/$n ] && continue
      case $n in
        annotations*) t=$(ls ideaSDK/core/intellij-annotations.jar) ;;
        asm-all*|asm-[0-9]*) t=$(ls ideaSDK/core/asm-6.0.jar ideaSDK/core/asm-org-jetbrains-org-objectweb-asm.jar 2>/dev/null | head -1) ;;
        guava*) t=ideaSDK/core/guava.jar ;;
        jdom*) t=ideaSDK/core/jdom.jar ;;
        log4j*) t=ideaSDK/core/log4j.jar ;;
        snappy*) t=ideaSDK/core/iq80-snappy.jar ;;
        trove4j*) t=ideaSDK/core/jetbrains-trove4j.jar ;;
        xpp3*) t=ideaSDK/core/xpp3.jar ;;
        xstream*) t=ideaSDK/core/xstream.jar ;;
        streamex*) t=${jar kotlinLibs.streamex} ;;
        *) echo "scripted-edits: do not know which jar provides ideaSDK/core/$n"; exit 1 ;;
      esac
      [ -e "$t" ] || { echo "scripted-edits: $t missing (for $n)"; exit 1; }
      ln -s "$(readlink -f $t)" ideaSDK/core/$n
    done
    # jansi is used by the compiler (TarCV adds it to the compiler jar)
    grep -q 'dependencies}/jansi.jar' build.xml || \
      sed -i 's|\( *\)<zipfileset src="''${dependencies}/jline.jar"/>|\1<zipfileset src="''${dependencies}/jansi.jar"/>\n&|' build.xml
    # dist: no extra artifacts, and no forked Ant (it would not see CLASSPATH)
    sed -i '/<target name="dist"/,/description/ { s/,other-artifacts//; s/,compiler-fork,/,compiler,/ }' build.xml
    # IntelliJ 172 API (Kotlin 1.1.x was built against 171)
    f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/MockExternalAnnotationsManager.kt
    if [ -f $f ] && ! grep -q hasAnnotationRootsForFile $f; then
      sed -i 's|^\( *\)override fun annotateExternally|\1override fun hasAnnotationRootsForFile(p0: com.intellij.openapi.vfs.VirtualFile): Boolean = false\n&|' $f
    fi
    # Coloured output needs jansi's native library; always enable it.
    f=compiler/cli/src/org/jetbrains/kotlin/cli/common/messages/PlainTextMessageRenderer.java
    regex-edit --optional '(?s)public static final boolean COLOR_ENABLED;\s*static \{.*?COLOR_ENABLED = colorEnabled;\s*\}' 'public static final boolean COLOR_ENABLED = true;' $f
    regex-edit --optional 'import org\.fusesource\.jansi\.internal\.CLibrary;\n' "" $f
  '';

  # Compile a runtime library of the version being built with the bootstrap
  # compiler and use it instead of the bootstrap's, for when the new compiler
  # needs new runtime API (upstream bootstraps from a dev build of the same
  # version instead).
  freshRuntime = name: dirs: ''
    mkdir -p dependencies/fresh-${name}
    $JAVA_HOME/bin/java -Xmx2g -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
      -no-stdlib -cp "$BOOTSTRAP/lib/kotlin-stdlib.jar" -Xallow-kotlin-package -module-name kotlin-${name} \
      -d dependencies/fresh-${name} ${lib.concatStringsSep " " dirs}
    find ${lib.concatStringsSep " " dirs} -name '*.java' > fresh-${name}.txt
    if [ -s fresh-${name}.txt ]; then
      $JAVA_HOME/bin/javac -nowarn -d dependencies/fresh-${name} \
        -cp "dependencies/fresh-${name}:$BOOTSTRAP/lib/kotlin-stdlib.jar" @fresh-${name}.txt
    fi
    (cd dependencies/fresh-${name} && $JAVA_HOME/bin/jar cf ../kotlin-${name}-fresh.jar .)
    antFlagsExtra+=" -Dbootstrap.${
      lib.replaceStrings [ "-" ] [ "." ] name
    }=$PWD/dependencies/kotlin-${name}-fresh.jar"
  '';

  # Stdlib of the version being built, compiled by the bootstrap compiler, to
  # be the runtime that the new compiler is compiled against (1.2.50+ uses
  # stdlib contracts, which only the stdlib of the same version declares).
  # Extra compiler options for the stdlib (runtime fragment and fresh stdlib).
  stdlibFlags =
    flags:
    lib.flip lib.pipe [
      (ops.replace "ant-runtime" (antRuntime {
        fragment = ../../patches/own/runtime-targets-1.2.50.xml;
        stdlibOptions = flags;
      }))
      (ops.replace "fresh-stdlib" (
        lib.replaceStrings [ "-Xmulti-platform" ] [ "-Xmulti-platform ${flags}" ] freshStdlib
      ))
    ];

  freshStdlib = ''
    mkdir -p dependencies/fresh-stdlib dependencies/prev-builtins
    # Only the builtins metadata of the bootstrap runtime: the sources
    # define everything else.
    unzip -q "$BOOTSTRAP/lib/kotlin-stdlib.jar" 'kotlin/*.kotlin_builtins' -d dependencies/prev-builtins
    $JAVA_HOME/bin/java -Xmx3g -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
      -no-stdlib -cp dependencies/prev-builtins -Xallow-kotlin-package -Xmultifile-parts-inherit -Xmulti-platform \
      -Xnormalize-constructor-calls=enable -module-name kotlin-stdlib \
      -d dependencies/fresh-stdlib core/builtins/src libraries/stdlib/jvm/runtime libraries/stdlib/jvm/src \
      libraries/stdlib/common/src libraries/stdlib/src core/runtime.jvm/src
    find core/builtins/src libraries/stdlib/jvm/runtime libraries/stdlib/jvm/src core/runtime.jvm/src -name '*.java' > fresh-stdlib.txt
    $JAVA_HOME/bin/javac -nowarn -d dependencies/fresh-stdlib \
      -cp dependencies/fresh-stdlib @fresh-stdlib.txt
    cp -r dependencies/prev-builtins/kotlin/. dependencies/fresh-stdlib/kotlin/
    (cd dependencies/fresh-stdlib && $JAVA_HOME/bin/jar cf ../kotlin-stdlib-fresh.jar .)
    antFlagsExtra+=" -Dbootstrap.runtime=$PWD/dependencies/kotlin-stdlib-fresh.jar"
  '';

  # Replace the compiler source dirs of the restored build.xml (and the
  # service descriptors packed into the compiler jar) by `dirs`, the
  # `compilerModules` of the version's Gradle build (tools/kotlin-modules).
  compilerDirs =
    dirs:
    let
      list = lib.concatMapStrings (d: "${d}\n") dirs;
    in
    ''
      cat > compiler-dirs.txt <<'EOF'
      ${list}EOF
      for d in $(cat compiler-dirs.txt); do [ -d $d ] || { echo "compiler-dirs: $d missing"; exit 1; }; done
      python3 - compiler-dirs.txt build.xml <<'PY'
      import re, sys
      dirs = open(sys.argv[1]).read().split()
      s = open(sys.argv[2], encoding="latin-1").read()
      # the compiler's source dirs
      m = re.search(r'(<dirset id="compilerSources.dirset" dir="\$\{basedir\}/">).*?(</dirset>)', s, re.S)
      includes = "".join('\n        <include name="%s"/>' % d for d in dirs)
      s = s[: m.start()] + m.group(1) + includes + "\n    " + m.group(2) + s[m.end() :]
      # their service descriptors, in src/ or (resources moved, 1.3.20) resources/
      res = [x for d in dirs for x in (d, re.sub(r"/[^/]+$", "/resources", d))]
      m = re.search(r'(\s*<fileset dir="\$\{basedir\}/[^"]+" includes="META-INF/services/\*\*"/>)+', s)
      filesets = "".join(
          '\n                <fileset dir="''${basedir}/%s" includes="META-INF/services/**" erroronmissingdir="false"/>' % r
          for r in res
      )
      s = s[: m.start()] + filesets + s[m.end() :]
      open(sys.argv[2], "w", encoding="latin-1").write(s)
      PY
    '';

  # Kotlin 1.3.0's stdlib compiled with 1.2.71, which has the 1.3 language
  # features as unstable ones and whose release coroutines codegen still
  # targets kotlin.SuccessOrFailure (renamed to Result in 1.3-RC): only used to
  # compile the compiler against (which then does not use coroutines).
  freshStdlib13 =
    let
      common = [
        "libraries/stdlib/common/src"
        "libraries/stdlib/src"
        "libraries/stdlib/unsigned/src"
        "libraries/stdlib/coroutines/common/src"
        "libraries/stdlib/coroutines/src"
      ];
      jvm = [
        "core/builtins/src"
        "libraries/stdlib/jvm/runtime"
        "libraries/stdlib/jvm/src"
        "libraries/stdlib/coroutines/jvm/src"
        "core/runtime.jvm/src"
      ];
      kotlinc = ''$JAVA_HOME/bin/java -Xmx3g -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -Xallow-kotlin-package -Xmultifile-parts-inherit -Xmulti-platform -language-version 1.3 -api-version 1.3 -Xuse-experimental=kotlin.Experimental'';
    in
    ''
      cp -r libraries/stdlib fresh-stdlib-src
      rm fresh-stdlib-src/coroutines/src/kotlin/SuccessOrFailure.kt
      grep -rlw Result fresh-stdlib-src/coroutines fresh-stdlib-src/coroutines-experimental | xargs regex-edit --lines --all '\bResult\b' 'SuccessOrFailure'
      # 1.2.71 rejects `where C : Array<*>, C : R`
      grep -rl 'UPPER_BOUND_CANNOT_BE_ARRAY")' fresh-stdlib-src | xargs sed -i 's/@Suppress("UPPER_BOUND_CANNOT_BE_ARRAY")/@Suppress("UPPER_BOUND_CANNOT_BE_ARRAY", "BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER")/'
      grep -rlE 'where \w+ : .*, \w+ : R =' fresh-stdlib-src/src | xargs regex-edit --all '(?m)(?<!BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER"\)\n)^(public inline fun [^\n]* where \w+ : [^\n]*, \w+ : R =)$' '@Suppress("BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER")\n\1'
      # 1.2.71 crashes generating defaults (referring to the receiver) of expect functions
      sed -i -E '/expect fun .*\.copyInto\(/ s/ = (0|size)([,)])/\2/g' fresh-stdlib-src/common/src/generated/_Arrays.kt
      mkdir -p dependencies/fresh-stdlib dependencies/prev-builtins
      unzip -q "$BOOTSTRAP/lib/kotlin-stdlib.jar" 'kotlin/*.kotlin_builtins' -d dependencies/prev-builtins
      ${kotlinc} -cp dependencies/prev-builtins -Xnormalize-constructor-calls=enable -module-name kotlin-stdlib \
        -Xuse-experimental=kotlin.ExperimentalMultiplatform -Xuse-experimental=kotlin.ExperimentalUnsignedTypes \
        -Xuse-experimental=kotlin.contracts.ExperimentalContracts -XXLanguage:+InlineClasses -XXLanguage:+ReleaseCoroutines \
        -Xcommon-sources=${lib.concatMapStringsSep "," fresh common} \
        -d dependencies/fresh-stdlib ${lib.concatMapStringsSep " " fresh (jvm ++ common)}
      ${kotlinc} -cp dependencies/fresh-stdlib:dependencies/prev-builtins -Xskip-metadata-version-check -XXLanguage:-ReleaseCoroutines \
        -module-name kotlin-stdlib-coroutines -Xcommon-sources=fresh-stdlib-src/coroutines-experimental/src \
        -d dependencies/fresh-stdlib fresh-stdlib-src/coroutines-experimental/jvm/src fresh-stdlib-src/coroutines-experimental/src
      find ${
        lib.concatMapStringsSep " " fresh jvm
      } fresh-stdlib-src/coroutines-experimental/jvm/src -name '*.java' > fresh-stdlib.txt
      $JAVA_HOME/bin/javac -nowarn -d dependencies/fresh-stdlib -cp dependencies/fresh-stdlib @fresh-stdlib.txt
      cp -r dependencies/prev-builtins/kotlin/. dependencies/fresh-stdlib/kotlin/
      # 1.2.71 ignores @get:JvmName on annotation parameters (Metadata.k etc.)
      unzip -qo "$BOOTSTRAP/lib/kotlin-stdlib.jar" 'kotlin/Metadata*.class' -d dependencies/fresh-stdlib
      (cd dependencies/fresh-stdlib && $JAVA_HOME/bin/jar cf ../kotlin-stdlib-fresh.jar .)
      rm -r fresh-stdlib-src
      antFlagsExtra+=" -Dbootstrap.runtime=$PWD/dependencies/kotlin-stdlib-fresh.jar"
    '';
  fresh =
    d:
    if lib.hasPrefix "libraries/stdlib/" d then
      "fresh-stdlib-src/" + lib.removePrefix "libraries/stdlib/" d
    else
      d;

  # Kotlin 1.4's stdlib compiled by 1.3.72 (language version 1.4), to compile
  # the compiler against: it uses stdlib API that is new in 1.4.
  freshStdlib14 = ''
    mkdir -p dependencies/fresh-stdlib dependencies/prev-builtins
    unzip -q "$BOOTSTRAP/lib/kotlin-stdlib.jar" 'kotlin/*.kotlin_builtins' -d dependencies/prev-builtins
    $JAVA_HOME/bin/java -Xmx3g -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
      -no-stdlib -cp dependencies/prev-builtins -Xallow-kotlin-package -Xallow-result-return-type -Xmultifile-parts-inherit -Xmulti-platform \
      -language-version 1.4 -api-version 1.4 -Xnormalize-constructor-calls=enable -module-name kotlin-stdlib \
      -Xopt-in=kotlin.RequiresOptIn -Xopt-in=kotlin.ExperimentalMultiplatform -Xopt-in=kotlin.ExperimentalUnsignedTypes \
      -Xopt-in=kotlin.contracts.ExperimentalContracts -XXLanguage:+InlineClasses \
      -Xcommon-sources=libraries/stdlib/common/src,libraries/stdlib/src,libraries/stdlib/unsigned/src \
      -d dependencies/fresh-stdlib core/builtins/src libraries/stdlib/jvm/runtime libraries/stdlib/jvm/src \
      libraries/stdlib/common/src libraries/stdlib/src libraries/stdlib/unsigned/src
    find core/builtins/src libraries/stdlib/jvm/runtime libraries/stdlib/jvm/src -name '*.java' > fresh-stdlib.txt
    $JAVA_HOME/bin/javac -nowarn -d dependencies/fresh-stdlib -cp dependencies/fresh-stdlib @fresh-stdlib.txt
    # builtins metadata of the new sources (e.g. DeprecatedSinceKotlin)
    $JAVA_HOME/bin/java -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.serialization.builtins.RunKt \
      dependencies/new-builtins core/builtins/native core/builtins/src builtins-cherry
    cp -r dependencies/new-builtins/kotlin/. dependencies/fresh-stdlib/kotlin/
    (cd dependencies/fresh-stdlib && $JAVA_HOME/bin/jar cf ../kotlin-stdlib-fresh.jar .)
    antFlagsExtra+=" -Dbootstrap.runtime=$PWD/dependencies/kotlin-stdlib-fresh.jar"
  '';

  # FIR (experimental front end) needs fun interfaces and kotlinx.collections.immutable: leave it out
  noFir = ''
    f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
    regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\..*\n' "" $f
    regex-edit '(?s)(    private fun compileModulesUsingFrontendIR\([^\n]*\): Boolean) \{.*?\n(?=    private fun getBuildFilePaths)' '\1 =\n        throw UnsupportedOperationException("FIR is not part of the bootstrap build")\n\n' $f
    grep -q 'not part of the bootstrap build' $f
    ! grep -q 'kotlin\.fir\.' $f
    sed -i '/org\.jetbrains\.kotlin\.fir\./d' compiler/cli/resources/META-INF/services/org.jetbrains.kotlin.diagnostics.rendering.DefaultErrorMessages\$Extension
  '';

  # compilerModules of Kotlin 1.4-M2 .. 1.4.0 without FIR
  dirs14 = [
    "build-common/src"
    "compiler/backend-common/src"
    "compiler/backend/src"
    "compiler/builtins-serializer/src"
    "compiler/cli/cli-common/src"
    "compiler/cli/cli-js/src"
    "compiler/cli/src"
    "compiler/compiler.version/src"
    "compiler/config.jvm/src"
    "compiler/config/src"
    "compiler/container/src"
    "compiler/frontend.common/src"
    "compiler/frontend.java/src"
    "compiler/frontend/src"
    "compiler/incremental-compilation-impl/src"
    "compiler/ir/backend.common/src"
    "compiler/ir/backend.js/src"
    "compiler/ir/backend.jvm/src"
    "compiler/ir/backend.wasm/src"
    "compiler/ir/ir.psi2ir/src"
    "compiler/ir/ir.tree/src"
    "compiler/ir/serialization.common/src"
    "compiler/ir/serialization.js/src"
    "compiler/ir/serialization.jvm/src"
    "compiler/javac-wrapper/src"
    "compiler/light-classes/src"
    "compiler/plugin-api/src"
    "compiler/psi/src"
    "compiler/resolution/src"
    "compiler/serialization/src"
    "compiler/util-io/src"
    "compiler/util-klib-metadata/src"
    "compiler/util-klib/src"
    "compiler/util/src"
    "core/descriptors.jvm/src"
    "core/descriptors.runtime/src"
    "core/descriptors/src"
    "core/deserialization/src"
    "core/metadata.jvm/src"
    "core/metadata/src"
    "core/type-system/src"
    "core/util.runtime/src"
    "js/js.ast/src"
    "js/js.config/src"
    "js/js.dce/src"
    "js/js.frontend/src"
    "js/js.inliner/src"
    "js/js.parser/src"
    "js/js.serializer/src"
    "js/js.translator/src"
    "native/frontend/src"
    "native/utils/src"
  ];

  # The bootstrap's stdlib with the builtins metadata of the new sources
  # (new builtin declarations such as DeprecatedSinceKotlin), for when the
  # bootstrap compiler cannot compile the new stdlib itself.
  freshBuiltins = ''
    mkdir -p dependencies
    cp "$BOOTSTRAP/lib/kotlin-stdlib.jar" dependencies/kotlin-stdlib-fresh.jar
    chmod u+w dependencies/kotlin-stdlib-fresh.jar
    $JAVA_HOME/bin/java -cp "$BOOTSTRAP/lib/kotlin-compiler.jar" org.jetbrains.kotlin.serialization.builtins.RunKt \
      dependencies/new-builtins core/builtins/native core/builtins/src builtins-cherry
    $JAVA_HOME/bin/jar uf dependencies/kotlin-stdlib-fresh.jar -C dependencies/new-builtins kotlin
    antFlagsExtra+=" -Dbootstrap.runtime=$PWD/dependencies/kotlin-stdlib-fresh.jar"
  '';

  # compilerModules of Kotlin 1.4.21 without FIR
  dirs1421 = [
    "build-common/src"
    "compiler/backend-common/src"
    "compiler/backend/src"
    "compiler/builtins-serializer/src"
    "compiler/cli/cli-common/src"
    "compiler/cli/cli-js/src"
    "compiler/cli/src"
    "compiler/compiler.version/src"
    "compiler/config.jvm/src"
    "compiler/config/src"
    "compiler/container/src"
    "compiler/frontend.common/src"
    "compiler/frontend.java/src"
    "compiler/frontend/src"
    "compiler/incremental-compilation-impl/src"
    "compiler/ir/backend.common/src"
    "compiler/ir/backend.js/src"
    "compiler/ir/backend.jvm/src"
    "compiler/ir/backend.wasm/src"
    "compiler/ir/ir.interpreter/src"
    "compiler/ir/ir.psi2ir/src"
    "compiler/ir/ir.tree.impl/src"
    "compiler/ir/ir.tree.persistent/src"
    "compiler/ir/ir.tree/src"
    "compiler/ir/serialization.common/src"
    "compiler/ir/serialization.js/src"
    "compiler/ir/serialization.jvm/src"
    "compiler/javac-wrapper/src"
    "compiler/light-classes/src"
    "compiler/plugin-api/src"
    "compiler/psi/src"
    "compiler/resolution.common.jvm/src"
    "compiler/resolution.common/src"
    "compiler/resolution/src"
    "compiler/serialization/src"
    "compiler/util-io/src"
    "compiler/util-klib-metadata/src"
    "compiler/util-klib/src"
    "compiler/util/src"
    "core/compiler.common.jvm/src"
    "core/compiler.common/src"
    "core/descriptors.jvm/src"
    "core/descriptors.runtime/src"
    "core/descriptors/src"
    "core/deserialization/src"
    "core/metadata.jvm/src"
    "core/metadata/src"
    "core/util.runtime/src"
    "js/js.ast/src"
    "js/js.config/src"
    "js/js.dce/src"
    "js/js.frontend/src"
    "js/js.inliner/src"
    "js/js.parser/src"
    "js/js.serializer/src"
    "js/js.translator/src"
    "native/frontend/src"
    "native/utils/src"
  ];

  noFir2 = ''
    f=compiler/cli/src/org/jetbrains/kotlin/cli/jvm/compiler/KotlinToJVMBytecodeCompiler.kt
    regex-edit --all '(?m)^import org\.jetbrains\.kotlin\.fir\..*\n' "" $f
    regex-edit '(?s)    private fun compileModulesUsingFrontendIR\(.*?\n(?=    private fun getBuildFilePaths)' '    private fun compileModulesUsingFrontendIR(environment: KotlinCoreEnvironment, buildFile: File?, chunk: List<Module>, extendedAnalysisMode: Boolean): Boolean =\n        throw UnsupportedOperationException("FIR is not part of the bootstrap build")\n\n' $f
    grep -q 'not part of the bootstrap build' $f
    ! grep -q 'kotlin\.fir\.' $f
    sed -i '/org\.jetbrains\.kotlin\.fir\./d' compiler/cli/resources/META-INF/services/org.jetbrains.kotlin.diagnostics.rendering.DefaultErrorMessages\$Extension
  '';

  dirs1531 = dirs1432 ++ [
    "compiler/frontend/cfg/src"
    "compiler/ir/backend.jvm/entrypoint/src"
    "compiler/ir/ir.tree.persistent/gen"
    "js/js.sourcemap/src"
  ];

  dirs160 = dirs1531 ++ [ "compiler/ir/backend.jvm/lower/src" ];

  dirs1621 = dirs160 ++ [
    "compiler/frontend.common-psi/src"
    "compiler/ir/backend.jvm/codegen/src"
  ];

  dirs170 =
    (lib.subtractLists [
      "compiler/ir/ir.tree.persistent/gen"
      "compiler/ir/ir.tree.persistent/src"
    ] dirs1621)
    ++ [ "compiler/frontend.common.jvm/src" ];

  dirs180 = (lib.subtractLists [ "compiler/ir/ir.tree.impl/src" ] dirs170) ++ [
    "analysis/light-classes-base/src"
    "compiler/ir/ir.tree/gen"
  ];

  dirs2120 = lib.subtractLists [ "js/js.dce/src" "js/js.inliner/src" ] dirs210 ++ [
    "compiler/ir/backend.native/src"
    "native/base/src"
  ];
  firDirs2120 = firDirs210 ++ [
    "compiler/config/gen"
    "compiler/config.jvm/gen"
    "compiler/cli/cli-base/gen"
    "js/js.frontend/gen"
  ];
  dirs230 = dirs220 ++ [
    "compiler/ir/ir.validation/src"
    "js/typescript-export-model/src"
    "js/typescript-printer/src"
    "native/binary-options/src"
    "compiler/build-tools/kotlin-build-tools-api/gen"
    "js/js.config/gen"
  ];
  firDirs230 = firDirs220;
  dirs240 = lib.subtractLists [ "compiler/cli/cli-common/gen" "compiler/fir/fir-js/src" ] dirs230 ++ [
    "compiler/cli/cli-jvm/src"
    "compiler/cli/cli-metadata/src"
    "native/native.config/src"
    "core/names/src"
    "core/language.model/src"
    "core/language.targets/src"
    "core/language.targets.jvm/src"
    "core/language.version-settings/src"
    "compiler/fir/diagnostic-renderers/src"
    "compiler/frontend.common/gen"
    "wasm/wasm.frontend/gen"
    "native/native.config/gen"
  ];
  firDirs240 = lib.subtractLists [ "compiler/fir/fir-js/src" ] firDirs230;
  dirs220 = lib.subtractLists [ "compiler/builtins-serializer/src" ] dirs2120 ++ [
    "compiler/arguments.common/src"
    "js/js.frontend.common/src"
  ];
  firDirs210 = [
    "compiler/fir/raw-fir/light-tree2fir/src"
    "compiler/fir/cones/src"
    "compiler/fir/providers/src"
    "compiler/fir/semantics/src"
    "compiler/fir/resolve/src"
    "compiler/fir/fir-serialization/src"
    "compiler/fir/fir-deserialization/src"
    "compiler/fir/plugin-utils/src"
    "compiler/fir/tree/src"
    "compiler/fir/tree/gen"
    "compiler/fir/java/src"
    "compiler/fir/native/src"
    "compiler/fir/raw-fir/raw-fir.common/src"
    "compiler/fir/raw-fir/raw-fir.common/gen"
    "compiler/fir/raw-fir/psi2fir/src"
    "compiler/fir/checkers/src"
    "compiler/fir/checkers/gen"
    "compiler/fir/checkers/checkers.jvm/src"
    "compiler/fir/checkers/checkers.jvm/gen"
    "compiler/fir/checkers/checkers.js/src"
    "compiler/fir/checkers/checkers.js/gen"
    "compiler/fir/checkers/checkers.native/src"
    "compiler/fir/checkers/checkers.native/gen"
    "compiler/fir/checkers/checkers.wasm/src"
    "compiler/fir/checkers/checkers.wasm/gen"
    "compiler/fir/checkers/checkers.web.common/src"
    "compiler/fir/checkers/checkers.web.common/gen"
    "compiler/fir/entrypoint/src"
    "compiler/fir/fir2ir/src"
    "compiler/fir/fir2ir/jvm-backend/src"
  ];
  firDirs220 = [
    "compiler/config/gen"
    "compiler/config.jvm/gen"
    "compiler/cli/cli-base/gen"
    "js/js.frontend/gen"
    "compiler/fir/cones/src"
    "compiler/fir/providers/src"
    "compiler/fir/semantics/src"
    "compiler/fir/resolve/src"
    "compiler/fir/fir-serialization/src"
    "compiler/fir/fir-deserialization/src"
    "compiler/fir/plugin-utils/src"
    "compiler/fir/tree/src"
    "compiler/fir/tree/gen"
    "compiler/fir/fir-jvm/src"
    "compiler/fir/fir-js/src"
    "compiler/fir/fir-native/src"
    "compiler/fir/raw-fir/raw-fir.common/src"
    "compiler/fir/raw-fir/raw-fir.common/gen"
    "compiler/fir/raw-fir/psi2fir/src"
    "compiler/fir/raw-fir/light-tree2fir/src"
    "compiler/fir/checkers/src"
    "compiler/fir/checkers/gen"
    "compiler/fir/checkers/checkers.jvm/src"
    "compiler/fir/checkers/checkers.jvm/gen"
    "compiler/fir/checkers/checkers.js/src"
    "compiler/fir/checkers/checkers.js/gen"
    "compiler/fir/checkers/checkers.native/src"
    "compiler/fir/checkers/checkers.native/gen"
    "compiler/fir/checkers/checkers.wasm/src"
    "compiler/fir/checkers/checkers.wasm/gen"
    "compiler/fir/checkers/checkers.web.common/src"
    "compiler/fir/checkers/checkers.web.common/gen"
    "compiler/fir/entrypoint/src"
    "compiler/fir/fir2ir/src"
    "compiler/fir/fir2ir/jvm-backend/src"
  ];
  dirs210 = lib.subtractLists [ "analysis/project-structure/src" ] dirs200 ++ [
    "compiler/build-tools/kotlin-build-tools-jdk-utils/src/main/kotlin"
  ];
  dirs200 = dirs190 ++ [
    "compiler/build-tools/kotlin-build-tools-api/src/main/kotlin"
    "compiler/ir/ir.actualization/src"
    "compiler/ir/ir.inline/src"
    "compiler/ir/ir.objcinterop/src"
    "compiler/ir/serialization.native/src"
    "compiler/util-klib-abi/src"
    "core/compiler.common.native/src"
    "core/compiler.common.wasm/src"
    "core/compiler.common.web/src"
  ];
  dirs190 = dirs180 ++ [
    "compiler/cli/cli-common/gen"
    "analysis/project-structure/src"
    "compiler/build-tools/kotlin-build-statistics/src"
    "compiler/cli/cli-base/src"
    "core/compiler.common.js/src"
    "wasm/wasm.config/src"
    "wasm/wasm.frontend/src"
  ];

  dirs1432 = [
    "build-common/src"
    "compiler/backend-common/src"
    "compiler/backend.common.jvm/src"
    "compiler/backend/src"
    "compiler/builtins-serializer/src"
    "compiler/cli/cli-common/src"
    "compiler/cli/cli-js/src"
    "compiler/cli/src"
    "compiler/compiler.version/src"
    "compiler/config.jvm/src"
    "compiler/config/src"
    "compiler/container/src"
    "compiler/frontend.common/src"
    "compiler/frontend.java/src"
    "compiler/frontend/src"
    "compiler/incremental-compilation-impl/src"
    "compiler/ir/backend.common/src"
    "compiler/ir/backend.js/src"
    "compiler/ir/backend.jvm/src"
    "compiler/ir/backend.wasm/src"
    "compiler/ir/ir.interpreter/src"
    "compiler/ir/ir.psi2ir/src"
    "compiler/ir/ir.tree.impl/src"
    "compiler/ir/ir.tree.persistent/src"
    "compiler/ir/ir.tree/src"
    "compiler/ir/serialization.common/src"
    "compiler/ir/serialization.js/src"
    "compiler/ir/serialization.jvm/src"
    "compiler/javac-wrapper/src"
    "compiler/light-classes/src"
    "compiler/plugin-api/src"
    "compiler/psi/src"
    "compiler/resolution.common.jvm/src"
    "compiler/resolution.common/src"
    "compiler/resolution/src"
    "compiler/serialization/src"
    "compiler/util-io/src"
    "compiler/util-klib-metadata/src"
    "compiler/util-klib/src"
    "compiler/util/src"
    "core/compiler.common.jvm/src"
    "core/compiler.common/src"
    "core/descriptors.jvm/src"
    "core/descriptors.runtime/src"
    "core/descriptors/src"
    "core/deserialization.common.jvm/src"
    "core/deserialization.common/src"
    "core/deserialization/src"
    "core/metadata.jvm/src"
    "core/metadata/src"
    "core/util.runtime/src"
    "js/js.ast/src"
    "js/js.config/src"
    "js/js.dce/src"
    "js/js.frontend/src"
    "js/js.inliner/src"
    "js/js.parser/src"
    "js/js.serializer/src"
    "js/js.translator/src"
    "native/frontend/src"
    "native/utils/src"
    "wasm/wasm.ir/src"
  ];

  # Relocate the compiler core classes in kotlin-reflect.jar and strip their
  # Kotlin metadata, as upstream does (otherwise compiling the next compiler
  # against this runtime sees two versions of the same classes).
  relocateReflect = ''
    cd $out/lib
    cat > rules.txt <<EOF
    rule org.jetbrains.kotlin.** kotlin.reflect.jvm.internal.impl.@1
    rule javax.inject.** kotlin.reflect.jvm.internal.impl.javax.inject.@1
    EOF
    java -cp ${
      javaLib.classpathOf [ java.jarjar ]
    } com.tonicsystems.jarjar.Main process rules.txt kotlin-reflect.jar reflect-jarjar.jar
    java -cp ${javaLib.classpathOf [ kotlinLibs.strip-kotlin-metadata ]} StripKotlinMetadata \
      'kotlin/reflect/jvm/internal/impl/.*' reflect-jarjar.jar kotlin-reflect.jar
    rm rules.txt reflect-jarjar.jar
    # jarjar does not relocate service descriptors
    mkdir svc
    (cd svc
    unzip -q ../kotlin-reflect.jar 'META-INF/services/*'
    for f in META-INF/services/org.jetbrains.kotlin.*; do
      [ -e "$f" ] || continue
      n=META-INF/services/kotlin.reflect.jvm.internal.impl.''${f#META-INF/services/org.jetbrains.kotlin.}
      sed 's/^org\.jetbrains\.kotlin\./kotlin.reflect.jvm.internal.impl./' "$f" > "$n"
      rm "$f"
      zip -q -d ../kotlin-reflect.jar "$f"
      zip -q ../kotlin-reflect.jar "$n"
      echo "relocated service $n"
    done)
    rm -r svc
    cd -
  '';

  # Replace the Gradle based "runtime" target by the Ant targets of 1.1.2.
  antRuntime =
    {
      fragment ? ../../patches/own/runtime-targets-1.1.xml,
      stdlibOptions ? "",
    }:
    ''
      regex-edit '<target name="runtime"\s+depends="gradle-runtime[^"]*"\s*/>' "" build.xml
      sed -e "s|@JUNIT_JAR@|${jar java.junit4}|" -e "s|@STDLIB_EXTRA_OPTIONS@|${stdlibOptions}|" \
        ${fragment} > runtime-targets.xml
      regex-edit --subst-file TARGETS runtime-targets.xml '</project>\s*$' '@TARGETS@\n</project>\n' build.xml
      grep -q 'name="kotlin-test"' build.xml
    '';
in
chain
// {
  inherit jdk-annotations;
  latest = chain."1.1.2-5";
}
