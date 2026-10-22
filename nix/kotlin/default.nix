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
          perl -pi -e 's/<(jar|jarjar) /<$1 level="0" modificationtime="0" /g' build.xml
        '';
        remove-targets = ''
          for t in android-compiler-plugin androidSdkAnnotations android-sdk-annotations compilerSources \
                   compiler-sources daemon-client j2kConverter jslib runtime_sources; do
            perl -pi -e "s/,$t(,|\")/\$1/g" build.xml
          done
        '';
        # fix non-deterministic bytecode generation caused by random iteration
        # order of basic hash maps and sets
        fix-value-order = ''
          find . -type f \( -name '*.java' -o -name '*.kt' \) -print0 \
            | xargs -0 perl -pi -e 's/([^_[:alnum:]]|new)Hash(Map|Set)/$1LinkedHash$2/g'
          find . -depth -type f -regextype posix-extended -regex '.*/(|.*[^_[:alnum:]]|new)Hash(Map|Set)[^/]*' -print \
            | while read -r f; do
                d=$(dirname "$f"); b=$(basename "$f")
                mv -v "$f" "$d/''${b//Hash/LinkedHash}"
              done
        '';
        disable-classpath-from-env = ''
          perl -0pi -e 's/(<project[^>]+>)/$1<property name="build.sysclasspath" value="ignore"\/>/' build.xml
        '';
        update-asm = ''
          find . -type f \( -name '*.java' -o -name '*.kt' \) -print0 | xargs -0 perl -pi -e '
            s/([^[:alnum:]])org\.jetbrains\.asm4([^[:alnum:]])/$1org.jetbrains.org.objectweb.asm$2/g;
            s/(new InstructionAdapter\()(.+\)\s+\{\s*)$/$1org.jetbrains.org.objectweb.asm.Opcodes.ASM4, $2/;
            s/(new MethodNode\()(.+\)\s+\{\s*)$/$1org.jetbrains.org.objectweb.asm.Opcodes.ASM4, $2/;
          '
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
    map (name: { inherit name; script = s.${name}; }) [
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

  addLast = name: script: s: s ++ [ { inherit name script; } ];

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

  same = prev: version: patches: step prev version patches { };

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
    "1.1.3-dev-1317" = buildWith {
      mainPatch = false;
      install = relocateReflect;
    } k."1.1.2-5" "1.1.3-dev-1317" p113 {
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
          (ops.replace "ant-runtime" (antRuntime { fragment = ../../patches/own/runtime-targets-1.1.4.xml; }))
          (addLast "scripted-edits" scriptedEdits)
          (addLast "fresh-script-runtime" (freshRuntime "script-runtime" [ "core/script.runtime/src" ]))
          (addLast "prepare-deps-1.1.4" ''
            ln -s ${jar kotlinLibs.json-org} dependencies/json-org.jar
            ln -s ${jar (kotlinLibs.kotlinx-coroutines-core-0_14 k."1.1.3")} dependencies/kotlinx-coroutines-core.jar
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
      steps = ops.replace "ant-runtime" (antRuntime { fragment = ../../patches/own/runtime-targets-1.2.xml; });
    };
    "1.2.10" = step k."1.2.0" "1.2.10" [ ] {
      steps = addLast "jvm-target-1.8" ''
        sed -i -e 's|<compilerarg value="-version"/>|& <compilerarg line="-jvm-target 1.8"/>|' build.xml
      '';
    };
    "1.2.21" = step k."1.2.10" "1.2.21" [ ] {
      steps = ops.replace "ant-runtime" (antRuntime { fragment = ../../patches/own/runtime-targets-1.2.21.xml; });
    };
    "1.2.31" = step k."1.2.21" "1.2.31" [ ] { };
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
    perl -0pi -e 's/public static final boolean COLOR_ENABLED;\s*static \{.*?COLOR_ENABLED = colorEnabled;\s*\}/public static final boolean COLOR_ENABLED = true;/s; s/import org\.fusesource\.jansi\.internal\.CLibrary;\n//' $f
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
    antFlagsExtra+=" -Dbootstrap.${lib.replaceStrings [ "-" ] [ "." ] name}=$PWD/dependencies/kotlin-${name}-fresh.jar"
  '';

  # Relocate the compiler core classes in kotlin-reflect.jar and strip their
  # Kotlin metadata, as upstream does (otherwise compiling the next compiler
  # against this runtime sees two versions of the same classes).
  relocateReflect = ''
    cd $out/lib
    cat > rules.txt <<EOF
    rule org.jetbrains.kotlin.** kotlin.reflect.jvm.internal.impl.@1
    rule javax.inject.** kotlin.reflect.jvm.internal.impl.javax.inject.@1
    EOF
    java -cp ${javaLib.classpathOf [ java.jarjar ]} com.tonicsystems.jarjar.Main process rules.txt kotlin-reflect.jar reflect-jarjar.jar
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
      perl -0pi -e 's|<target name="runtime"\s+depends="gradle-runtime[^"]*"\s*/>||' build.xml
      sed -e "s|@JUNIT_JAR@|${jar java.junit4}|" -e "s|@STDLIB_EXTRA_OPTIONS@|${stdlibOptions}|" \
        ${fragment} > runtime-targets.xml
      FRAG=runtime-targets.xml perl -0pi -e 'BEGIN { local $/; open F, "<", $ENV{FRAG}; $f = <F> } s|</project>\s*$|$f\n</project>\n|' build.xml
      grep -q 'name="kotlin-test"' build.xml
    '';
in
chain
// {
  inherit jdk-annotations;
  latest = chain."1.1.2-5";
}
