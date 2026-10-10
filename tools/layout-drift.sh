#!/usr/bin/env bash
#
# tools/layout-drift.sh -- do new stable kernel releases still match vendor/LAYOUT-TABLE?
#
#     layout-drift.sh [--table FILE] [--series 7.0,7.1,...] [--base-url URL]
#
# For every stable release of each series (names taken from the series'
# sha256sums.asc under --base-url, default https://cdn.kernel.org/pub/linux/kernel)
# the layout hash is computed from the closure files alone, fetched from
# git.kernel.org's stable tree (override with HDA_DRIFT_GIT_URL), and compared
# with the table.  One line per release:
#
#     COVERED   <ver>  inside a range, hash equals the range's
#     DRIFT     <ver>  inside a range, hash differs: the range is no longer valid
#     UNCOVERED <ver>  outside every range; says whether to extend the last
#                      range (same hash) or add a snapshot (different hash)
#
# Every finding is followed by the vendoring commands to run.  Default series:
# those in the table.
#
# Exit: 0 nothing to do, 1 drift or uncovered releases, 2 bad usage, a bad
# table or a failed fetch (a failed fetch is never reported as drift).
#
# The include closure is resolved by tools/layout-hash.sh itself: each time it
# reports a missing closure file, that file is fetched (relative to its
# includer first, then common/, the order layout-hash.sh uses) and it is re-run.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

START_FILES="codecs/cirrus/cs8409.c codecs/cirrus/cs8409.h codecs/cirrus/cs8409-tables.c"
git_url=${HDA_DRIFT_GIT_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}
base_url=https://cdn.kernel.org/pub/linux/kernel
table=$repo/vendor/LAYOUT-TABLE
series_arg=""
have_series=0

usage() {
	echo "usage: layout-drift.sh [--table FILE] [--series 7.0,7.1] [--base-url URL]" >&2
	exit 2
}

die() {
	echo "layout-drift: $*" >&2
	exit 2
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--table | --series | --base-url)
		[[ $# -ge 2 ]] || usage
		case $1 in
		--table) table=$2 ;;
		--series) series_arg=$2 have_series=1 ;;
		--base-url) base_url=$2 ;;
		esac
		shift 2
		;;
	*) usage ;;
	esac
done

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf -- "$work"' EXIT

# vnum <x.y.z> -- sortable integer
vnum() {
	local a b c
	IFS=. read -r a b c <<< "$1"
	echo $((a * 1000000 + b * 1000 + ${c:-0}))
}

# --- table -----------------------------------------------------------------
[[ -r $table ]] || die "cannot read table: $table"
t_first=() t_last=() t_snap=() t_hash=()
while read -r first last snap hash extra; do
	case $first in "" | "#"*) continue ;; esac
	[[ -z $extra && -n $hash ]] || die "malformed table line: $first $last $snap $hash $extra"
	[[ $first =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $last =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "malformed version in table line: $first $last"
	[[ $hash =~ ^[0-9a-f]{64}$ ]] || die "malformed layout hash in table line: $first $last"
	[[ ${first%.*} == "${last%.*}" ]] || die "range crosses a series: $first $last"
	t_first+=("$first") t_last+=("$last") t_snap+=("$snap") t_hash+=("$hash")
done < "$table"
[[ ${#t_first[@]} -gt 0 ]] || die "table has no ranges: $table"

# --- series ------------------------------------------------------------------
if [[ $have_series -eq 0 ]]; then
	series_list=$(printf '%s\n' "${t_first[@]}" | sed 's/\.[0-9]*$//' | LC_ALL=C sort -u | tr '\n' ' ')
else
	[[ $series_arg =~ ^[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+)*$ ]] || usage
	series_list=${series_arg//,/ }
fi

# fetch <url> <dest> -- 0 found, 1 absent (HTTP 404); anything else is fatal
fetch() {
	local code
	code=$(curl -sS --max-time 60 --retry 2 -o "$2" -w '%{http_code}' "$1") || die "fetch failed: $1"
	case $code in
	200) return 0 ;;
	404) return 1 ;;
	*) die "fetch failed (HTTP $code): $1" ;;
	esac
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

# release_hash <version> -- print the layout hash of a release
release_hash() {
	local ver=$1 tag root out missing includer cand f
	# the first release of a series is tagged v7.0, not v7.0.0
	tag=v$ver
	[[ $ver == *.0 ]] && tag=v${ver%.0}
	root=$work/tree-$ver/sound/hda
	mkdir -p "$root"
	for f in $START_FILES; do
		mkdir -p "$root/$(dirname "$f")"
		fetch "$git_url/plain/sound/hda/$f?h=$tag" "$root/$f" || die "$f not found in $tag"
	done
	while ! out=$(bash "$here/layout-hash.sh" --files "$root" 2>&1); do
		missing=$(sed -n 's/^layout-hash: missing closure file: \(.*\) (included from .*)$/\1/p' <<< "$out")
		includer=$(sed -n 's/^layout-hash: missing closure file: .* (included from \(.*\))$/\1/p' <<< "$out")
		[[ -n $missing && -n $includer ]] || die "cannot resolve closure of $ver: $out"
		for cand in "$(dirname "$includer")/$missing" "common/$missing"; do
			cand=$(normalize "$cand") || continue
			mkdir -p "$root/$(dirname "$cand")"
			if fetch "$git_url/plain/sound/hda/$cand?h=$tag" "$root/$cand"; then
				continue 2
			fi
			rm -f "$root/$cand"
		done
		die "include \"$missing\" of $includer not found in $tag"
	done
	bash "$here/layout-hash.sh" "$root" || die "layout hash failed for $ver"
	rm -rf -- "$work/tree-$ver"
}

# --- scan ----------------------------------------------------------------------
findings=0
report_commands() {
	echo "    tools/vendor-kernel-sources.sh $1"
	echo "    tools/layout-hash.sh vendor/linux-$1/sound/hda"
}

for series in $series_list; do
	major=${series%%.*}
	listing=$work/list-$series
	fetch "${base_url%/}/v$major.x/sha256sums.asc" "$listing" || die "no release listing for series $series"
	versions=$(sed -n "s/^.*[[:space:]]linux-\(${series//./\\.}\(\.[0-9]*\)\{0,1\}\)\.tar\.xz\$/\1/p" "$listing")
	[[ -n $versions ]] || die "no stable releases of series $series in the listing"
	versions=$(while read -r v; do [[ $v == "$series" ]] && v=$series.0; echo "$(vnum "$v") $v"; done <<< "$versions" | sort -n | cut -d' ' -f2)

	# last range of this series, if any
	last_idx=-1
	for i in "${!t_first[@]}"; do
		[[ ${t_first[$i]%.*} == "$series" ]] || continue
		if [[ $last_idx -lt 0 ]] || [[ $(vnum "${t_last[$i]}") -gt $(vnum "${t_last[$last_idx]}") ]]; then last_idx=$i; fi
	done

	for ver in $versions; do
		hash=$(release_hash "$ver") || exit 2
		n=$(vnum "$ver")
		range=-1
		for i in "${!t_first[@]}"; do
			if [[ $n -ge $(vnum "${t_first[$i]}") && $n -le $(vnum "${t_last[$i]}") ]]; then range=$i; fi
		done
		if [[ $range -ge 0 ]]; then
			if [[ $hash == "${t_hash[$range]}" ]]; then
				echo "COVERED $ver (range ${t_first[$range]}..${t_last[$range]}, ${t_snap[$range]})"
			else
				findings=1
				echo "DRIFT $ver: hash $hash differs from range ${t_first[$range]}..${t_last[$range]} (${t_hash[$range]}); the range is no longer valid, split it with a new snapshot"
				report_commands "$ver"
			fi
		elif [[ $last_idx -ge 0 && $n -gt $(vnum "${t_last[$last_idx]}") && $hash == "${t_hash[$last_idx]}" ]]; then
			findings=1
			echo "UNCOVERED $ver: same layout as ${t_snap[$last_idx]}; extend the range ${t_first[$last_idx]}..${t_last[$last_idx]} to $ver in vendor/LAYOUT-TABLE"
		else
			findings=1
			echo "UNCOVERED $ver: layout $hash matches no range; new snapshot needed, add a range for it in vendor/LAYOUT-TABLE"
			report_commands "$ver"
		fi
	done
done

exit "$findings"
