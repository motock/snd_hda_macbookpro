#!/usr/bin/env bash
#
# tests/test_docs_consistency.sh -- machine-checkable invariants between
# README.md and NOTES.md:
#   1. each doc's kernel-range sentence names the same boundary (6.17);
#   2. every install*.sh script a doc mentions exists in the repo root.

set -u

. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# print the kernel boundary (x.y) named by each "x.y and later" phrase of doc $1
kernel_boundary() {
  grep -oE '[0-9]+\.[0-9]+ and later' "$1" | grep -oE '^[0-9]+\.[0-9]+' | sort -u
}

# print each install*.sh script named in doc $1 that is missing from dir $2
missing_scripts() {
  local s
  grep -oE 'install[A-Za-z0-9._-]*\.sh' "$1" | sort -u | while IFS= read -r s; do
    [ -e "$2/$s" ] || printf '%s\n' "$s"
  done
}

# --- positive: the real docs --------------------------------------------------

readme_boundary=$(kernel_boundary "$REPO_ROOT/README.md")
notes_boundary=$(kernel_boundary "$REPO_ROOT/NOTES.md")
assert_eq "6.17" "$readme_boundary" "README kernel-range sentence names the 6.17 boundary"
assert_eq "$readme_boundary" "$notes_boundary" "NOTES names the same kernel boundary as README"
assert_eq "" "$(missing_scripts "$REPO_ROOT/README.md" "$REPO_ROOT")" "every installer README names exists"
assert_eq "" "$(missing_scripts "$REPO_ROOT/NOTES.md" "$REPO_ROOT")" "every installer NOTES names exists"

# --- negative: fixtures -------------------------------------------------------

fixture_dir=$(make_tmpdir)
printf 'Run install.cirrus.driver.bogus.sh for kernels 6.17 and later.\n' > "$fixture_dir/doc.md"
assert_eq "install.cirrus.driver.bogus.sh" "$(missing_scripts "$fixture_dir/doc.md" "$REPO_ROOT")" "a nonexistent installer is reported"

printf 'Kernels 6.16 and later are supported.\n' > "$fixture_dir/other.md"
assert_ne "$readme_boundary" "$(kernel_boundary "$fixture_dir/other.md")" "a different boundary is detected"

printf 'no kernel sentence\n' > "$fixture_dir/none.md"
assert_eq "" "$(kernel_boundary "$fixture_dir/none.md")" "a doc without a kernel sentence yields no boundary"

finish
