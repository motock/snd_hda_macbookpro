#!/usr/bin/env bash
#
# tests/test_shell_static.sh -- static checks for the install shell scripts.
#
# Scripts under test (the three shell entry points shipped to users):
#   install.cirrus.driver.sh
#   install.cirrus.driver.pre617.sh
#   dkms.sh
#
# Requirements checked, one assertion group each:
#   R1 `bash -n` parses each script (exit 0).  Hard failure: a script that
#      does not parse cannot be shipped at all.
#   R2 the R1 check is not vacuous: a scratch copy of a script with an
#      injected syntax error is rejected, and the rejection names the error.
#   R3 every shellcheck finding at warning severity or above is listed in
#      tests/shellcheck-baseline.txt.  A finding that is not listed fails the
#      test and is printed as "new shellcheck finding: <file>:<CODE>".
#   R4 the baseline may only shrink: an entry that no longer fires fails the
#      test and is printed as "stale baseline entry: <file>:<CODE>".
#   R5 the R3/R4 comparison is not vacuous: a scratch script with a fresh
#      warning-severity finding is reported as new, and a scratch baseline
#      with an entry that cannot fire is reported as stale -- while an entry
#      that does fire is not.
#
# R3 and R4 are skipped, with a note, when shellcheck is not on PATH; R1 and
# R2 need nothing but bash and always run.
#
# The comparison is count-insensitive: a code that fires N times in one file
# is listed once, and line numbers are not part of the key, so unrelated edits
# do not churn the baseline.
#
# Note on the R5 fixture: SC2086 ("double quote to prevent globbing") is an
# *info* finding, so `-S warning` filters it out.  The fixture therefore uses
# an unquoted command substitution, which shellcheck reports as SC2046 at
# warning severity -- the same severity the real check uses.

. "$(dirname "$0")/lib/assert.sh"
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

SCRIPTS="install.cirrus.driver.sh install.cirrus.driver.pre617.sh dkms.sh"
BASELINE=tests/shellcheck-baseline.txt

# ---------------------------------------------------------------------------
# shellcheck helpers
# ---------------------------------------------------------------------------

# sc_findings <script>... -- print the unique `file:CODE` findings shellcheck
# reports at warning severity or above, one per line, sorted.  The gcc format
# is `file:line:col: severity: message [SCxxxx]`; only the file and the code
# are kept, which is what makes the comparison count- and line-insensitive.
sc_findings() {
  shellcheck -f gcc -S warning "$@" 2>/dev/null \
    | sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: .*\[\(SC[0-9]*\)\]$/\1:\2/p' \
    | LC_ALL=C sort -u
}

# _sc_trim <line> -- strip a trailing `#` comment and surrounding whitespace.
_sc_trim() {
  _sc_t=$1
  _sc_t=${_sc_t%%#*}
  while [ "${_sc_t%[[:space:]]}" != "$_sc_t" ]; do _sc_t=${_sc_t%[[:space:]]}; done
  while [ "${_sc_t#[[:space:]]}" != "$_sc_t" ]; do _sc_t=${_sc_t#[[:space:]]}; done
  printf '%s' "$_sc_t"
}

# sc_compare <baseline> <findings> -- print one line per difference between the
# baseline and the findings:
#     new shellcheck finding: <file>:<CODE>   finding absent from the baseline
#     stale baseline entry: <file>:<CODE>     baseline entry that no longer fires
# Exit 0 when the two agree, 1 when they differ.
sc_compare() {
  _sc_base=$1
  _sc_find=$2
  _sc_rc=0

  while IFS= read -r _sc_line || [ -n "$_sc_line" ]; do
    [ -n "$_sc_line" ] || continue
    if ! grep -Fxq -- "$_sc_line" "$_sc_base"; then
      printf 'new shellcheck finding: %s\n' "$_sc_line"
      _sc_rc=1
    fi
  done < "$_sc_find"

  while IFS= read -r _sc_line || [ -n "$_sc_line" ]; do
    _sc_line=$(_sc_trim "$_sc_line")
    [ -n "$_sc_line" ] || continue
    if ! grep -Fxq -- "$_sc_line" "$_sc_find"; then
      printf 'stale baseline entry: %s\n' "$_sc_line"
      _sc_rc=1
    fi
  done < "$_sc_base"

  return "$_sc_rc"
}

# ---------------------------------------------------------------------------
# R1: every script parses
# ---------------------------------------------------------------------------

for _script in $SCRIPTS; do
  assert_file_exists "$_script" "script $_script is present"
  assert_exit_code 0 bash -n "$_script" "bash -n parses $_script"
done

# ---------------------------------------------------------------------------
# R2: the parse check rejects a broken script (negative control)
# ---------------------------------------------------------------------------

_tmp=$(make_tmpdir)

_broken="$_tmp/broken.sh"
cp dkms.sh "$_broken"
assert_exit_code 0 bash -n "$_broken" "control: an unmodified copy of dkms.sh parses"

printf 'if [ 1 = 1 ]; then\n' >> "$_broken"
_broken_out=$(bash -n "$_broken" 2>&1)
_broken_rc=$?
assert_ne 0 "$_broken_rc" "bash -n rejects a copy of dkms.sh with an unterminated if (rc=$_broken_rc)"
assert_contains "$_broken_out" "syntax error" "the rejection names the syntax error"

# ---------------------------------------------------------------------------
# R3/R4: shellcheck findings against the baseline
# ---------------------------------------------------------------------------

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'SKIP: shellcheck is not on PATH -- the baseline comparison (R3/R4) was not run; the bash -n checks above did run\n' >&2
else
  assert_file_exists "$BASELINE" "shellcheck baseline $BASELINE is present"

  _sc_version=$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')
  _baseline_version=$(sed -n 's/^# ShellCheck version used to build this baseline: //p' "$BASELINE")
  printf 'shellcheck %s; %s records version %s\n' "${_sc_version:-unknown}" "$BASELINE" "${_baseline_version:-none}"
  assert_ne "" "$_baseline_version" "$BASELINE records the shellcheck version used to build it"
  if [ -n "$_baseline_version" ] && [ "$_baseline_version" != "$_sc_version" ]; then
    printf 'NOTE: shellcheck %s is running but the baseline was built with %s; a version difference can change findings\n' "$_sc_version" "$_baseline_version" >&2
  fi

  # Every non-comment baseline line must be a well-formed `file:CODE` key, so a
  # typo cannot masquerade as a legitimate entry.
  _bad_keys=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=$(_sc_trim "$_line")
    [ -n "$_line" ] || continue
    if ! printf '%s\n' "$_line" | grep -Eq '^[^:]+:SC[0-9]+$'; then
      _bad_keys="$_bad_keys $_line"
    fi
  done < "$BASELINE"
  assert_eq "" "$_bad_keys" "every baseline entry is a well-formed file:CODE key"

  _findings="$_tmp/findings.txt"
  sc_findings $SCRIPTS > "$_findings"
  _diffs=$(sc_compare "$BASELINE" "$_findings")
  _diffs_rc=$?
  if [ -n "$_diffs" ]; then
    printf '%s\n' "$_diffs" >&2
  fi
  assert_eq 0 "$_diffs_rc" "shellcheck findings match $BASELINE (differences printed above)"

  # -------------------------------------------------------------------------
  # R5a: a finding that is not in the baseline is reported as new
  # -------------------------------------------------------------------------

  _new_script="$_tmp/new-finding.sh"
  cat > "$_new_script" <<'FIXTURE'
#!/usr/bin/env bash
set -u
printf '%s\n' $(date)
FIXTURE
  _new_findings="$_tmp/new-findings.txt"
  sc_findings "$_new_script" > "$_new_findings"
  assert_contains "$(cat "$_new_findings")" "SC2046" \
    "the R5a fixture produces a warning-severity unquoted-expansion finding"

  _new_diffs=$(sc_compare "$BASELINE" "$_new_findings")
  _new_rc=$?
  assert_ne 0 "$_new_rc" "a finding absent from the baseline fails the comparison"
  assert_contains "$_new_diffs" "new shellcheck finding:" "the new finding is reported"
  assert_contains "$_new_diffs" "SC2046" "the new finding names its code"

  # -------------------------------------------------------------------------
  # R5b: a baseline entry that no longer fires is reported as stale
  # -------------------------------------------------------------------------

  _dkms_findings="$_tmp/dkms-findings.txt"
  sc_findings dkms.sh > "$_dkms_findings"
  assert_contains "$(cat "$_dkms_findings")" "dkms.sh:SC2034" \
    "the R5b fixture still fires the entry that must not be reported stale"

  # The real dkms.sh findings, plus one code that cannot fire.
  _stale_base="$_tmp/stale-baseline.txt"
  {
    printf '# fixture baseline: the real dkms.sh findings plus one that cannot fire\n'
    cat "$_dkms_findings"
    printf 'dkms.sh:SC9999\n'
  } > "$_stale_base"

  _stale_diffs=$(sc_compare "$_stale_base" "$_dkms_findings")
  _stale_rc=$?
  assert_ne 0 "$_stale_rc" "a baseline entry that no longer fires fails the comparison"
  assert_eq "stale baseline entry: dkms.sh:SC9999" "$_stale_diffs" \
    "only the entry that cannot fire is reported stale"
fi

finish
