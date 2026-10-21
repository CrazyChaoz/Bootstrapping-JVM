# Apache Ant built from source with its bootstrap script (only needs javac).
# Optional tasks whose dependencies are absent are skipped by build.xml.
{
  lib,
  stdenv,
  fetchurl,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  version ? "1.9.16",
  hash ? "sha256-H0w3bd4Z374/ABf1FjdQtZV4p4DiGar2J6sRAbTnIPw=",
}:

stdenv.mkDerivation {
  pname = "ant";
  inherit version;

  src = fetchurl {
    url = "https://archive.apache.org/dist/ant/source/apache-ant-${version}-src.tar.gz";
    inherit hash;
  };

  nativeBuildInputs = [
    jdk
    zip
    unzip
    stripJavaArchivesHook
  ];

  postPatch = ''
    find . -name '*.jar' -print -delete
    # Tests need hamcrest/junit, which need ant.
    substituteInPlace build.xml --replace-quiet 'depends="jars,test-jar' 'depends="jars'
    patchShebangs .
  '';

  buildPhase = ''
    runHook preBuild
    export JAVA_HOME=${jdk.home or jdk}
    sh ./bootstrap.sh -Ddist.dir=$PWD/dist dist-lite
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/ant $out/bin $out/share/java
    cp -r dist/lib $out/share/ant/lib
    mkdir -p $out/share/ant/bin
    cp src/script/antRun $out/share/ant/bin/ 2>/dev/null || true
    chmod +x $out/share/ant/bin/* || true
    ln -s $out/share/ant/lib $out/lib
    for j in ant.jar ant-launcher.jar; do ln -s ../ant/lib/$j $out/share/java/$j; done

    cat > $out/bin/ant <<EOF
    #!${stdenv.shell} -e
    export ANT_HOME=$out/share/ant
    : \''${JAVA_HOME:=${jdk.home or jdk}}
    export JAVA_HOME
    exec \$JAVA_HOME/bin/java \$ANT_OPTS -classpath $out/share/ant/lib/ant-launcher.jar \\
      -Dant.home=$out/share/ant -Dant.library.dir=$out/share/ant/lib \\
      org.apache.tools.ant.launch.Launcher \$ANT_ARGS -cp "\$CLASSPATH" "\$@"
    EOF
    chmod +x $out/bin/ant
    runHook postInstall
  '';

  passthru.home = "share/ant";

  meta = {
    description = "Java build tool (built from source)";
    license = lib.licenses.asl20;
  };
}
