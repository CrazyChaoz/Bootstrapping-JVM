# Fetch a Kotlin source archive from GitHub, without the binary jars (and other
# binaries) that the repository ships.
{ fetchzip }:

{ rev, hash }:

fetchzip {
  name = "kotlin-${rev}";
  url = "https://github.com/JetBrains/kotlin/archive/refs/tags/${rev}.tar.gz";
  inherit hash;
  postFetch = ''
    find $out -type f \( -name '*.jar' -o -name '*.class' -o -name '*.so' -o -name '*.dll' \
      -o -name '*.dylib' -o -name '*.exe' -o -name '*.zip' -o -name '*.a' -o -name '*.jnilib' \) -delete
  '';
}
