# Old protobuf releases: protoc (C++) and the Java runtime generated with it.
{
  lib,
  stdenv,
  fetchurl,
  mkJar,
}:

let
  mkProtoc =
    { version, hash }:
    stdenv.mkDerivation {
      pname = "protoc";
      inherit version;
      src = fetchurl {
        url = "https://github.com/protocolbuffers/protobuf/releases/download/v${version}/protobuf-${version}.tar.bz2";
        inherit hash;
      };
      # Ancient C++; keep the compiler quiet and in an old dialect.
      env.NIX_CFLAGS_COMPILE = "-std=gnu++98 -Wno-error -fpermissive";
      configureFlags = [ "--disable-shared" ];
      enableParallelBuilding = true;
      doCheck = false;
    };

  mkJava =
    {
      protoc,
      relocate ? null,
    }:
    mkJar {
      pname = "protobuf-java" + lib.optionalString (relocate != null) "-relocated";
      inherit (protoc) version src;
      sourceDirs = [ "java/src/main/java" ];
      javaRelease = "1.6";
      preBuild = ''
        ${protoc}/bin/protoc --java_out=java/src/main/java --proto_path=src \
          src/google/protobuf/descriptor.proto
      ''
      + lib.optionalString (relocate != null) ''
        find java/src/main/java -name '*.java' -exec sed -i -E \
          's/([^[:alnum:]])com\.google\.protobuf([^[:alnum:]])/\1${relocate}\2/g' {} +
      '';
      passthru = { inherit protoc; };
    };
in
rec {
  protoc-2_5 = mkProtoc {
    version = "2.5.0";
    hash = "sha256-E7/FrlQ886oYCsJIXAvIlJXjrnEfxvq0+P/pDftLtnc=";
  };
  protoc-2_6 = mkProtoc {
    version = "2.6.1";
    hash = "sha256-7kRWEtVE2IWuJA/7y/kmf6qfWTt7EB8h1Yvs65JmGRA=";
  };

  # Latest version not requiring clients to know about StringLists (TarCV)
  java-2_5 = mkJava { protoc = protoc-2_5; };
  # Kotlin >= 1.1.0-dev-2022 uses a relocated protobuf 2.6.1
  java-2_6-kotlin = mkJava {
    protoc = protoc-2_6;
    relocate = "org.jetbrains.kotlin.protobuf";
  };
}
