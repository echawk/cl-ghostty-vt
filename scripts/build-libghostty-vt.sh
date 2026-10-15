#!/usr/bin/env sh
# Fetch a pinned Ghostty commit plus Zig 0.16.0, build libghostty-vt, and
# install the shared library and headers into <project>/build/.
#
# Everything downloaded or cached lives in <project>/.deps/. Re-running is
# cheap: finished steps are detected and skipped. Set FORCE=1 to rebuild.
#
# Environment overrides:
#   GHOSTTY_REPO     git URL of Ghostty (default: upstream GitHub)
#   GHOSTTY_COMMIT   commit to build (default: the pinned commit below)
#   ZIG              use this zig 0.16.x binary instead of downloading one
#   OPTIMIZE         Zig optimize mode (default: ReleaseFast)
set -eu

GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/ghostty-org/ghostty.git}"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-22fa134a07f5749edd9e92c6bc17d8aaf61843be}"
ZIG_VERSION=0.16.0
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"

root=$(cd "$(dirname "$0")/.." && pwd)
deps="$root/.deps"
prefix="$root/build"
mkdir -p "$deps"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$2" "$1"
  else wget -O "$2" "$1"; fi
}

# --- Zig ------------------------------------------------------------------
# SHA-256 values published at https://ziglang.org/download/index.json
os=$(uname -s); arch=$(uname -m)
case "$os-$arch" in
  Linux-x86_64)               zig_triple=x86_64-linux
    zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
  Linux-aarch64|Linux-arm64)  zig_triple=aarch64-linux
    zig_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
  Darwin-arm64|Darwin-aarch64) zig_triple=aarch64-macos
    zig_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
  Darwin-x86_64)              zig_triple=x86_64-macos
    zig_sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
  *) die "unsupported platform $os-$arch (set ZIG=/path/to/zig-$ZIG_VERSION)" ;;
esac

if [ -n "${ZIG:-}" ]; then
  zig="$ZIG"
else
  zig_name="zig-$zig_triple-$ZIG_VERSION"
  zig_dir="$deps/zig/$zig_name"
  zig="$zig_dir/zig"
  if [ ! -x "$zig" ]; then
    mkdir -p "$deps/zig"
    tarball="$deps/zig/$zig_name.tar.xz"
    if [ ! -f "$tarball" ] || [ "$(sha256 "$tarball")" != "$zig_sha" ]; then
      log "downloading $zig_name"
      fetch "https://ziglang.org/download/$ZIG_VERSION/$zig_name.tar.xz" "$tarball.part"
      mv "$tarball.part" "$tarball"
    fi
    got=$(sha256 "$tarball")
    [ "$got" = "$zig_sha" ] || { rm -f "$tarball"; die "zig checksum mismatch: got $got, want $zig_sha"; }
    log "extracting $zig_name"
    rm -rf "$zig_dir"
    tar -C "$deps/zig" -xJf "$tarball"
  fi
fi
zv=$("$zig" version)
case "$zv" in 0.16.*) ;; *) die "need zig 0.16.x, $zig reports $zv" ;; esac

# --- Ghostty --------------------------------------------------------------
src="$deps/ghostty"
if [ ! -d "$src/.git" ]; then
  log "initialising ghostty checkout"
  rm -rf "$src"; mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin "$GHOSTTY_REPO"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
  log "fetching ghostty $GHOSTTY_COMMIT"
  git -C "$src" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$src" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$GHOSTTY_COMMIT" ] || die "ghostty checkout is not at $GHOSTTY_COMMIT"

# --- Build ----------------------------------------------------------------
stamp="$prefix/.ghostty-commit"
case "$os" in
  Darwin) libfile=libghostty-vt.dylib; shimfile=libghostty-vt-cl.dylib
          shim_ldflags="-Wl,-undefined,dynamic_lookup" ;;
  *)      libfile=libghostty-vt.so; shimfile=libghostty-vt-cl.so; shim_ldflags="" ;;
esac
if [ -z "${FORCE:-}" ] && [ -f "$prefix/lib/$libfile" ] && [ -f "$stamp" ] \
   && [ "$(cat "$stamp")" = "$GHOSTTY_COMMIT $OPTIMIZE" ]; then
  log "libghostty-vt already built at $prefix/lib/$libfile (FORCE=1 to rebuild)"
else
  log "building libghostty-vt ($OPTIMIZE) with zig $zv"
  export ZIG_GLOBAL_CACHE_DIR="$deps/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$deps/zig-local-cache"
  rm -rf "$prefix"
  (cd "$src" && "$zig" build \
     -Demit-lib-vt=true -Demit-xcframework=false -Doptimize="$OPTIMIZE" \
     --prefix "$prefix")
  [ -f "$prefix/lib/$libfile" ] || die "build finished but $prefix/lib/$libfile is missing"
  echo "$GHOSTTY_COMMIT $OPTIMIZE" > "$stamp"
  log "installed $prefix/lib/$libfile and $prefix/include/ghostty"
fi

# --- Lisp shim ------------------------------------------------------------
# Small C library with pointer-taking wrappers for the by-value functions
# (see csrc/ghostty-vt-cl.c). Optional at run time: without it the Lisp side
# falls back to cffi-libffi.
shim_src="$root/csrc/ghostty-vt-cl.c"
shim_out="$prefix/lib/$shimfile"
if [ -n "${FORCE:-}" ] || [ ! -f "$shim_out" ] || [ "$shim_src" -nt "$shim_out" ] \
   || [ "$prefix/lib/$libfile" -nt "$shim_out" ]; then
  log "building $shimfile"
  export ZIG_GLOBAL_CACHE_DIR="$deps/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$deps/zig-local-cache"
  # shellcheck disable=SC2086
  "$zig" cc -shared -fPIC -O2 -I"$prefix/include" $shim_ldflags \
    "$shim_src" -o "$shim_out"
  log "installed $shim_out"
fi
