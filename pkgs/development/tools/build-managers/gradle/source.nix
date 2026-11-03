# The Gradle source tree, without the binary jars (wrapper, test fixtures, ...) it ships.
{
  fetchzip,
  version ? "9.8.0",
  hash ? "sha256-5KRHOveEOeA11TZGbUi8etSd7av9Tt6fe7u4TeRQkbQ=",
}:

fetchzip {
  name = "gradle-${version}-src";
  url = "https://github.com/gradle/gradle/archive/refs/tags/v${version}.tar.gz";
  inherit hash;
  postFetch = ''
    find $out -type f \( -name '*.jar' -o -name '*.class' -o -name '*.so' -o -name '*.dll' \
      -o -name '*.dylib' -o -name '*.exe' -o -name '*.zip' -o -name '*.a' -o -name '*.jnilib' \
      -o -name '*.war' -o -name '*.ear' -o -name '*.dex' \) -delete
  '';
}
