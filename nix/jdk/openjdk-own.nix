# OpenJDK versions that nixpkgs has no recipe for (9, 10, 12-16, 18-20),
# needed because each OpenJDK must be built with the previous (or same)
# version.  After Guix' openjdk9 ... openjdk20.  Sources are the GA tags of
# the openjdk/jdk GitHub repository.
{
  lib,
  gcc13Stdenv,
  fetchzip,
  gnumake42,
  gnumake,
  autoconf,
  zip,
  unzip,
  which,
  file,
  cpio,
  perl,
  bash,
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
      patches ? [ ],
      bootJdk,
      feature, # major version as integer
    }:
    let
      consolidated = feature >= 10;
      certsPem =
        if feature >= 19 then
          "src/java.base/share/data/blockedcertsconverter/blocked.certs.pem"
        else if feature >= 17 then
          "make/data/blockedcertsconverter/blocked.certs.pem"
        else if feature >= 11 && feature < 12 then
          "make/data/blockedcertsconverter/blocked.certs.pem"
        else
          null;
    in
    gcc13Stdenv.mkDerivation {
      pname = "openjdk";
      inherit version patches;
      src = fetchzip {
        name = "openjdk-${version}-src";
        url = "https://github.com/openjdk/jdk/archive/refs/tags/${tag}.tar.gz";
        inherit hash;
        postFetch = ''
          find $out -type f \( -name '*.bin' -o -name '*.exe' -o -name '*.jar' \) -delete
        '';
      };

      nativeBuildInputs = [
        (if feature < 15 then gnumake42 else gnumake)
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
        libXcursor
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
      configurePlatforms = [ ];
      enableParallelBuilding = true;

      postPatch = ''
        patchShebangs --build configure make
        chmod +x configure
        # These files were "fixed" by patchShebangs, but require this exact
        # first line.
        for f in $(find make src -name 'blacklisted.certs.pem' -o -name 'blocked.certs.pem' 2>/dev/null); do
          case $f in
            *blacklisted*) sed -i '1s|^#!.*|#! java BlacklistedCertsConverter SHA-256|' $f ;;
            *) sed -i '1s|^#!.*|#! java BlockedCertsConverter SHA-256|' $f ;;
          esac
        done
        # The m4 macro uses 'help' to search for builtins.
        if [ -f make/autoconf/basics.m4 ]; then sed -i 's/if help/if command -v/' make/autoconf/basics.m4; fi
      ''
      + lib.optionalString consolidated ''
        for f in src/hotspot/share/runtime/vm_version.cpp src/hotspot/share/runtime/abstract_vm_version.cpp; do
          [ -f $f ] && sed -i 's/__DATE__//; s/__TIME__//' $f
        done
        [ -f make/autoconf/generated-configure.sh ] && sed -i 's/-Werror//g' make/autoconf/generated-configure.sh || true
      '';

      configurePhase = ''
        runHook preConfigure
        export HOME=$TMPDIR
        bash ./configure \
          --with-extra-cflags="-fcommon -fno-delete-null-pointer-checks -fno-lifetime-dse -Wno-error=int-conversion" \
          --with-boot-jdk=${bootJdk.home or bootJdk} \
          --with-freetype-include=${lib.getDev freetype}/include/freetype2 \
          --with-freetype-lib=${lib.getLib freetype}/lib \
          ${lib.optionalString (feature < 11) "--with-freetype=${lib.getDev freetype} --disable-freetype-bundling"} \
          --disable-warnings-as-errors \
          ${if feature >= 15 then "--without-gtest" else "--disable-hotspot-gtest"} \
          --with-giflib=system \
          --with-libjpeg=system \
          ${lib.optionalString (feature >= 11) "--with-libpng=system --with-lcms=system --with-version-pre="} \
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

      passthru = { inherit feature; };
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
      feature = 9;
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
      feature = 10;
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

  openjdk12 =
    bootJdk:
    mkOpenjdk {
      version = "12.33";
      tag = "jdk-12+33";
      hash = "sha256-NtaVeRiM2BcDVDZ9mWK4qMTRyp3GL1/U7A18iECzwNg=";
      feature = 12;
      inherit bootJdk;
      patches = map p [ "openjdk-10-setsignalhandler" ];
    };
  openjdk13 =
    bootJdk:
    mkOpenjdk {
      version = "13.33";
      tag = "jdk-13+33";
      hash = "sha256-CnBRE39WzRSTSdReg71C+qRNeIEKAL6KWvnzQERAi6o=";
      feature = 13;
      inherit bootJdk;
    };
  openjdk14 =
    bootJdk:
    mkOpenjdk {
      version = "14.36";
      tag = "jdk-14+36";
      hash = "sha256-oAsvP7kvOc6sMkz4rjgCKKwHLkdqgrbib+Hess+qGVc=";
      feature = 14;
      inherit bootJdk;
      patches = map p [ "openjdk-10-setsignalhandler" ];
    };
  openjdk15 =
    bootJdk:
    mkOpenjdk {
      version = "15.36";
      tag = "jdk-15+36";
      hash = "sha256-foxh3dRghPr2H6X4qlX7bpw9mMujH8ZYK0teao8ZYv8=";
      feature = 15;
      inherit bootJdk;
    };
  openjdk16 =
    bootJdk:
    mkOpenjdk {
      version = "16.36";
      tag = "jdk-16+36";
      hash = "sha256-7pVPQMw2TtCBR0TyBLWTzrmMTU8e5kGwlww9ACfCsc8=";
      feature = 16;
      inherit bootJdk;
      patches = map p [ "openjdk-10-setsignalhandler" ];
    };
  openjdk18 =
    bootJdk:
    mkOpenjdk {
      version = "18.36";
      tag = "jdk-18+36";
      hash = "sha256-5lGlsUd2MM59dtVNaH24qATgrCfSZrmCP4T8gYuDXdg=";
      feature = 18;
      inherit bootJdk;
    };
  openjdk19 =
    bootJdk:
    mkOpenjdk {
      version = "19.36";
      tag = "jdk-19+36";
      hash = "sha256-Hm7bKRayvwv1WN/ViHjffpzoUX1FvX7ue2CbXT6E5T0=";
      feature = 19;
      inherit bootJdk;
    };
  openjdk20 =
    bootJdk:
    mkOpenjdk {
      version = "20.36";
      tag = "jdk-20+36";
      hash = "sha256-qNIi0it85NXu92GI56otBHhU/napZVoGK3zLLy9OypY=";
      feature = 20;
      inherit bootJdk;
    };
}
