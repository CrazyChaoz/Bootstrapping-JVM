# The Gradle distribution (lib/, lib/plugins/, lib/agents/, bin/gradle), laid out like the
# one Gradle's own build produces (packaging/distributions-full).  The module graph comes from
# modules/VERSION.json: the core is the closure of core-platform, the plugins the rest of the closure of
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
  modulesJson ? ./modules/${version}.json,
  # "sidecar": <module>.properties next to the jars (9.x); "embedded": <module>-classpath.properties in them (8.x)
  registryStyle ? "sidecar",
  embeddedKotlin ? "2.0.21",
  # the generated Kotlin extensions of the Gradle API (null: an empty jar)
  kotlinDslExtensions ? null,
  # modules that do not build yet (missing third party libraries)
  excluded ? [
    "resources-gcs"
    "resources-s3"
    "build-init"
  ],
  # dists/VERSION.json: lay out the distribution like the published one (its third-party
  # modules, registry, LICENSE, launchers, start scripts; dist-upstream.py)
  upstreamLock ? null,
  extraLockJars ? { }, # component -> jar, of components that are no dependency of Gradle's modules here
}:

let
  # GradleVersion's spelling of a pre-release tag: 9.9.0-RC1 -> 9.9.0-rc-1, 9.9.0-M2 -> 9.9.0-milestone-2
  pre = builtins.match "([0-9.]+)-(RC|M)([0-9]+)" version;
  versionNumber =
    if pre == null then
      version
    else
      "${lib.elemAt pre 0}-${if lib.elemAt pre 1 == "RC" then "rc" else "milestone"}-${lib.elemAt pre 2}";
  baseVersion = if pre == null then version else lib.elemAt pre 0;
  modules = builtins.fromJSON (builtins.readFile modulesJson);
  libMap = gradleModules._libMap;

  runtimeConfs = [
    "api"
    "implementation"
    "shadedImplementation" # (tooling-api's slf4j-api, relocated into its jar and still a dependency)
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
  onlyAgents = lib.filter (
    n: !(lib.elem n.key coreKeys) && !(lib.elem n.key (keys pluginNodes))
  ) agentNodes;

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
  jarFile =
    n:
    if n.kind == "project" then
      "gradle-${n.name}-${version}.jar"
    else
      "${libName n}-${libVersion n}.jar";
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
      lib.unique (
        map moduleName (lib.filter (c: c.kind == "lib" || hasJar c.name) (children runtimeConfs n))
      )
    );

  # all project and library jars on the runtime classpath of a node (its dependencies, transitively)
  runtimeClosure =
    n:
    lib.filter (c: c.key != n.key) (
      real (
        builtins.genericClosure {
          startSet = [ n ];
          operator = children runtimeConfs;
        }
      )
    );

  install =
    dir: n:
    let
      props = lib.concatStringsSep "\n" ([
        "dependencies=${lib.concatStringsSep "," (depNames n)}"
        "jarFile=${jarFile n}"
      ]);
      deps = runtimeClosure n;
      embeddedProps = lib.concatStringsSep "\n" (
        [
          "projects=${
            lib.concatStringsSep "," (
              lib.sort (a: b: a < b) (
                map moduleName (lib.filter (c: c.kind == "project") deps)
                ++ lib.optional (n.name == "core" || n.name == "launcher") "gradle-runtime-api-info"
              )
            )
          }"
          "runtime=${
            lib.concatStringsSep "," (
              lib.sort (a: b: a < b) (map jarFile (lib.filter (c: c.kind == "lib") deps))
            )
          }"
        ]
        ++
          lib.optional (n.kind == "project" && (modules.${n.name}.optional or [ ]) != [ ])
            "optional=${lib.concatStringsSep "," (modules.${n.name}.optional)}"
      );
    in
    if registryStyle == "embedded" then
      ''
        install -Dm644 ${jarPath n} $out/${dir}/${jarFile n}
      ''
      + lib.optionalString (n.kind == "project") ''
        mkdir -p reg && cat > reg/${moduleName n}-classpath.properties <<'EOF2'
        ${embeddedProps}
        EOF2
        chmod u+w $out/${dir}/${jarFile n}
        jar uf $out/${dir}/${jarFile n} -C reg ${moduleName n}-classpath.properties
      ''
    else
      ''
        install -Dm644 ${jarPath n} $out/${dir}/${jarFile n}
        cat > $out/${dir}/${moduleName n}.properties <<'EOF2'
        ${props}
        EOF2
      '';

  projectJarNames =
    nodes: lib.sort (a: b: a < b) (map moduleName (lib.filter (n: n.kind == "project") nodes));

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
          startSet = map (
            d: projectNode (lib.removePrefix "project:" d)
          ) modules.daemon-main.deps.manifestClasspath;
          operator = children runtimeConfs;
        }
      )
    )
  );

  sourceDirs = lib.concatMapStringsSep " " (
    n: "${gradleSrc}/${modules.${n.name}.dir}/src/main/java"
  ) (lib.filter (n: n.kind == "project") (coreNodes ++ onlyPlugins));
  projectJars = lib.concatMapStringsSep " " jarPath (
    lib.filter (n: n.kind == "project") (coreNodes ++ onlyPlugins)
  );

  # upstreamLock: the third-party jars by registry name, those of the lock not built here
  # (missing, or another version)
  lock = builtins.fromJSON (builtins.readFile upstreamLock);
  libNodes = lib.filter (n: n.kind == "lib") (coreNodes ++ onlyPlugins ++ onlyAgents);
  # (the direct dependencies of Gradle's modules first: a dependency of another module may be
  # another variant of it, e.g. the untransformed jar)
  directLibs = lib.filter (n: n.kind == "lib") (
    lib.concatMap (children runtimeConfs) (
      lib.filter (n: n.kind == "project") (coreNodes ++ onlyPlugins ++ onlyAgents)
    )
  );
  ourLibs =
    lib.listToAttrs (map (n: lib.nameValuePair (libName n) n) libNodes)
    // lib.listToAttrs (map (n: lib.nameValuePair (libName n) n) directLibs);
  # (registry name in the lock -> ours)
  libAliases = {
    kotlinx-serialization-core-jvm = "kotlinx-serialization-core";
    kotlinx-serialization-json-jvm = "kotlinx-serialization-json";
    configuration-cache-report-jvm = "configuration-cache-report";
  };
  # (of several variants by that name: the lock's version)
  lockLib =
    key: c:
    let
      name = libAliases.${key} or key;
      same = lib.filter (n: libName n == name && libVersion n == c.version) libNodes;
    in
    if same != [ ] then lib.head same else ourLibs.${name} or null;
  lockJar =
    key: c:
    let
      n = lockLib key c;
    in
    if key == "ant-launcher" then
      "${gradleLibs.ant}/share/java/ant-launcher.jar"
    else if extraLockJars ? ${key} then
      extraLockJars.${key}
    else if c.jarFile == null || n == null then
      null
    else
      jarPath n;
  upstreamGaps = lib.optionalAttrs (upstreamLock != null) (
    let
      withJar = lib.filterAttrs (
        k: c: c.jarFile != null && k != "ant-launcher" && !(extraLockJars ? ${k})
      ) lock.components;
      found = k: c: lockLib k c != null;
      used = map (k: libName (lockLib k lock.components.${k})) (lib.attrNames (lib.filterAttrs found withJar));
    in
    {
      missing = lib.attrNames (lib.filterAttrs (k: c: !found k c) withJar);
      otherVersion = lib.mapAttrs (k: c: "${libVersion (lockLib k c)} (upstream ${c.version})") (
        lib.filterAttrs (k: c: found k c && libVersion (lockLib k c) != c.version) withJar
      );
      # (our modules' dependencies that the published distribution does not have)
      notInUpstream = lib.unique (
        map libName (lib.filter (n: !(lib.elem (libName n) used) || !(lib.elem n (map (k: lockLib k lock.components.${k}) (lib.attrNames (lib.filterAttrs found withJar))))) libNodes)
      );
    }
  );
  upstreamConfig = builtins.toJSON {
    out = builtins.placeholder "out";
    lock = upstreamLock;
    jars = lib.mapAttrs lockJar lock.components;
    license = "${gradleSrc}/LICENSE";
    toplevel = "${gradleSrc}/packaging/distributions-full/src/toplevel";
  };
  # Gradle's modules without a jar (platforms: core-platform, distributions-*): registry entries only
  platformNodes = lib.filter (n: n.kind == "project" && modules.${n.name}.src == { }) (
    closure runtimeConfs (coreRoots ++ pluginRoots)
  );
  platformDeps =
    n:
    lib.sort (a: b: a < b) (
      lib.unique (
        map moduleName (
          lib.filter (c: c.kind == "lib" || hasJar c.name || modules.${c.name}.src == { }) (
            children runtimeConfs n
          )
        )
      )
    );
  # gradlebuild.distributions (applied by gradlebuild.distribution.packaging) adds
  # platform(project(":distributions-dependencies")) to coreRuntimeOnly, which the module graph does
  # not record; that platform's only dependency is platform(providedLibs.X) (the rest of its api(...)
  # are constraints)
  distPlatformDeps =
    n:
    lib.sort (a: b: a < b) (
      platformDeps n
      ++ lib.optional (lib.elem "gradlebuild.distribution.packaging" (
        modules.${n.name}.plugins or [ ]
      )) "gradle-distributions-dependencies"
    );
  distributionsDependenciesDeps =
    let
      m = builtins.match ".*api\\(platform\\(providedLibs\\.([A-Za-z0-9]+)\\)\\).*" (
        builtins.readFile "${gradleSrc}/packaging/distributions-dependencies/build.gradle.kts"
      );
      kebab = a: lib.concatMapStrings (c: if lib.toLower c != c then "-${lib.toLower c}" else c) (lib.stringToCharacters a);
    in
    map kebab (if m == null then [ ] else m);
  # the legacy public API's registry entry (a Maven resolution: from the lock)
  publicApiLegacyDeps = lock.publicApiLegacy or [ ];
  gradleJar = "python3 ${./gradle-jar.py}";
  stdAttrs = "--attr 'Implementation-Title: Gradle' --attr 'Implementation-Version: ${version}' --attr 'Implementation-Vendor: Gradle, Inc.'";
  pomFor = group: n: ''
    mkdir -p pom/${n}
    printf '#Generated by gradle-pom-properties\ngroupId=${group}\nartifactId=${n}\nversion=${version}\n' > pom/${n}/pom.properties
  '';
  # a Gradle module's jar again, with other manifest attributes (and more entries)
  repack =
    file: attrs: extra:
    ''
      mv ${file} repack.jar
      ${gradleJar} ${file} ${stdAttrs} --attr 'Implementation-Vendor-Id: org.gradle' ${attrs} --from repack.jar ${extra}
      rm repack.jar
    '';
  classPathAttr = jars: "--attr 'Class-Path: ${lib.concatStringsSep " " jars}'";
  upstreamInstall = ''
    runHook preInstall
    . "$jarInstallPath"
    python3 ${./dist-upstream.py} "$upstreamConfigPath"

    # the jars generated by the distribution's build
    ${pomFor "org.gradle" "gradle-runtime-api-info"}
    ${gradleJar} $out/lib/gradle-runtime-api-info-${version}.jar ${stdAttrs} --attr 'Implementation-Vendor-Id: org.gradle' \
      --root info --append META-INF/maven/org.gradle/gradle-runtime-api-info/pom.properties=pom/gradle-runtime-api-info/pom.properties
    printf 'dependencies=\njarFile=gradle-runtime-api-info-${version}.jar\n' > $out/lib/gradle-runtime-api-info.properties

    # (upstream has signature stubs)
    mkdir api
    for j in ${projectJars}; do unzip -qo "$j" '*.class' 'META-INF/*.kotlin_module' -d api || [ $? = 11 ]; done
    ${pomFor "org.gradle.experimental" "gradle-public-api-legacy"}
    mkdir -p $out/lib/api
    ${gradleJar} $out/lib/api/gradle-public-api-legacy-${version}.jar ${stdAttrs} --attr 'Implementation-Vendor-Id: org.gradle.experimental' \
      --append META-INF/maven/org.gradle.experimental/gradle-public-api-legacy/pom.properties=pom/gradle-public-api-legacy/pom.properties --root api
    printf 'dependencies=${lib.concatStringsSep "," publicApiLegacyDeps}\njarFile=gradle-public-api-legacy-${version}.jar\n' > $out/lib/api/gradle-public-api-legacy.properties

    ${pomFor "org.gradle" "gradle-kotlin-dsl-extensions"}
    ${
      if kotlinDslExtensions == null then
        "mkdir kext"
      else
        "mkdir kext && (cd kext && unzip -q ${kotlinDslExtensions}/share/java/gradle-kotlin-dsl-extensions.jar -x 'META-INF/MANIFEST.MF')"
    }
    ${gradleJar} $out/lib/gradle-kotlin-dsl-extensions-${version}.jar ${stdAttrs} --attr 'Implementation-Vendor-Id: org.gradle' \
      --root kext --append META-INF/maven/org.gradle/gradle-kotlin-dsl-extensions/pom.properties=pom/gradle-kotlin-dsl-extensions/pom.properties
    printf 'dependencies=\njarFile=gradle-kotlin-dsl-extensions-${version}.jar\n' > $out/lib/gradle-kotlin-dsl-extensions.properties

    ${lib.concatMapStrings (n: ''
      printf 'dependencies=${lib.concatStringsSep "," (distPlatformDeps n)}\n' > $out/${
        # (the core closure before `real`: core-platform itself, jar-less api-metadata)
        if lib.elem n.key (keys (closure runtimeConfs coreRoots)) then "lib" else "lib/plugins"
      }/gradle-${n.name}.properties
    '') platformNodes}
    printf 'dependencies=${lib.concatStringsSep "," distributionsDependenciesDeps}\n' > $out/lib/gradle-distributions-dependencies.properties

    # build receipt (GradleVersion), as in the release
    mkdir -p receipt
    ${
      let
        r = lock.receipt;
        t = r.buildTimestamp;
        iso = "${builtins.substring 0 4 t}-${builtins.substring 4 2 t}-${builtins.substring 6 2 t} ${builtins.substring 8 2 t}\\:${builtins.substring 10 2 t}\\:${builtins.substring 12 2 t} UTC";
      in
      "printf 'baseVersion=${baseVersion}\\nbuildTimestamp=${t}\\nbuildTimestampIso=${iso}\\ncommitId=${r.commitId}\\nisSnapshot=false\\nscriptTemplateCommitId=${r.scriptTemplateCommitId}\\nversionNumber=${versionNumber}\\n' > receipt/build-receipt.properties"
    }
    ${repack "$out/lib/gradle-base-services-${version}.jar" "" "--append org/gradle/build-receipt.properties=receipt/build-receipt.properties"}

    # launchable jars
    ${repack "$out/lib/gradle-gradle-cli-main-${version}.jar" "${classPathAttr lock.classPath.gradle-cli-main} --attr 'Main-Class: org.gradle.launcher.GradleMain' --attr 'Enable-Native-Access: ALL-UNNAMED'" ""}
    ${repack "$out/lib/gradle-daemon-main-${version}.jar" "${classPathAttr lock.classPath.daemon-main} --attr 'Main-Class: org.gradle.launcher.daemon.bootstrap.GradleDaemon'" ""}
    ${repack "$out/lib/gradle-launcher-${version}.jar" "--attr 'Class-Path: gradle-gradle-cli-main-${version}.jar'" ""}
    ${repack "$out/lib/agents/gradle-instrumentation-agent-${version}.jar" "--attr 'Premain-Class: org.gradle.instrumentation.agent.Agent'" ""}

    # start scripts
    mkdir -p $out/bin ss
    mkdir -p ss-src && cp ${./StartScripts.java} ss-src/StartScripts.java
    javac -nowarn -d ss -cp "$(echo $out/lib/*.jar $out/lib/plugins/*.jar | tr ' ' :)" ss-src/StartScripts.java
    t=${gradleSrc}/platforms/jvm/plugins-application/src/main/resources/org/gradle/api/internal/plugins
    java -cp "ss:$(echo $out/lib/*.jar $out/lib/plugins/*.jar | tr ' ' :)" StartScripts $t/unixStartScript.txt $t/windowsStartScript.txt \
      ${lock.receipt.scriptTemplateCommitId} gradle-gradle-cli-main-${version}.jar $out/bin gradle-instrumentation-agent-${version}.jar
    chmod 755 $out/bin/gradle
    runHook postInstall
  '';
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
    echo "plugins=${
      lib.concatStringsSep "," (
        projectJarNames (lib.filter (n: !(lib.elem n.key coreKeys)) apiPluginNodes)
      )
    }" > info/gradle-plugins.properties
    echo "plugins=${lib.concatStringsSep "," (projectJarNames onlyPlugins)}" > info/gradle-implementation-plugins.properties
    jar cf gradle-runtime-api-info-${version}.jar -C info .
    runHook postBuild
  '';
  # (too long for an environment variable)
  jarInstall =
    if upstreamLock != null then
      # (Gradle's own modules; the third-party ones: dist-upstream.py)
      lib.concatMapStrings (install "lib") (lib.filter (n: n.kind == "project") coreNodes)
      + lib.concatMapStrings (install "lib/plugins") (lib.filter (n: n.kind == "project") onlyPlugins)
      + lib.concatMapStrings (install "lib/agents") (lib.filter (n: n.kind == "project") onlyAgents)
    else
    lib.concatMapStrings (install "lib") coreNodes
    + ''
      install -Dm644 ${gradleLibs.ant}/share/java/ant-launcher.jar $out/lib/ant-launcher-${gradleLibs.ant.version}.jar
      printf 'dependencies=\njarFile=ant-launcher-${gradleLibs.ant.version}.jar\n' > $out/lib/ant-launcher.properties
    ''
    + lib.concatMapStrings (install "lib/plugins") onlyPlugins
    + lib.concatMapStrings (install "lib/agents") onlyAgents;
  passAsFile = [ "jarInstall" ] ++ lib.optional (upstreamLock != null) "upstreamConfig";
  ${if upstreamLock != null then "upstreamConfig" else null} = upstreamConfig;
  passthru = lib.optionalAttrs (upstreamLock != null) { inherit upstreamGaps; };
  installPhase =
    if upstreamLock != null then
      upstreamInstall
    else
      ''
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

    ${lib.optionalString (registryStyle == "embedded") ''
      # (GradleCli reads it from its own class loader, which does not see the kotlin-dsl jar)
      mkdir -p regv && echo 'kotlin=${embeddedKotlin}' > regv/gradle-kotlin-dsl-versions.properties
      chmod u+w $out/lib/gradle-gradle-cli-${version}.jar
      jar uf $out/lib/gradle-gradle-cli-${version}.jar -C regv gradle-kotlin-dsl-versions.properties
      mkdir -p regx
      for m in gradle-runtime-api-info gradle-kotlin-dsl-extensions; do
        printf 'projects=\nruntime=\n' > regx/$m-classpath.properties
        chmod u+w $out/lib/plugins/$m-${version}.jar
        jar uf $out/lib/plugins/$m-${version}.jar -C regx $m-classpath.properties
      done
    ''}

    # build receipt (GradleVersion)
    mkdir -p receipt/org/gradle
    cat > receipt/org/gradle/build-receipt.properties <<'EOF2'
    commitId=HEAD
    scriptTemplateCommitId=HEAD
    versionNumber=${versionNumber}
    baseVersion=${baseVersion}
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
