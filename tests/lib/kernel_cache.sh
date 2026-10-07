#!/usr/bin/env bash
#
# tests/lib/kernel_cache.sh -- pinned kernel-source cache for the test suite.
#
# Sourced shell library.  Sourcing it has no side effects: nothing is
# downloaded, created or printed until one of the functions is called.
#
#   kernel_tree_for new|old
#       Print the path of the pristine extracted kernel tree, exit 0.
#       Exit 77 when the tree is not cached and cannot be downloaded (the
#       caller should skip).  Every other failure -- bad arguments, checksum
#       mismatch, unreadable pins -- is a hard error: non-zero and NOT 77.
#
#   kernel_tree_copy new|old destdir
#       Copy the pristine tree to destdir (created if missing) so a test can
#       mutate the copy.  The cached pristine tree is never mutated.
#
# Environment:
#   HDA_TEST_CACHE     cache root (default
#                      ${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests,
#                      outside the repository).
#   HDA_KERNEL_PINS    pins file (default: the kernel-pins.conf next to this
#                      library's directory, i.e. tests/kernel-pins.conf).
#   HDA_KERNEL_MIRROR  directory URL the tarball is fetched from
#                      (default https://cdn.kernel.org/pub/linux/kernel/v6.x).
#
# Exit codes: 0 ok, 1 hard error, 77 tree unavailable and network down.

# --- internals -------------------------------------------------------------

_kc_lib_dir() {
  # This library is sourced, so $0 is the caller's path; BASH_SOURCE is the
  # only reliable pointer to this file.
  local src=${BASH_SOURCE[0]:-$0}
  ( cd "$(dirname "$src")" && pwd )
}

_kc_cache_root() {
  printf '%s\n' "${HDA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests}"
}

_kc_pins_file() {
  # Default: tests/kernel-pins.conf, i.e. one level up from tests/lib/.
  printf '%s\n' "${HDA_KERNEL_PINS:-$(_kc_lib_dir)/../kernel-pins.conf}"
}

_kc_mirror() {
  local m=${HDA_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v6.x}
  printf '%s\n' "${m%/}"
}

_kc_die() {
  printf 'kernel_cache: %s\n' "$*" >&2
  return 1
}

_kc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

_kc_download() {
  # _kc_download <url> <dest> -- fetch url into dest, 0 on success.
  local url=$1 dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL -o "$dest" "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

_kc_load_pins() {
  # _kc_load_pins new|old -- set _KC_VERSION, _KC_TARBALL, _KC_SHA256.
  local which=$1 pins vname tname sname
  case "$which" in
    new) vname=PIN_NEW_VERSION; tname=PIN_NEW_TARBALL; sname=PIN_NEW_SHA256 ;;
    old) vname=PIN_OLD_VERSION; tname=PIN_OLD_TARBALL; sname=PIN_OLD_SHA256 ;;
    *) _kc_die "unknown pin '$which' (expected new or old)"; return 1 ;;
  esac
  pins=$(_kc_pins_file)
  if [ ! -f "$pins" ]; then
    _kc_die "pins file not found: $pins"
    return 1
  fi
  # shellcheck disable=SC1090
  if ! . "$pins"; then
    _kc_die "cannot read pins file: $pins"
    return 1
  fi
  eval "_KC_VERSION=\${$vname-}"
  eval "_KC_TARBALL=\${$tname-}"
  eval "_KC_SHA256=\${$sname-}"
  if [ -z "$_KC_VERSION" ] || [ -z "$_KC_TARBALL" ]; then
    _kc_die "pins file $pins does not define $vname and $tname"
    return 1
  fi
  if ! printf '%s' "$_KC_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    _kc_die "pins file $pins has no valid sha256 for the $which pin (got '$_KC_SHA256')"
    return 1
  fi
  return 0
}

_kc_ensure_tarball() {
  # Download and verify the pinned tarball into the cache.  0 ok, 1 hard
  # error (checksum mismatch, no sha256 tool), 77 download failed.
  local root tarball tmp actual
  root=$(_kc_cache_root)
  mkdir -p "$root/tarballs" || { _kc_die "cannot create cache root $root"; return 1; }
  tarball="$root/tarballs/$_KC_TARBALL"

  if [ -f "$tarball" ]; then
    actual=$(_kc_sha256 "$tarball") || { _kc_die "no sha256 tool available"; return 1; }
    if [ "$actual" = "$_KC_SHA256" ]; then
      return 0
    fi
    rm -f "$tarball"
    _kc_die "checksum mismatch for cached $_KC_TARBALL: expected $_KC_SHA256, actual $actual (bad file deleted)"
    return 1
  fi

  tmp=$(mktemp "$root/tarballs/.download.XXXXXX") || {
    _kc_die "cannot create a temp file in $root/tarballs"
    return 1
  }
  if ! _kc_download "$(_kc_mirror)/$_KC_TARBALL" "$tmp"; then
    rm -f "$tmp"
    _kc_die "cannot download $_KC_TARBALL from $(_kc_mirror) (network unavailable?)"
    return 77
  fi
  actual=$(_kc_sha256 "$tmp") || { rm -f "$tmp"; _kc_die "no sha256 tool available"; return 1; }
  if [ "$actual" != "$_KC_SHA256" ]; then
    rm -f "$tmp"
    _kc_die "checksum mismatch for $_KC_TARBALL: expected $_KC_SHA256, actual $actual (bad file deleted)"
    return 1
  fi
  mv -f "$tmp" "$tarball" || {
    rm -f "$tmp"
    _kc_die "cannot move the verified tarball into $tarball"
    return 1
  }
  return 0
}

_kc_extract() {
  # _kc_extract new|old -- unpack only the installer's subtrees into the cache.
  local which=$1 root tarball final tmp members
  root=$(_kc_cache_root)
  tarball="$root/tarballs/$_KC_TARBALL"
  final="$root/trees/linux-$_KC_VERSION"
  mkdir -p "$root/trees" || { _kc_die "cannot create $root/trees"; return 1; }
  tmp=$(mktemp -d "$root/tmp.XXXXXX") || { _kc_die "cannot create a temp dir in $root"; return 1; }
  members="linux-$_KC_VERSION/sound/pci/hda"
  if [ "$which" = new ]; then
    members="$members linux-$_KC_VERSION/sound/hda"
  fi
  # shellcheck disable=SC2086
  if ! tar -xf "$tarball" -C "$tmp" --strip-components=1 $members; then
    rm -rf "$tmp"
    _kc_die "cannot extract $_KC_TARBALL"
    return 1
  fi
  if [ ! -d "$tmp/sound/pci/hda" ]; then
    rm -rf "$tmp"
    _kc_die "extracting $_KC_TARBALL produced no sound/pci/hda"
    return 1
  fi
  rm -rf "$final"
  mv "$tmp" "$final" || {
    rm -rf "$tmp"
    _kc_die "cannot move the extracted tree into $final"
    return 1
  }
  return 0
}

# --- public API ------------------------------------------------------------

kernel_tree_for() {
  local which=${1-} root tree rc
  case "$which" in
    new|old) ;;
    *) _kc_die "usage: kernel_tree_for new|old"; return 1 ;;
  esac
  _kc_load_pins "$which" || return 1
  root=$(_kc_cache_root)
  tree="$root/trees/linux-$_KC_VERSION"
  if [ -d "$tree" ]; then
    printf '%s\n' "$tree"
    return 0
  fi
  mkdir -p "$root" || { _kc_die "cannot create cache root $root"; return 1; }
  _kc_ensure_tarball
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  _kc_extract "$which" || return 1
  printf '%s\n' "$tree"
  return 0
}

kernel_tree_copy() {
  local which=${1-} dest=${2-} src rc
  case "$which" in
    new|old) ;;
    *) _kc_die "usage: kernel_tree_copy new|old <destdir>"; return 1 ;;
  esac
  if [ -z "$dest" ]; then
    _kc_die "usage: kernel_tree_copy new|old <destdir>"
    return 1
  fi
  src=$(kernel_tree_for "$which")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  mkdir -p "$dest" || { _kc_die "cannot create $dest"; return 1; }
  cp -R "$src/." "$dest/" || { _kc_die "cannot copy $src to $dest"; return 1; }
  return 0
}
