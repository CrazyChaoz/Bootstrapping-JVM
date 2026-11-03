# Builder for one step of the Kotlin bootstrap chain (Ant based builds,
# Kotlin 0.6 .. 1.1).  A step is described by a "config" attribute set; later
# steps are derived from earlier ones by modifying the config, mirroring the
# package inheritance used in TarCV/kotlin-guix.
{
  lib,
  stdenv,
  ant,
  zip,
  unzip,
  python3,
  regexEdit,
  kotlinSources,
  javaLib,
}:

let
  patchDir = ./patches;

  # Steps are an ordered list of { name, script } run before the Ant build.
  stepOps = rec {
    names = steps: map (s: s.name) steps;
    has = name: steps: lib.elem name (names steps);
    delete =
      name: steps:
      assert has name steps || throw "no step ${name}";
      lib.filter (s: s.name != name) steps;
    replace =
      name: script: steps:
      assert has name steps || throw "no step ${name}";
      map (s: if s.name == name then s // { inherit script; } else s) steps;
    append =
      name: script: steps:
      steps ++ [ { inherit name script; } ];
    addAfter =
      after: name: script: steps:
      assert has after steps || throw "no step ${after}";
      lib.concatMap (
        s:
        if s.name == after then
          [
            s
            { inherit name script; }
          ]
        else
          [ s ]
      ) steps;
  };

  mkKotlin =
    cfg:
    stdenv.mkDerivation {
      pname = "kotlin-bootstrap";
      inherit (cfg) version;
      src = cfg.src or kotlinSources.${cfg.version};

      patches = map (n: patchDir + "/${n}") (
        lib.optional (
          (cfg.mainPatch or true) && builtins.pathExists (patchDir + "/kotlin-${cfg.version}.patch")
        ) "kotlin-${cfg.version}.patch"
        ++ cfg.patches
      );

      nativeBuildInputs = [
        cfg.jdk
        ant
        zip
        unzip
        python3
        regexEdit
      ];

      configurePhase = ''
        runHook preConfigure
        export JAVA_HOME=${cfg.jdk.home or cfg.jdk}
        # Like Guix: every jar found in any input (and their propagated inputs).
        CLASSPATH=
        for d in ${lib.concatStringsSep " " (map toString (javaLib.closureOf (lib.attrValues cfg.inputs)))}; do
          for j in $(find -L $d -name '*.jar' | sort); do CLASSPATH="$CLASSPATH$j:"; done
        done
        export CLASSPATH="$CLASSPATH$JAVA_HOME/lib/tools.jar"
        export ANT_OPTS="${cfg.antOpts or "-Xmx2g"}"${
          lib.optionalString (cfg.utf8 or false)
            "\nexport LC_ALL=C.UTF-8 ANT_OPTS=\"$ANT_OPTS -Dfile.encoding=UTF-8\" JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8"
        }
        runHook postConfigure
      '';

      preBuild =
        lib.optionalString (cfg.dynamicFlags or false) ''
          BOOTSTRAP=${cfg.bootstrap}
          antFlagsExtra=
        ''
        + lib.concatMapStringsSep "\n" (s: ''
          echo "## step: ${s.name}"
          ${s.script}
        '') cfg.steps;

      buildPhase = ''
        runHook preBuild
        ant ${cfg.target or "dist"} \
          -Dkotlin-home=$out \
          ${lib.escapeShellArgs cfg.antFlags} \
          ${lib.optionalString (cfg.bootstrap != null) "-Dbootstrap.compiler.home=${cfg.bootstrap}"}${
            lib.optionalString (cfg.dynamicFlags or false) " $antFlagsExtra"
          }
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        ${cfg.install or ""}
        runHook postInstall
      '';

      # The build output is the kotlinc distribution directory.
      dontStrip = true;

      passthru = {
        inherit cfg;
        inherit (cfg) bootstrap;
      };

      meta = {
        description = "Kotlin ${cfg.version}, bootstrapped from source";
        license = lib.licenses.asl20;
      };
    };
in
{
  inherit mkKotlin stepOps;
}
