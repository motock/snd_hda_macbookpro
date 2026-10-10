#!/usr/bin/env bash
#
# tools/layout-hash.sh -- fingerprint of the kernel headers cs8409 is built against.
#
#     layout-hash.sh <sound/hda-root>          print one sha256
#     layout-hash.sh --files <sound/hda-root>  print the include closure, one
#                                              root-relative path per line
#
# The closure is every file reachable through #include "..." directives from
# codecs/cirrus/cs8409.c, cs8409.h and cs8409-tables.c.  A quoted include is
# resolved relative to the including file, then in common/ (the Makefile's
# -I), and must stay inside <root>.  <...> includes are not followed.
#
# The hash covers only the .h files of the closure: sorted by path, each as
# "<sha256 of content>  <path>", then hashed again.  Only root-relative paths
# enter the hash, so it does not depend on where the tree is checked out.
# Exits non-zero, naming the file, when a closure file is missing.

set -u

START_FILES="codecs/cirrus/cs8409.c codecs/cirrus/cs8409.h codecs/cirrus/cs8409-tables.c"

die() {
	echo "layout-hash: $*" >&2
	exit 1
}

sha256_of_stdin() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	elif command -v shasum > /dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
	else
		die "neither sha256sum nor shasum is available"
	fi
}

# normalize <relative-path> -- collapse . and .. ; fail when it escapes the root
normalize() {
	local part IFS=/
	local -a out=()
	for part in $1; do
		case $part in
		"" | .) ;;
		..)
			[[ ${#out[@]} -gt 0 ]] || return 1
			unset "out[${#out[@]}-1]"
			;;
		*) out+=("$part") ;;
		esac
	done
	printf '%s\n' "${out[*]-}"
}

usage() {
	echo "usage: layout-hash.sh [--files] <sound/hda-root>" >&2
	exit 2
}

list_only=0
if [[ ${1:-} == --files ]]; then
	list_only=1
	shift
fi
[[ $# -eq 1 ]] || usage
root=$1
[[ -d $root ]] || die "not a directory: $root"

# resolve <includer> <name> -- print the root-relative path an include names
resolve() {
	local includer=$1 name=$2 dir cand
	dir=$(dirname "$includer")
	for cand in "$dir/$name" "common/$name"; do
		cand=$(normalize "$cand") || continue
		if [[ -f $root/$cand ]]; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	return 1
}

seen=" "
queue=($START_FILES)
for f in "${queue[@]}"; do
	[[ -f $root/$f ]] || die "missing closure file: $f"
done

i=0
while [[ $i -lt ${#queue[@]} ]]; do
	cur=${queue[$i]}
	i=$((i + 1))
	case $seen in *" $cur "*) continue ;; esac
	seen="$seen$cur "
	while IFS= read -r name; do
		[[ -n $name ]] || continue
		found=$(resolve "$cur" "$name") || die "missing closure file: $name (included from $cur)"
		queue+=("$found")
	done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$root/$cur")
done

closure=$(printf '%s\n' $seen | LC_ALL=C sort)

if [[ $list_only -eq 1 ]]; then
	printf '%s\n' "$closure"
	exit 0
fi

for f in $(printf '%s\n' "$closure" | grep '\.h$'); do
	printf '%s  %s\n' "$(sha256_of_stdin < "$root/$f")" "$f"
done | sha256_of_stdin
