# A small analogue of Guix' `ant-build-system` with `#:jar-name`: compile every
# .java file below `sourceDirs` with plain javac and pack the classes into
# $out/share/java/${jarName}.
#
# Java dependencies are passed in `deps` (propagated: they end up on the
# classpath of everything depending on this jar) or `buildDeps` (only used to
# compile this jar).  Every Java package in this tree installs its jars into
# $out/share/java, and the classpath is "all jars of the transitive closure".
{
  lib,
  stdenv,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
}:

let
  closureOf = deps: lib.unique (lib.concatMap (d: [ d ] ++ (d.passthru.javaDeps or [ ])) deps);

  # A shell snippet expanding to the colon separated classpath of `deps`.
  classpathOf =
    deps:
    let
      all = closureOf deps;
    in
    if all == [ ] then
      ""
    else
      "$(for d in ${lib.concatStringsSep " " (map toString all)}; do for j in $d/share/java/*.jar; do [ -e \"$j\" ] && printf '%s:' \"$j\"; done; done)";

  mkJar =
    {
      pname,
      version ? "0",
      jarName ? "${pname}.jar",
      sourceDirs ? [ "src" ],
      # Directories whose non-.java files are copied next to the classes.
      resourceDirs ? [ ],
      # Copy non-.java files found in sourceDirs as resources.
      copySourceResources ? false,
      deps ? [ ],
      buildDeps ? [ ],
      javaRelease ? "1.8",
      javacFlags ? [ ],
      encoding ? "UTF-8",
      mainClass ? null,
      # Extra jars whose classes are merged into the produced jar.
      mergeJars ? [ ],
      ...
    }@args:
    let
      cp = classpathOf (deps ++ buildDeps);
      extraArgs = removeAttrs args [
        "deps"
        "buildDeps"
        "sourceDirs"
        "resourceDirs"
        "javacFlags"
        "mergeJars"
        "passthru"
      ];
    in
    stdenv.mkDerivation (
      extraArgs
      // {
        inherit pname version;
        nativeBuildInputs = [
          jdk
          zip
          unzip
          stripJavaArchivesHook
        ]
        ++ (args.nativeBuildInputs or [ ]);

        buildPhase =
          args.buildPhase or ''
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
              javac -d build/classes -encoding ${encoding} \
                -source ${javaRelease} -target ${javaRelease} \
                -nowarn -g -Xmaxerrs 1000 \
                -cp "$CLASSPATH" ${lib.escapeShellArgs javacFlags} \
                @build/sources.txt
            fi
            ${lib.optionalString copySourceResources ''
              for d in ${lib.escapeShellArgs sourceDirs}; do
                (cd "$d" && find . -type f ! -name '*.java' -exec cp --parents -t "$OLDPWD/build/classes" {} +)
              done
            ''}
            for d in ${lib.escapeShellArgs resourceDirs}; do
              cp -r "$d"/. build/classes/
            done
            for j in ${lib.escapeShellArgs mergeJars}; do
              (cd build/classes && unzip -qo "$j" -x 'META-INF/MANIFEST.MF' 'META-INF/INDEX.LIST')
            done
            runHook postBuild
          '';

        installPhase =
          args.installPhase or ''
            runHook preInstall
            mkdir -p $out/share/java
            ${
              if mainClass != null then
                "jar cfe $out/share/java/${jarName} ${mainClass} -C build/classes ."
              else
                "jar cf $out/share/java/${jarName} -C build/classes ."
            }
            runHook postInstall
          '';

        passthru = (args.passthru or { }) // {
          javaDeps = closureOf deps;
        };
      }
    );
in
{
  inherit mkJar closureOf classpathOf;
}
