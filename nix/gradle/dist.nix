# The Gradle distribution (lib/, lib/plugins/, lib/agents/, bin/gradle), laid out like the
# one Gradle's own build produces (packaging/distributions-full).  The module graph comes from
# modules.json: the core is the closure of core-platform, the plugins the rest of the closure of
# distributions-full.  Every jar has a "<module>.properties" next to it for the module registry.
{
  lib,
  stdenv,
  jdk,
  zip,
  unzip,
  python3,
  gradleSrc,
  gradleModules,
  gradleLibs,
  classpathOf,
  version ? "9.8.0",
  # the generated Kotlin extensions of the Gradle API (null: an empty jar)
  kotlinDslExtensions ? null,
  # modules that do not build yet (missing third party libraries)
  excluded ? [
    "resources-gcs"
    "resources-s3"
    "build-init"
  ],
}:

let
  modules = builtins.fromJSON (builtins.readFile ./modules.json);
  libMap = gradleModules._libMap;

  runtimeConfs = [
    "api"
    "implementation"
    "runtimeOnly"
    "runtime"
    "coreRuntimeOnly"
    "pluginsRuntimeOnly"
  ];
  apiConfs = [
    "api"
    "runtime"
    "coreRuntimeOnly"
    "pluginsRuntimeOnly"
  ];

  hasJar = n: modules.${n}.src != { } && !(lib.elem n excluded);

  projectNode = n: {
    key = "project:${n}";
    kind = "project";
    name = n;
  };
  libNode = d: {
    key = toString d;
    kind = "lib";
    drv = d;
  };

  children =
    confs: node:
    if node.kind == "project" then
      let
        ds = lib.concatMap (c: modules.${node.name}.deps.${c} or [ ]) confs;
        projects = map (d: projectNode (lib.removePrefix "project:" d)) (
          lib.filter (d: lib.hasPrefix "project:" d && modules ? ${lib.removePrefix "project:" d}) ds
        );
        libs = map (d: libNode libMap.${lib.removePrefix "lib:" d}) (
          lib.filter (d: lib.hasPrefix "lib:" d && libMap ? ${lib.removePrefix "lib:" d}) ds
        );
      in
      projects ++ libs
    else
      map libNode (node.drv.passthru.javaDeps or [ ]);

  closure =
    confs: roots:
    builtins.genericClosure {
      startSet = map projectNode roots;
      operator = children confs;
    };

  # nodes that go into the distribution (project nodes without sources are only grouping platforms)
  real = nodes: lib.filter (n: n.kind == "lib" || hasJar n.name) nodes;

  coreRoots = [ "core-platform" ];
  pluginRoots = lib.filter (n: n != "core-platform") (
    lib.concatMap (p: map (lib.removePrefix "project:") (modules.${p}.deps.pluginsRuntimeOnly or [ ])) [
      "distributions-full"
    ]
  );
  agentRoots = map (lib.removePrefix "project:") modules.distributions-full.deps.agentsRuntimeOnly;

  coreNodes = real (closure runtimeConfs coreRoots);
  pluginNodes = real (closure runtimeConfs pluginRoots);
  agentNodes = real (closure runtimeConfs agentRoots);
  apiPluginNodes = real (closure apiConfs pluginRoots);

  keys = nodes: map (n: n.key) nodes;
  coreKeys = keys coreNodes;
  onlyPlugins = lib.filter (n: !(lib.elem n.key coreKeys)) pluginNodes;
  onlyAgents = lib.filter (n: !(lib.elem n.key coreKeys) && !(lib.elem n.key (keys pluginNodes))) agentNodes;

  # (module names are Maven artifact ids)
  artifactIds = {
    javax-inject = "javax.inject";
  };
  libName =
    n:
    let
      p = n.drv.pname or (builtins.parseDrvName n.drv.name).name;
    in
    artifactIds.${p} or p;
  libVersion = n: n.drv.version or (builtins.parseDrvName n.drv.name).version;
  moduleName = n: if n.kind == "project" then "gradle-${n.name}" else libName n;
  jarFile = n: if n.kind == "project" then "gradle-${n.name}-${version}.jar" else "${libName n}-${libVersion n}.jar";
  jarPath =
    n:
    if n.kind == "project" then
      "${gradleModules.${n.name}}/share/java/gradle-${n.name}.jar"
    else
      "${n.drv}/share/java/${n.drv.pname or (builtins.parseDrvName n.drv.name).name}.jar";

  # the registry dependencies: direct runtime dependencies (a lib's are all its transitive ones)
  depNames =
    n:
    lib.sort (a: b: a < b) (
      lib.unique (map moduleName (lib.filter (c: c.kind == "lib" || hasJar c.name) (children runtimeConfs n)))
    );

  install =
    dir: n:
    let
      props = lib.concatStringsSep "\n" (
        [
          "dependencies=${lib.concatStringsSep "," (depNames n)}"
          "jarFile=${jarFile n}"
        ]
      );
    in
    ''
      install -Dm644 ${jarPath n} $out/${dir}/${jarFile n}
      cat > $out/${dir}/${moduleName n}.properties <<'EOF2'
      ${props}
      EOF2
    '';

  projectJarNames = nodes: lib.sort (a: b: a < b) (map moduleName (lib.filter (n: n.kind == "project") nodes));

  cliMainClasspath = lib.concatStringsSep " " (
    map jarFile (
      lib.filter (n: n.key != "project:gradle-cli-main") (
        real (
          builtins.genericClosure {
            startSet = [ (projectNode "gradle-cli-main") ];
            operator = children runtimeConfs;
          }
        )
      )
    )
  );

  daemonMainClasspath = lib.concatStringsSep " " (
    map jarFile (
      real (
        builtins.genericClosure {
          startSet = map (d: projectNode (lib.removePrefix "project:" d)) modules.daemon-main.deps.manifestClasspath;
          operator = children runtimeConfs;
        }
      )
    )
  );

  sourceDirs = lib.concatMapStringsSep " " (n: "${gradleSrc}/${modules.${n.name}.dir}/src/main/java") (
    lib.filter (n: n.kind == "project") (coreNodes ++ onlyPlugins)
  );
  projectJars = lib.concatMapStringsSep " " jarPath (lib.filter (n: n.kind == "project") (coreNodes ++ onlyPlugins));
in
stdenv.mkDerivation {
  pname = "gradle";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [
    jdk
    zip
    unzip
    python3
  ];
  buildPhase = ''
    runHook preBuild
    export CLASSPATH="${classpathOf [ gradleLibs.asm ]}"

    # metadata of gradle-runtime-api-info.jar
    mkdir -p info/org/gradle/api/internal/runtimeshaded
    python3 ${./gen-api-info.py} info ${sourceDirs}
    mkdir cls && cp ${./InstrumentationMetadata.java} InstrumentationMetadata.java
    javac -nowarn -d cls InstrumentationMetadata.java
    java -cp cls:$CLASSPATH InstrumentationMetadata info ${projectJars}
    : > info/org/gradle/api/internal/runtimeshaded/api-relocated.txt
    echo "plugins=${lib.concatStringsSep "," (projectJarNames (lib.filter (n: !(lib.elem n.key coreKeys)) apiPluginNodes))}" > info/gradle-plugins.properties
    echo "plugins=${lib.concatStringsSep "," (projectJarNames onlyPlugins)}" > info/gradle-implementation-plugins.properties
    jar cf gradle-runtime-api-info-${version}.jar -C info .
    runHook postBuild
  '';
  # (too long for an environment variable)
  jarInstall =
    lib.concatMapStrings (install "lib") coreNodes
    + ''
      install -Dm644 ${gradleLibs.ant}/share/java/ant-launcher.jar $out/lib/ant-launcher-${gradleLibs.ant.version}.jar
      printf 'dependencies=\njarFile=ant-launcher-${gradleLibs.ant.version}.jar\n' > $out/lib/ant-launcher.properties
    ''
    + lib.concatMapStrings (install "lib/plugins") onlyPlugins
    + lib.concatMapStrings (install "lib/agents") onlyAgents;
  passAsFile = [ "jarInstall" ];
  installPhase = ''
    runHook preInstall
    . "$jarInstallPath"

    install -Dm644 gradle-runtime-api-info-${version}.jar $out/lib/plugins/gradle-runtime-api-info-${version}.jar
    printf 'dependencies=\njarFile=gradle-runtime-api-info-${version}.jar\n' > $out/lib/plugins/gradle-runtime-api-info.properties

    # the public API for compiling build scripts: the classes of all modules (upstream has signature stubs)
    mkdir api
    for j in ${projectJars}; do unzip -qo "$j" '*.class' 'META-INF/*.kotlin_module' -d api || [ $? = 11 ]; done
    jar cf $out/lib/plugins/gradle-public-api-legacy-${version}.jar -C api .
    printf 'dependencies=\njarFile=gradle-public-api-legacy-${version}.jar\n' > $out/lib/plugins/gradle-public-api-legacy.properties

    ${
      if kotlinDslExtensions == null then
        "mkdir kext && jar cf $out/lib/plugins/gradle-kotlin-dsl-extensions-${version}.jar -C kext ."
      else
        "cp ${kotlinDslExtensions}/share/java/gradle-kotlin-dsl-extensions.jar $out/lib/plugins/gradle-kotlin-dsl-extensions-${version}.jar"
    }
    printf 'dependencies=\njarFile=gradle-kotlin-dsl-extensions-${version}.jar\n' > $out/lib/plugins/gradle-kotlin-dsl-extensions.properties

    # build receipt (GradleVersion)
    mkdir -p receipt/org/gradle
    cat > receipt/org/gradle/build-receipt.properties <<'EOF2'
    commitId=HEAD
    scriptTemplateCommitId=HEAD
    versionNumber=${version}
    baseVersion=${version}
    isSnapshot=false
    buildTimestamp=19800101000000+0000
    buildTimestampIso=1980-01-01 00:00:00 UTC
    EOF2
    sed -i 's/^    //' receipt/org/gradle/build-receipt.properties
    chmod u+w $out/lib/gradle-base-services-${version}.jar
    (cd receipt && jar uf $out/lib/gradle-base-services-${version}.jar org/gradle/build-receipt.properties)

    # launchable jars
    python3 - > manifest-main <<'EOF2'
    def wrap(line):
        parts = [line[:70]] + [line[i:i + 69] for i in range(70, len(line), 69)]
        return "\n ".join(parts)
    print("Main-Class: org.gradle.launcher.GradleMain")
    print("Enable-Native-Access: ALL-UNNAMED")
    print(wrap("Class-Path: ${cliMainClasspath}"))
    EOF2
    chmod u+w $out/lib/gradle-gradle-cli-main-${version}.jar
    jar ufm $out/lib/gradle-gradle-cli-main-${version}.jar manifest-main
    python3 - > manifest-daemon <<'EOF2'
    def wrap(line):
        parts = [line[:70]] + [line[i:i + 69] for i in range(70, len(line), 69)]
        return "\n ".join(parts)
    print("Main-Class: org.gradle.launcher.daemon.bootstrap.GradleDaemon")
    print(wrap("Class-Path: ${daemonMainClasspath}"))
    EOF2
    chmod u+w $out/lib/gradle-daemon-main-${version}.jar
    jar ufm $out/lib/gradle-daemon-main-${version}.jar manifest-daemon
    printf 'Premain-Class: org.gradle.instrumentation.agent.Agent\n' > manifest-agent
    chmod u+w $out/lib/agents/gradle-instrumentation-agent-${version}.jar
    jar ufm $out/lib/agents/gradle-instrumentation-agent-${version}.jar manifest-agent

    mkdir -p $out/bin
    cat > $out/bin/gradle <<'EOF2'
    #!/bin/sh
    app_path=$0
    while [ -h "$app_path" ]; do
      ls=$(ls -ld "$app_path"); link=''${ls#*' -> '}
      case $link in /*) app_path=$link ;; *) app_path=$(dirname "$app_path")/$link ;; esac
    done
    APP_HOME=$(cd "$(dirname "$app_path")/.." > /dev/null && pwd -P)
    if [ -n "$JAVA_HOME" ]; then JAVACMD=$JAVA_HOME/bin/java; else JAVACMD=java; fi
    exec "$JAVACMD" -Xmx64m -Xms64m "-javaagent:$APP_HOME/lib/agents/gradle-instrumentation-agent-${version}.jar" \
      -Dorg.gradle.appname=gradle $JAVA_OPTS $GRADLE_OPTS -jar "$APP_HOME/lib/gradle-gradle-cli-main-${version}.jar" "$@"
    EOF2
    sed -i 's/^    //' $out/bin/gradle
    chmod +x $out/bin/gradle
    runHook postInstall
  '';
}
