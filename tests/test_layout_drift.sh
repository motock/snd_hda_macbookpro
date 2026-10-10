#!/usr/bin/env bash
#
# tests/test_layout_drift.sh -- tools/layout-drift.sh and the scheduled
# workflow that runs it.  No network: a fake curl serves fixture files.
#
#   T1  covered release          -> COVERED, exit 0
#   T2  changed header in range  -> DRIFT, exit 1
#   T3  newer, same hash         -> UNCOVERED "extend the range", exit 1
#   T4  newer, different hash    -> UNCOVERED "new snapshot", exit 1
#   T5  fetch fails (curl rc 22) -> exit 2, never a DRIFT line
#   T6  malformed table          -> exit 2
#   T7  bad usage                -> usage on stderr, exit 2
#   W1-W5  .github/workflows/layout-drift.yml lint (grep based)

. "$(dirname "$0")/lib/assert.sh"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 1

DRIFT=tools/layout-drift.sh
LAYOUT_HASH=tools/layout-hash.sh
WORKFLOW=.github/workflows/layout-drift.yml

assert_file_exists "$DRIFT" "T0 $DRIFT exists"

# make_tree <root> <variant> -- miniature sound/hda; variant "b" differs from
# "a" by one byte in a closure header that lives in common/ (so fetching it
# needs the 404 probe of the includer's directory first).
make_tree() {
  local r=$1 v=$2
  mkdir -p "$r/codecs/cirrus" "$r/common"
  printf '#include "cs8409.h"\n' > "$r/codecs/cirrus/cs8409.c"
  printf '#include "cs8409.h"\n' > "$r/codecs/cirrus/cs8409-tables.c"
  printf '#include "hda_local.h"\n' > "$r/codecs/cirrus/cs8409.h"
  printf 'struct hda_local { int %s; };\n' "$v" > "$r/common/hda_local.h"
}

# make_world <dir> <variant-of-each-release...> -- fixture world for series
# 9.9: releases 9.9, 9.9.1, 9.9.2, ... get the given variants in order.
make_world() {
  local w=$1; shift
  local i=0 ver v
  mkdir -p "$w/list/v9.x" "$w/git" "$w/bin"
  : > "$w/list/v9.x/sha256sums.asc"
  for v in "$@"; do
    if [ "$i" -eq 0 ]; then ver=9.9; else ver=9.9.$i; fi
    make_tree "$w/git/$ver/sound/hda" "$v"
    printf '%064d  linux-%s.tar.xz\n' 0 "$ver" >> "$w/list/v9.x/sha256sums.asc"
    i=$((i + 1))
  done
  printf '%064d  linux-9.10-rc1.tar.xz\n' 0 >> "$w/list/v9.x/sha256sums.asc"
  cat > "$w/bin/curl" <<'FAKE'
#!/bin/bash
# fake curl: `curl ... -o <dest> -w '%{http_code}' <url>`.  Serves
# $FAKE_WORLD; prints 404 for absent git files; rc 22 when the url names
# $FAKE_CURL_FAIL as its tag.
out=""; url=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -w | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  *sha256sums.asc)
    dir=${url%/sha256sums.asc}
    src="$FAKE_WORLD/list/${dir##*/}/sha256sums.asc" ;;
  *"/plain/"*"?h=v"*)
    tag=${url##*\?h=v}; path=${url#*/plain/}; path=${path%%\?*}
    [ -n "${FAKE_CURL_FAIL:-}" ] && [ "$tag" = "$FAKE_CURL_FAIL" ] && exit 22
    src="$FAKE_WORLD/git/$tag/$path" ;;
  *) exit 6 ;;
esac
if [ -f "$src" ]; then cp "$src" "$out"; printf 200; else printf 404; fi
exit 0
FAKE
  chmod +x "$w/bin/curl"
}

# write_table <file> <last-version> <hash-tree-variant>
write_table() {
  local t=$1 last=$2 variant=$3 tree
  tree=$(make_tmpdir)
  make_tree "$tree" "$variant"
  printf '# comment\n\n9.9.0 %s snap-a %s\n' "$last" "$(bash "$LAYOUT_HASH" "$tree")" > "$t"
}

# run_drift <world> <table> [args...] -- sets out (stdout), err, rc
run_drift() {
  local w=$1 t=$2; shift 2
  err=$(mktemp "${TMPDIR:-/tmp}/drift-err.XXXXXX")
  out=$(PATH="$w/bin:$PATH" FAKE_WORLD="$w" bash "$DRIFT" --table "$t" --series 9.9 "$@" 2>"$err")
  rc=$?
  err_text=$(cat "$err"); rm -f "$err"
}

# --- T1 covered ---------------------------------------------------------------
w=$(make_tmpdir)
make_world "$w" a a a
t="$w/table"; write_table "$t" 9.9.2 a
run_drift "$w" "$t"
assert_eq 0 "$rc" "T1 covered releases exit 0 ($out / $err_text)"
assert_contains "$out" "COVERED 9.9.2" "T1 reports COVERED"
assert_contains "$out" "COVERED 9.9.0" "T1 reports the .0 release (tag v9.9) as 9.9.0"
assert_not_contains "$out" "DRIFT" "T1 no DRIFT"
assert_not_contains "$out" "UNCOVERED" "T1 no UNCOVERED"
assert_not_contains "$out" "rc1" "T1 release candidates are ignored"

# --- T2 drift -----------------------------------------------------------------
w=$(make_tmpdir)
make_world "$w" a b a
t="$w/table"; write_table "$t" 9.9.2 a
run_drift "$w" "$t"
assert_eq 1 "$rc" "T2 drift exits 1"
assert_contains "$out" "DRIFT 9.9.1" "T2 reports DRIFT for the changed release"
assert_contains "$out" "COVERED 9.9.2" "T2 other releases stay COVERED"
assert_contains "$out" "tools/vendor-kernel-sources.sh 9.9.1" "T2 prints the vendoring command"

# --- T3 uncovered, same hash --------------------------------------------------
w=$(make_tmpdir)
make_world "$w" a a a a
t="$w/table"; write_table "$t" 9.9.2 a
run_drift "$w" "$t"
assert_eq 1 "$rc" "T3 uncovered exits 1"
assert_contains "$out" "UNCOVERED 9.9.3" "T3 reports UNCOVERED"
assert_contains "$out" "extend the range" "T3 suggests extending the range"
assert_not_contains "$out" "new snapshot" "T3 does not suggest a new snapshot"

# --- T4 uncovered, different hash ---------------------------------------------
w=$(make_tmpdir)
make_world "$w" a a a b
t="$w/table"; write_table "$t" 9.9.2 a
run_drift "$w" "$t"
assert_eq 1 "$rc" "T4 uncovered exits 1"
assert_contains "$out" "UNCOVERED 9.9.3" "T4 reports UNCOVERED"
assert_contains "$out" "new snapshot" "T4 suggests a new snapshot"
assert_contains "$out" "tools/vendor-kernel-sources.sh 9.9.3" "T4 prints the vendoring command"

# --- T5 failed fetch is not drift ---------------------------------------------
w=$(make_tmpdir)
make_world "$w" a a a
t="$w/table"; write_table "$t" 9.9.2 a
FAKE_CURL_FAIL=9.9.1 run_drift "$w" "$t"
assert_eq 2 "$rc" "T5 a failed fetch exits 2"
assert_not_contains "$out" "DRIFT" "T5 a failed fetch is never reported as DRIFT"
assert_not_contains "$err_text" "DRIFT" "T5 nor on stderr"
assert_contains "$err_text" "9.9.1" "T5 stderr names the release that failed"

# --- T6 malformed table -------------------------------------------------------
w=$(make_tmpdir)
make_world "$w" a
printf '9.9.0 9.9.2 snap-a\n' > "$w/table"
run_drift "$w" "$w/table"
assert_eq 2 "$rc" "T6 table with a missing field exits 2"
printf '9.9.0 9.9.2 snap-a nothex\n' > "$w/table"
run_drift "$w" "$w/table"
assert_eq 2 "$rc" "T6 table with a bad hash exits 2"
run_drift "$w" "$w/no-such-table"
assert_eq 2 "$rc" "T6 missing table exits 2"

# --- T7 usage -----------------------------------------------------------------
w=$(make_tmpdir)
make_world "$w" a
t="$w/table"; write_table "$t" 9.9.2 a
run_drift "$w" "$t" --series 9.x
assert_eq 2 "$rc" "T7 malformed --series exits 2"
assert_contains "$err_text" "usage" "T7 usage goes to stderr"
run_drift "$w" "$t" --series ""
assert_eq 2 "$rc" "T7 empty --series exits 2"
run_drift "$w" "$t" --bogus
assert_eq 2 "$rc" "T7 unknown option exits 2"
run_drift "$w" "$t" --series 8.8
assert_eq 2 "$rc" "T7 a series with no published releases exits 2"

# --- W: workflow lint ---------------------------------------------------------
assert_file_exists "$WORKFLOW" "W0 $WORKFLOW exists"
wf=$(cat "$WORKFLOW" 2>/dev/null)
assert_contains "$wf" "schedule:" "W1 runs on a schedule"
assert_contains "$wf" "workflow_dispatch" "W1 can be dispatched by hand"
assert_not_contains "$wf" "pull_request" "W2 never triggers on pull_request"
assert_contains "$wf" "contents: read" "W3 requests contents: read"
assert_contains "$wf" "issues: write" "W3 requests issues: write"
perms=$(grep -E '^[[:space:]]+[a-z-]+: (read|write|none)$' "$WORKFLOW" 2>/dev/null | sed 's/^[[:space:]]*//' | LC_ALL=C sort)
assert_eq "$(printf 'contents: read\nissues: write')" "$perms" "W3 no permission beyond contents:read and issues:write"
runs=$(awk '
  { match($0, /^[ ]*/); ind = RLENGTH }
  inrun && ($0 ~ /^[ ]*$/ || ind > runind) { if ($0 ~ /\$\{\{/) print; next }
  { inrun = 0 }
  /^[ -]*run:/ { inrun = 1; runind = ind; if ($0 ~ /\$\{\{/) print }
' "$WORKFLOW" 2>/dev/null)
assert_eq "" "$runs" "W4 no \${{ }} expression inside a run: block"
assert_contains "$wf" "concurrency:" "W5 has a concurrency group"
assert_contains "$wf" "timeout-minutes:" "W5 has a timeout"
assert_contains "$wf" "persist-credentials: false" "W5 checkout does not persist credentials"
assert_eq 0 "$(grep -Ec 'uses: .*@[^0-9a-f]' "$WORKFLOW" 2>/dev/null)" "W5 actions are pinned to a commit sha"

finish
