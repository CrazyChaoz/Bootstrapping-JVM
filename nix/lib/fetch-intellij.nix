# Fetch an intellij-community source archive, keeping only the few modules
# needed to build the parts of the IntelliJ SDK that Kotlin depends on, and
# without any of the binary jars that the repository ships.
{ lib, fetchzip }:

{
  rev,
  hash,
  keep ? [
    "build.xml"
    "bin/idea.properties"
    "platform/annotations"
    "platform/boot"
    "platform/core-api"
    "platform/core-impl"
    "platform/extensions"
    "platform/platform-resources"
    "platform/platform-resources-en"
    "platform/util"
    "platform/util-rt"
    "java/java-psi-api"
    "java/java-psi-impl"
    "java/compiler/javac2"
    "java/compiler/instrumentation-util"
    "jps/model-api"
    "jps/model-impl"
  ],
}:

fetchzip {
  name = "intellij-community-${rev}-pruned";
  url = "https://github.com/JetBrains/intellij-community/archive/${rev}.tar.gz";
  inherit hash;
  postFetch = ''
    mv $out $TMPDIR/full
    mkdir -p $out
    cd $TMPDIR/full
    for p in ${lib.escapeShellArgs keep}; do
      if [ -e "$p" ]; then
        cp -r --parents "$p" $out/
      fi
    done
    cd $out
    find . -type f \( -name '*.jar' -o -name '*.class' -o -name '*.so' -o -name '*.dll' \
      -o -name '*.dylib' -o -name '*.exe' -o -name '*.zip' -o -name '*.a' \) -delete
    rm -rf $TMPDIR/full
  '';
}
