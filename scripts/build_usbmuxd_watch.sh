#!/bin/bash
# Builds the usbmuxd_watch binary of the mac-devices role from roles/mac-devices/files/usbmuxd_watch.c
# and the pinned release tarballs of libplist, libimobiledevice-glue and libusbmuxd: a universal
# (arm64 + x86_64) binary for macOS 13.0+, the libraries are linked statically.
# The build is reproducible: the same Xcode builds the same binary byte for byte.
# Usage: scripts/build_usbmuxd_watch.sh [output], by default the binary of the role is replaced.
# Needs macOS with the Xcode command line tools and curl.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${REPO}/roles/mac-devices/files/usbmuxd_watch.c"
OUTPUT="${1:-${REPO}/roles/mac-devices/files/usbmuxd_watch}"
MACOS_MIN=13.0
# <name> <version> <sha256> of the release tarballs of github.com/libimobiledevice, in the build order
LIBRARIES=(
  "libplist 2.7.0 7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b"
  "libimobiledevice-glue 1.3.2 6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774"
  "libusbmuxd 2.1.1 5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce"
)
# <arch> <configure host> of the slices
SLICES=("arm64 aarch64-apple-darwin" "x86_64 x86_64-apple-darwin")

if [[ "$(uname)" != Darwin ]]; then
  echo "usbmuxd_watch is a macOS binary, build it on macOS" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
JOBS="$(sysctl -n hw.ncpu)"
# the archives get no timestamps
export ZERO_AR_DATE=1

# fetch <name> <version> <sha256>: downloads and checks the release tarball into ${WORK}/<name>-<version>.tar.bz2
fetch() {
  local tarball="${WORK}/${1}-${2}.tar.bz2"
  curl --fail --silent --show-error --location --retry 3 --output "$tarball" \
    "https://github.com/libimobiledevice/${1}/releases/download/${2}/${1}-${2}.tar.bz2"
  echo "${3}  ${tarball}" | shasum --algorithm 256 --check --status || {
    echo "${1}-${2}.tar.bz2: unexpected sha256" >&2
    exit 1
  }
}

# build_library <arch> <host> <name> <version>: builds and installs the static library into ${WORK}/<arch>
build_library() {
  local arch="$1" name="$3" version="$4"
  local prefix="${WORK}/${arch}" src="${WORK}/src-${arch}/${3}-${4}"
  local options=(
    CC="clang -arch ${arch} -mmacosx-version-min=${MACOS_MIN}"
    # no paths of the build directory in the binary
    CFLAGS="-O2 -ffile-prefix-map=${WORK}=."
    # the flags of the dependencies, so pkg-config is not needed and no other copy of them is picked up
    "libplist_CFLAGS=-I${prefix}/include" "libplist_LIBS=-L${prefix}/lib -lplist-2.0"
    "limd_glue_CFLAGS=-I${prefix}/include" "limd_glue_LIBS=-L${prefix}/lib -limobiledevice-glue-1.0"
    --host="$2" --prefix="$prefix" --disable-shared --enable-static --disable-dependency-tracking
  )
  if [[ "$name" == libplist ]]; then
    options+=(--without-cython --without-tests)
  fi
  echo "==> ${arch}: ${name} ${version}"
  mkdir -p "${src%/*}"
  tar -xjf "${WORK}/${name}-${version}.tar.bz2" -C "${src%/*}"
  (
    cd "$src"
    ./configure "${options[@]}" > configure.log 2>&1 || {
      cat configure.log >&2
      exit 1
    }
    make -j"$JOBS" install > make.log 2>&1 || {
      tail -50 make.log >&2
      exit 1
    }
  )
}

# build_slice <arch> <host>: builds the libraries and links ${WORK}/usbmuxd_watch.<arch>
build_slice() {
  local arch="$1" prefix="${WORK}/${1}" library
  for library in "${LIBRARIES[@]}"; do
    # <name> <version>, the sha256 is dropped
    # shellcheck disable=SC2086
    build_library "$arch" "$2" ${library% *}
  done
  echo "==> ${arch}: usbmuxd_watch"
  # -Wl,-S: no debug map with the paths of the object files
  clang -arch "$arch" -mmacosx-version-min="$MACOS_MIN" -O2 -Wl,-S -I"${prefix}/include" "$SOURCE" \
    "${prefix}/lib/libusbmuxd-2.0.a" "${prefix}/lib/libimobiledevice-glue-1.0.a" "${prefix}/lib/libplist-2.0.a" \
    -o "${WORK}/usbmuxd_watch.${arch}"
}

for library in "${LIBRARIES[@]}"; do
  # <name> <version> <sha256> are the arguments
  # shellcheck disable=SC2086
  fetch $library
done
slices=()
for slice in "${SLICES[@]}"; do
  # <arch> <host> are the arguments
  # shellcheck disable=SC2086
  build_slice $slice
  slices+=("${WORK}/usbmuxd_watch.${slice%% *}")
done
lipo -create "${slices[@]}" -output "$OUTPUT"
echo "==> ${OUTPUT}: $(lipo -archs "$OUTPUT"), $(clang --version | head -1)"
