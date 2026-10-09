#!/usr/bin/env bash
#
# lib/ci_build_warnings.sh -- warning-count ratchet for lib/ci_build_check.sh.
#
# Source it; nothing runs on load.  Compatible with bash 3.2 and any awk.
#
# Baseline file (tests/ci/build-warning-baseline.<pin>.txt): one line per
# `<file> <kind> <count>`, sorted, where <kind> is the compiler's -W option
# without the "-W" (unused-variable).  A warning with no [-W...] tag is
# counted under the kind "untagged".  The file must exist and be non-empty.
#
# Rules (cbw_check <log> <baseline>):
#   fail  a (file, kind) count above the baseline, or absent from it
#   fail  a warning kind the baseline does not contain at all
#   fail  a count BELOW the baseline: lower the baseline so the gain is kept
#   fail  a missing, empty or malformed baseline (deny by default)
# CI_BUILD_WARNINGS_UPDATE=1 rewrites the baseline from the log instead
# (review the diff: an increase is a regression you are accepting).

# cbw_counts <log> -- print `file kind count` lines, C-locale sorted.
cbw_counts() {
  grep ' warning: ' "$1" | LC_ALL=C awk '
    {
      kind = "untagged"
      if (match($0, /\[-W[^]]+\]$/)) kind = substr($0, RSTART + 3, RLENGTH - 4)
      split($0, p, ":")
      n[p[1] " " kind]++
    }
    END { for (k in n) print k, n[k] }' | LC_ALL=C sort
}

# cbw_validate_baseline <file> -- 0 when usable, else say why on stderr.
cbw_validate_baseline() {
  local f=$1 bad
  if [ ! -s "$f" ]; then
    echo "FAIL: warning baseline $f is missing or empty" >&2
    return 1
  fi
  bad=$(LC_ALL=C awk '
    NF != 3 || $2 !~ /^[A-Za-z0-9_=+-]+$/ || $3 !~ /^[1-9][0-9]*$/ {
      printf "line %d: %s\n", NR, $0; next }
    ($1 " " $2) in seen { printf "line %d: duplicate %s %s\n", NR, $1, $2 }
    { seen[$1 " " $2] = 1 }' "$f")
  if [ -n "$bad" ]; then
    echo "FAIL: malformed warning baseline $f (want '<file> <kind> <count>', count >= 1):" >&2
    printf '  %s\n' "$bad" >&2
    return 1
  fi
}

# cbw_check <log> <baseline> -- apply the rules; print measured vs baseline.
cbw_check() {
  local log=$1 base=$2 cur out rc=0
  cur=$(mktemp "${TMPDIR:-/tmp}/cbw.XXXXXX") || return 1
  cbw_counts "$log" >"$cur"
  if [ "${CI_BUILD_WARNINGS_UPDATE:-}" = 1 ]; then
    if [ ! -s "$cur" ]; then
      echo "FAIL: refusing to write an empty warning baseline" >&2
      rm -f "$cur"
      return 1
    fi
    cp "$cur" "$base" && echo "warning baseline rewritten: $base"
    rc=$?
    rm -f "$cur"
    return "$rc"
  fi
  if ! cbw_validate_baseline "$base"; then
    rm -f "$cur"
    return 1
  fi
  out=$(LC_ALL=C awk -v base="$base" '
    FILENAME == base { b[$1 " " $2] = $3; bk[$2] = 1; next }
    { c[$1 " " $2] = $3; seen[$1 " " $2] = 1
      if (!($2 in bk)) newkind[$2] = 1 }
    END {
      for (k in newkind) printf "FAIL: new warning kind not in the baseline: %s\n", k
      for (k in c) {
        split(k, a, " ")
        if (!(k in b)) { if (!(a[2] in newkind)) printf "FAIL: new warning in %s: %s (count %d, baseline 0)\n", a[1], a[2], c[k]; continue }
        if (c[k] > b[k]) printf "FAIL: more warnings in %s: %s (count %d, baseline %d)\n", a[1], a[2], c[k], b[k]
      }
      for (k in b) {
        split(k, a, " ")
        if (!(k in c)) printf "FAIL: fewer warnings in %s: %s (count 0, baseline %d); lower the baseline\n", a[1], a[2], b[k]
        else if (c[k] < b[k]) printf "FAIL: fewer warnings in %s: %s (count %d, baseline %d); lower the baseline\n", a[1], a[2], c[k], b[k]
      }
    }' "$base" "$cur" | LC_ALL=C sort)
  printf 'warnings measured=%s baseline=%s (%s)\n' \
    "$(awk '{s += $3} END {print s + 0}' "$cur")" \
    "$(awk '{s += $3} END {print s + 0}' "$base")" "$base"
  rm -f "$cur"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    echo "FAIL: warning ratchet: fix new warnings, or after reducing them run with CI_BUILD_WARNINGS_UPDATE=1 to lower the baseline (see README, CI)" >&2
    return 1
  fi
  echo "warning ratchet: counts equal the baseline"
}
