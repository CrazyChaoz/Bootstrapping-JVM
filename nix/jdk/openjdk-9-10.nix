# OpenJDK 9 and 10, ports of Guix' openjdk9/openjdk10 (each built with the
# previous JDK).  nixpkgs has no recipes for these versions.
{
  lib,
  gcc13Stdenv,
  fetchzip,
  gnumake42,
  autoconf,
  zip,
  unzip,
  which,
  file,
  cpio,
  perl,
  alsa-lib,
  cups,
  fontconfig,
  freetype,
  giflib,
  gtk3,
  lcms2,
  elfutils,
  libjpeg_turbo,
  libpng,
  xorg,
  zlib,
}:

let
  p = n: ../../patches/guix + "/${n}.patch";

  mkOpenjdk =
    {
      version,
      tag,
      hash,
      patches,
      bootJdk,
      layout, # "forest" (9: hotspot/src/...) or "consolidated" (10: src/hotspot)
    }:
    gcc13Stdenv.mkDerivation {
      pname = "openjdk";
      inherit version;
      src = fetchzip {
        name = "openjdk-${version}-src";
        url = "https://github.com/openjdk/jdk/archive/refs/tags/${tag}.tar.gz";
        inherit hash;
        postFetch = ''
          find $out -type f \( -name '*.bin' -o -name '*.exe' -o -name '*.jar' \) -delete
        '';
      };
      inherit patches;

      nativeBuildInputs = [
        gnumake42
        autoconf
        zip
        unzip
        which
        file
        cpio
        perl
      ];
      buildInputs = [
        alsa-lib
        cups
        fontconfig
        freetype
        giflib
        gtk3
        lcms2
        elfutils
        libjpeg_turbo
        libpng
        zlib
      ]
      ++ (with xorg; [
        libICE
        libX11
        libXcomposite
        libXi
        libXinerama
        libXrender
        libXt
        libXtst
        libXext
        libXrandr
        xorgproto
      ]);

      hardeningDisable = [ "all" ];
      dontAddDisableDepTrackingFlag = true;
      configurePlatforms = [ ];
      enableParallelBuilding = true;

      postPatch = ''
        patchShebangs --build configure
        chmod +x configure
        # This file was "fixed" by patchShebangs, but it requires this exact
        # first line.
        f=$(find make -name blacklisted.certs.pem | head -1)
        [ -n "$f" ] && sed -i '1s|^#!.*|#! java BlacklistedCertsConverter SHA-256|' $f || true
      ''
      + lib.optionalString (layout == "consolidated") ''
        sed -i 's/__DATE__//; s/__TIME__//' src/hotspot/share/runtime/vm_version.cpp
        sed -i 's/-Werror//g' make/autoconf/generated-configure.sh
      '';

      configurePhase = ''
        runHook preConfigure
        export HOME=$TMPDIR
        bash ./configure \
          --with-extra-cflags="-fcommon -fno-delete-null-pointer-checks -fno-lifetime-dse -Wno-error=int-conversion" \
          --with-boot-jdk=${bootJdk.home or bootJdk} \
          --with-freetype=${lib.getDev freetype} \
          --with-freetype-include=${lib.getDev freetype}/include/freetype2 \
          --with-freetype-lib=${lib.getLib freetype}/lib \
          --disable-freetype-bundling \
          --disable-warnings-as-errors \
          --disable-hotspot-gtest \
          --with-giflib=system \
          --with-libjpeg=system \
          --with-zlib=system \
          --with-native-debug-symbols=none \
          --with-x=${lib.getDev xorg.libX11} \
          --x-includes=${lib.getDev xorg.libX11}/include \
          --x-libraries=${lib.getLib xorg.libX11}/lib \
          --with-cups=${lib.getDev cups} \
          --with-alsa=${lib.getDev alsa-lib} \
          --with-fontconfig=${lib.getDev fontconfig} \
          --prefix=$out
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        echo ${version} > .src-rev
        make JOBS=$NIX_BUILD_CORES images
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        images=$(echo build/*-release/images)
        cp -r $images/jdk $out
        ln -s server/libjvm.so $out/lib/libjvm.so
        rm -f $out/lib/src.zip
        runHook postInstall
      '';

      dontStrip = true;
      dontPatchELF = true;

      meta.license = lib.licenses.gpl2Plus;
    };
in
{
  inherit mkOpenjdk;
  openjdk9 =
    bootJdk:
    mkOpenjdk {
      version = "9.181";
      tag = "jdk-9+181";
      hash = "sha256-mR8UKV1oOa9qRPSxZDbbnzqRfIHxVSF/JlYI6WPbraM=";
      layout = "forest";
      inherit bootJdk;
      patches = map p [
        "openjdk-9-pointer-comparison"
        "openjdk-9-classlist-reproducibility"
        "openjdk-currency-time-bomb"
        "openjdk-9-jar-reproducibility"
        "openjdk-9-module-reproducibility"
        "openjdk-9-module2-reproducibility"
        "openjdk-9-module3-reproducibility"
        "openjdk-9-idlj-reproducibility"
        "openjdk-9-setsignalhandler"
      ];
    };
  openjdk10 =
    bootJdk:
    mkOpenjdk {
      version = "10.46";
      tag = "jdk-10+46";
      hash = "sha256-eT57+hiKUKd6PEIlT8mCS3T7cDejIFbD0Qi2XdniUIk=";
      layout = "consolidated";
      inherit bootJdk;
      patches = map p [
        "openjdk-10-char-reproducibility"
        "openjdk-10-classlist-reproducibility"
        "openjdk-10-corba-reproducibility"
        "openjdk-10-idlj-reproducibility"
        "openjdk-10-module-reproducibility"
        "openjdk-10-module3-reproducibility"
        "openjdk-10-module4-reproducibility"
        "openjdk-10-jar-reproducibility"
        "openjdk-10-jtask-reproducibility"
        "openjdk-10-pointer-comparison"
        "openjdk-10-setsignalhandler"
        "openjdk-currency-time-bomb2"
      ];
    };
}
