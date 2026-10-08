#!/usr/bin/env bash
#
# tests/test_readme_paths.sh -- every filesystem path in a README fenced block
# that follows an uninstall label ("Deleting driver" / "remove driver ...")
# must exist in the repo, or its directory must be one the installers or the
# Makefile produce.  Module paths under /lib/modules/{kernel version}/ are
# checked by grepping the installers/Makefile for the same directory.

set -u

. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCES="$REPO_ROOT/Makefile $REPO_ROOT/dkms.conf $REPO_ROOT/dkms.sh $REPO_ROOT/install.cirrus.driver.sh $REPO_ROOT/install.cirrus.driver.pre617.sh"

# print the absolute paths found in uninstall fenced blocks of README $1
uninstall_paths() {
  awk '
    /^\*\*.*(Deleting|[Rr]emove|[Uu]ninstall).*\*\*/ { armed = 1; next }
    /^```/ { if (armed && !infence) { infence = 1; next } if (infence) { infence = 0; armed = 0; next } }
    /^\*\*/ { armed = 0 }
    infence && !/^[ \t]*#/ { print }
  ' "$1" | sed 's/{kernel version}/KVER/g' | tr ' ' '\n' | grep -E '^/(lib|usr|var|etc|boot)/'
}

# 0 when the path exists in the repo or its directory is produced by the code
path_is_backed() {
  local p=$1 rel dir
  [ -e "$REPO_ROOT$p" ] && return 0
  case $p in
    /lib/modules/*)
      rel=${p#/lib/modules/KVER/}
      dir=$(dirname "$rel")
      # shellcheck disable=SC2086
      grep -qF -- "$dir" $SOURCES
      return $?;;
    /usr/src/*|/var/lib/*)
      # shellcheck disable=SC2086
      grep -qF -- "$p" $SOURCES
      return $?;;
  esac
  return 1
}

# print each path of README $1 that is not backed by the code
unbacked_paths() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    path_is_backed "$p" || printf '%s\n' "$p"
  done <<EOP
$(uninstall_paths "$1")
EOP
}

# --- positive: the real README ------------------------------------------------

found=$(uninstall_paths "$REPO_ROOT/README.md")
assert_contains "$found" "updates/codecs/cirrus/snd-hda-codec-cs8409.ko" "README uninstall block names the 6.17+ module path"
assert_eq "" "$(unbacked_paths "$REPO_ROOT/README.md")" "every README uninstall path is produced by the installers/Makefile"

# --- negative: a bogus path is rejected --------------------------------------

fixture_dir=$(make_tmpdir)
cat > "$fixture_dir/README.md" <<'EOR'
**Deleting driver**
```
sudo rm /lib/modules/{kernel version}/updates/bogus/snd-hda-codec-cs8409.ko
```
EOR
assert_eq "/lib/modules/KVER/updates/bogus/snd-hda-codec-cs8409.ko" "$(unbacked_paths "$fixture_dir/README.md")" "a bogus uninstall path is reported"

# --- negative: a README with no uninstall block yields nothing to check -------

printf '# nothing here\n' > "$fixture_dir/empty.md"
assert_eq "" "$(uninstall_paths "$fixture_dir/empty.md")" "no uninstall block means no paths"

finish
