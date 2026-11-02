# IcedTea 2.6 (OpenJDK 7), built with JamVM + GNU Classpath + ECJ 4.
# Port of Guix' icedtea-7.
{
  lib,
  gcc13Stdenv,
  fetchurl,
  jdkBootstrap,
  pkg-config,
  zip,
  unzip,
  cpio,
  which,
  regexEdit,
  python3,
  procps,
  wget,
  libxslt,
  attr,
  file,
  gawk,
  libtool,
  fastjar,
  alsa-lib,
  cups,
  fontconfig,
  freetype,
  giflib,
  gtk2,
  lcms2,
  libjpeg_turbo,
  libpng,
  libx11,
  libxcomposite,
  libxi,
  libxinerama,
  libxrender,
  libxt,
  libxtst,
  libxext,
  xorgproto,
  krb5,
  nss,
  pcsclite,
  zlib,
}:

let
  version = "2.6.13";
  drop =
    name: hash:
    fetchurl {
      url = "http://icedtea.classpath.org/download/drops/icedtea7/${version}/${name}.tar.bz2";
      inherit hash;
    };
  drops = {
    corba = drop "corba" "sha256-3xFUkVytMXuTVVtWP8EqytG5Ll8ocGQnNvGGt6TYDxQ=";
    jaxp = drop "jaxp" "sha256-FDpblX+7AIif+dOKS/ORIYeGtqM2ZCNSee27bnmj3sw=";
    jaxws = drop "jaxws" "sha256-0+PVXW4iMcRCDTDRJPcsVmldReijmOPMe6If8qk8EoQ=";
    jdk = drop "jdk" "sha256-rb2pPR6b6JRH4AlzOmyQUMbmzr2jxnSnbrvriYZiNTQ=";
    langtools = drop "langtools" "sha256-EgNrmF+IEc2t9tW/hA+QurJfTaHMPoa6ucP278wQBVs=";
    hotspot = drop "hotspot" "sha256-muPW1D/3cc8CuMeAWsDwpFf1+nAmsTNOoQhSYtPYbZ0=";
  };
  dropPatches = {
    jdk = [ ../../patches/guix/jdk-currency-time-bomb.patch ];
    hotspot = [
      ../../patches/guix/icedtea-7-hotspot-aarch64-use-c++98.patch
      ../../patches/guix/icedtea-7-hotspot-pointer-comparison.patch
    ];
  };
  openjdk-src = drop "openjdk" "sha256-FKn5Di/lwLtz3I/8yepdx20856dKDJAc/QsK4/yMZFA=";

  inherit (jdkBootstrap)
    jamvm-with-ecj4
    ecj4-javac-wrapper
    classpath-devel
    ant-bootstrap
    ;
  jamvm = jamvm-with-ecj4;
  xlibs = [
    libx11
    libxcomposite
    libxi
    libxinerama
    libxrender
    libxt
    libxtst
    libxext
    xorgproto
  ];
in
gcc13Stdenv.mkDerivation {
  pname = "icedtea";
  inherit version;

  src = fetchurl {
    url = "http://icedtea.wildebeest.org/download/source/icedtea-${version}.tar.xz";
    hash = "sha256-EE6EIF0RduIX4k93B4TFPRzWZq6yOrC66KyFjlsOY/A=";
  };

  nativeBuildInputs = [
    pkg-config
    zip
    unzip
    cpio
    which
    regexEdit
    procps
    wget
    libxslt
    file
    gawk
    libtool
    fastjar
    ant-bootstrap
    ecj4-javac-wrapper
    jamvm
    classpath-devel
  ];
  buildInputs = [
    attr
    alsa-lib
    cups
    fontconfig
    freetype
    giflib
    gtk2
    lcms2
    libjpeg_turbo
    libpng
    krb5
    nss
    pcsclite
    zlib
  ]
  ++ xlibs;

  hardeningDisable = [ "all" ];

  postUnpack = ''
    cd $sourceRoot
    mkdir openjdk.src
    tar xf ${openjdk-src} -C openjdk.src --strip-components=1
    ${lib.concatStrings (
      lib.mapAttrsToList (name: tarball: ''
        rm -rf openjdk.src/${name}; mkdir openjdk.src/${name}
        tar xf ${tarball} -C openjdk.src/${name} --strip-components=1
        ${lib.concatMapStrings (p: "patch -d openjdk.src/${name} -p1 < ${p}\n") (
          dropPatches.${name} or [ ]
        )}
      '') drops
    )}
    cd ..
  '';

  postPatch = ''
    # the bootstrap JDK's javac (an ecj wrapper) and javah: Python ports of IcedTea's Perl scripts
    substitute ${../../patches/own/icedtea-javac.in} javac.in --replace-fail @PYTHON3@ ${python3.interpreter}
    substitute ${../../patches/own/icedtea-javah.in} javah.in --replace-fail @PYTHON3@ ${python3.interpreter}

    # do not leak information about the build host
    substituteInPlace Makefile.in --replace-quiet 'DISTRIBUTION_ID="$(DIST_ID)"' 'DISTRIBUTION_ID="\"nix\""'

    # use-classpath: GNU Classpath does not provide rt.jar, but jamvm provides
    # Classpath's glibj.zip as rt.jar.
    substituteInPlace Makefile.in --replace-fail '$(SYSTEM_JDK_DIR)/jre/lib/rt.jar' ${jamvm}/lib/rt.jar

    # patch-bitrot
    sed -i 's/REQUIRED_FREETYPE_VERSION = 2.2.1/REQUIRED_FREETYPE_VERSION = 2.10.1/' \
      patches/boot/revert-6973616.patch openjdk.src/jdk/make/common/shared/Defs-versions.gmk
    sed -i 's|attr/xattr.h|sys/xattr.h|' configure \
      openjdk.src/jdk/src/solaris/native/sun/nio/fs/LinuxNativeDispatcher.c

    cd openjdk.src
    # fix-openjdk
    sed -i 's/^CFLAGS_COMMON   = -fno-strict-aliasing/& -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types -Wno-error=int-conversion/' \
      jdk/make/common/Defs-linux.gmk
    sed -i 's|#include <sys/sysctl.h>|#include <linux/sysctl.h>|' \
      jdk/src/solaris/native/java/net/PlainSocketImpl.c \
      jdk/src/solaris/native/java/net/PlainDatagramSocketImpl.c
    sed -i 's/$(LDD) $1 &&//' jdk/make/common/shared/Defs-linux.gmk
    sed -i 's|^\(OPT_CFLAGS/NOOPT.*\)$|\1\nOPT_CFLAGS/dump.o += -O0|' hotspot/make/linux/makefiles/gcc.make

    # fix-x11-extension-include-path
    regex-edit '\$\(firstword \$\(wildcard \$\(OPENWIN_HOME\)/include/X11/extensions\) \\\n\s*\$\(wildcard /usr/include/X11/extensions\)\)' '${lib.getDev libxrender}/include/X11/extensions -I${lib.getDev libxtst}/include/X11/extensions -I${lib.getDev libxinerama}/include/X11/extensions' \
      jdk/make/sun/awt/mawt.gmk
    grep -n 'include/X11/extensions' jdk/make/sun/awt/mawt.gmk

    # patch-paths
    sed -i "s|/bin/sh|$(type -p bash)|" hotspot/make/linux/makefiles/buildtree.make
    corebin=$(dirname $(type -p cp))
    for f in jdk/make/common/shared/Defs-linux.gmk corba/make/common/shared/Defs-linux.gmk; do
      sed -i -e "s|UNIXCOMMAND_PATH  = /bin|UNIXCOMMAND_PATH = $corebin|" \
             -e "s|USRBIN_PATH  = /usr/bin|USRBIN_PATH = $corebin|" \
             -e "s|DEVTOOLS_PATH *= */usr/bin|DEVTOOLS_PATH = $corebin|" \
             -e "s|COMPILER_PATH *= */usr/bin|COMPILER_PATH = $(dirname $(type -p gcc))|" \
             -e "s|DEF_OBJCOPY *=.*objcopy|DEF_OBJCOPY = $(type -p objcopy)|" $f
    done
    sed -i "s|ALSA_INCLUDE=/usr/include/alsa/version.h|ALSA_INCLUDE=${lib.getDev alsa-lib}/include/alsa/version.h|" \
      jdk/make/common/shared/Sanity.gmk
    for f in jdk/make/common/shared/Defs-utils.gmk corba/make/common/shared/Defs-utils.gmk; do
      sed -i -E \
        -e "s|ECHO *=.*echo|ECHO = $corebin/echo|" \
        -e "s|^GREP *=.*grep|GREP = $(type -p grep)|" \
        -e "s|EGREP *=.*egrep|EGREP = $(type -p grep) -E|" \
        -e "s|CPIO *=.*cpio|CPIO = $(type -p cpio)|" \
        -e "s|READELF *=.*readelf|READELF = $(type -p readelf)|" \
        -e "s|^ *AR *=.*ar|AR = $(type -p ar)|" \
        -e "s|^ *TAR *=.*tar|TAR = $(type -p tar)|" \
        -e "s|AS *=.*as|AS = $(type -p as)|" \
        -e "s|LD *=.*ld|LD = $(type -p ld)|" \
        -e "s|STRIP *=.*strip|STRIP = $(type -p strip)|" \
        -e "s|NM *=.*nm|NM = $(type -p nm)|" \
        -e "s|^SH *=.*sh|SH = $(type -p bash)|" \
        -e "s|^FIND *=.*find|FIND = $(type -p find)|" \
        -e "s|LDD *=.*ldd|LDD = $(type -p ldd || echo true)|" \
        -e "s#NAWK *=.*(n|g)awk#NAWK = $(type -p gawk)#" \
        -e "s|XARGS *=.*xargs|XARGS = $(type -p xargs)|" \
        -e "s|UNZIP *=.*unzip|UNZIP = $(type -p unzip)|" \
        -e "s|ZIPEXE *=.*zip|ZIPEXE = $(type -p zip)|" \
        -e "s|SED *=.*sed|SED = $(type -p sed)|" $f
    done
    # Some of these timestamps cause problems as they are more than 10 years
    # ago, failing the build process.
    sed -i -e 's/AZ=AZM;2005-12-31-20-00-00;AZN/AZ=AZN/' -e 's/MZ=MZM;2006-06-30-22-00-00;MZN/MZ=MZN/' \
           -e 's/RO=ROL;2005-06-30-21-00-00;RON/RO=RON/' -e 's/TR=TRL;2004-12-31-22-00-00;TRY/TR=TRY/' \
      jdk/src/share/classes/java/util/CurrencyData.properties
    cd ..
  '';

  preConfigure = ''
    export CLASSPATH=${jamvm}/lib/rt.jar:${classpath-devel}/share/classpath/tools.zip
    export JAVACFLAGS="-cp $CLASSPATH"
    export CC=gcc
    export CPATH=${
      lib.concatMapStringsSep ":" (l: "${lib.getDev l}/include/X11/extensions") [
        libxcomposite
        libxrender
        libxtst
        libxinerama
      ]
    }''${CPATH:+:$CPATH}
    export ALT_OBJCOPY=$(type -p objcopy)
    export ALT_CUPS_HEADERS_PATH=${lib.getDev cups}/include
    export ALT_FREETYPE_HEADERS_PATH=${lib.getDev freetype}/include
    export ALT_FREETYPE_LIB_PATH=${lib.getLib freetype}/lib
    export HOME=$TMPDIR
    # configure insists on perl, which (javac.in being Python) only the systemtap tapset
    # tests use, not run here
    export PERL=$(type -P false)
    configureFlagsArray+=(--with-parallel-jobs=$NIX_BUILD_CORES)
  '';

  configureFlags = [
    "--disable-system-sctp"
    "--enable-system-pcsc"
    "--enable-system-lcms"
    "--enable-bootstrap"
    "--enable-nss"
    "--without-rhino"
    "--disable-downloading"
    "--disable-tests"
    "--disable-docs"
    "--with-openjdk-src-dir=./openjdk.src"
    "--with-ecj=${ecj4-javac-wrapper}/bin/javac"
    "--with-jdk-home=${classpath-devel}"
    "--with-java=${jamvm}/bin/jamvm"
    "--with-jar=${classpath-devel}/bin/gjar"
  ];

  preBuild = ''
    export DISABLE_HOTSPOT_OS_VERSION_CHECK=ok
  '';
  configurePlatforms = [ ];
  enableParallelBuilding = false;

  installPhase = ''
    runHook preInstall
    cp -r openjdk.build/j2sdk-image $out
    # Some of the libraries in lib/amd64 link to libjvm.so, which lives in
    # the server/ folder.
    ln -s server/libjvm.so $out/jre/lib/amd64/libjvm.so
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "OpenJDK 7 built with IcedTea from a JamVM/GNU Classpath bootstrap";
    license = lib.licenses.gpl2Plus;
  };
}
