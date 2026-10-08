#!/usr/bin/env bash
#
# tests/test_driver_spec_leak.sh
#
# HDA-25: cs8409_apple() must not leak the spec it allocates.
#
# cs8409_apple() (patch_cirrus/cirrus_apple.h) calls
# cs8409_apple_alloc_spec(), which kzalloc()s a struct cs8409_apple_spec and
# publishes it as codec->spec.  The function then has several early exits.  Any
# exit taken before the codec takes ownership must free that spec, because the
# HDA core does not: on probe failure hda_codec_driver_probe()
# (sound/hda/common/bind.c) jumps to error_module_put, which only module_put()s
# the owner -- driver->ops->remove() is not called, so nothing frees
# codec->spec.
#
# The fix routes every pre-ownership exit through one cleanup label
# (`err_free_spec:`) that does `kfree(spec); codec->spec = NULL; return err;`.
#
# The body of cs8409_apple() is bounded with awk (signature line to the first
# closing brace at column 0) so that a free anywhere else in the file cannot
# satisfy the checks.  Five checks:
#
#   1. the cleanup label exists and its block frees the spec and clears
#      codec->spec;
#   2. every negative-constant `return` after the allocation line is preceded,
#      within its own brace block, by a free of the spec;
#   3. the unknown-subsystem-id error path (the block holding `-ENODEV`) frees
#      the spec or jumps to the cleanup label;
#   4. the unknown-subsystem-id diagnostic is still reported on that path;
#   5. positive control: the success `return 0;` is NOT preceded by a free in
#      its block -- from there on the codec owns the spec and its remove path
#      frees it.
#
# This is a static check.  Whether the leak is actually gone can only be
# confirmed on hardware with kmemleak; see the recipe in tests/README.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

SRC="$REPO_ROOT/patch_cirrus/cirrus_apple.h"

FN_SIG='static int cs8409_apple(struct hda_codec *codec)'
ALLOC_CALL='cs8409_apple_alloc_spec(codec)'
CLEANUP_LABEL='err_free_spec'
UNKNOWN_MSG='UNKNOWN subsystem id'

assert_file_exists "$SRC" "the driver header patch_cirrus/cirrus_apple.h exists"

# scan_fn <file> -- print the analysis of cs8409_apple() as key=value lines.
scan_fn() {
  awk -v sig="$FN_SIG" -v alloc="$ALLOC_CALL" -v label="$CLEANUP_LABEL" -v umsg="$UNKNOWN_MSG" '
    # Strip string literals and // comments so braces in either cannot skew the
    # brace-depth tracking that defines "the same block".
    function strip(s,   out,i,c,n,instr,esc) {
      out = ""; instr = 0; esc = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") instr = 0
          continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "/" && substr(s, i + 1, 1) == "/") break
        out = out c
      }
      return out
    }
    function is_free(s) {
      return (index(s, "kfree(spec)") || index(s, "kfree(codec->spec)") ||
              index(s, "cs_8409_apple_remove(codec)") ||
              index(s, "snd_hda_gen_remove(codec)") ||
              index(s, "snd_hda_gen_free(codec)"))
    }
    function is_goto_label(s) {
      return (s ~ ("goto[[:space:]]+" label "[[:space:]]*;"))
    }
    !in_fn && index($0, sig) == 1 && $0 !~ /;[[:space:]]*$/ {
      in_fn = 1; found = 1; next
    }
    in_fn && /^}/ { endline = NR; in_fn = 0; next }
    in_fn {
      raw[NR] = $0
      code[NR] = strip($0)
      before[NR] = depth
      # Innermost enclosing block start *at this line*, recorded before this
      # line opens/closes any braces (blockstart[] alone goes stale).
      encl[NR] = blockstart[depth]
      n = length(code[NR])
      for (i = 1; i <= n; i++) {
        ch = substr(code[NR], i, 1)
        if (ch == "{") { depth++; blockstart[depth] = NR }
        else if (ch == "}") depth--
      }
      after[NR] = depth
      if (is_free(code[NR])) free[NR] = 1
      if (code[NR] ~ /return[[:space:]]+-[A-Za-z0-9_]+[[:space:]]*;/) negret[NR] = 1
      if (code[NR] ~ /return[[:space:]]+0[[:space:]]*;/) succret[NR] = 1
      if (index(code[NR], alloc)) allocline = NR
      if (code[NR] ~ ("^[[:space:]]*" label ":")) labelline = NR
      if (index(raw[NR], umsg)) umsgline[NR] = 1
      if (index(code[NR], "-ENODEV")) enodline[NR] = 1
    }
    END {
      printf "found=%d\n", found
      printf "alloc=%d\n", allocline
      printf "label=%d\n", labelline

      lf = 0; ln = 0
      if (labelline) {
        for (j = labelline + 1; j <= endline; j++) {
          if (code[j] ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:/) break
          if (index(code[j], "kfree(spec)")) lf = 1
          if (code[j] ~ /codec->spec[[:space:]]*=[[:space:]]*NULL/) ln = 1
        }
      }
      printf "label_free=%d\n", lf
      printf "label_null=%d\n", ln

      nbad = 0; bad = ""
      for (j = allocline + 1; j <= endline; j++) {
        if (!negret[j]) continue
        bs = encl[j]; ok = 0
        for (k = bs; k < j; k++) if (free[k]) ok = 1
        if (!ok) { nbad++; bad = bad " " j }
      }
      printf "bad_returns=%d\n", nbad
      printf "bad_lines=%s\n", bad

      # Unknown-subsystem-id error path: the block that returns -ENODEV.
      us = 0; nmsg = 0; nenod = 0
      for (j = allocline + 1; j <= endline; j++) {
        if (!enodline[j]) continue
        nenod++
        d = before[j]; bs = encl[j]; be = endline
        for (k = j + 1; k <= endline; k++)
          if (after[k] < d) { be = k; break }
        for (k = bs; k <= be; k++) {
          if (free[k]) us = 1
          if (is_goto_label(code[k])) us = 1
          if (umsgline[k]) nmsg = 1
        }
      }
      printf "unknown_safe=%d\n", us
      printf "unknown_msg=%d\n", nmsg
      printf "enod_count=%d\n", nenod

      sf = 0
      for (j = allocline + 1; j <= endline; j++) {
        if (!succret[j]) continue
        bs = encl[j]
        for (k = bs; k < j; k++) if (free[k]) sf = 1
      }
      printf "success_free=%d\n", sf
    }
  ' "$1"
}

report=$(scan_fn "$SRC")

field() {
  printf '%s\n' "$report" | sed -n "s/^$1=//p"
}

assert_eq 1 "$(field found)" \
  "cs8409_apple() is defined in $SRC"
assert_ne 0 "$(field alloc)" \
  "cs8409_apple() allocates the spec with $ALLOC_CALL"
assert_ne 0 "$(field label)" \
  "cs8409_apple() has a '$CLEANUP_LABEL:' cleanup label"
assert_eq 1 "$(field label_free)" \
  "the $CLEANUP_LABEL: label frees the spec with kfree(spec)"
assert_eq 1 "$(field label_null)" \
  "the $CLEANUP_LABEL: label clears codec->spec"
assert_eq 0 "$(field bad_returns)" \
  "every negative return after the allocation is preceded by a free of the spec (offending lines:$(field bad_lines))"
assert_ne 0 "$(field enod_count)" \
  "cs8409_apple() still returns -ENODEV for an unknown subsystem id"
assert_eq 1 "$(field unknown_msg)" \
  "the unknown-subsystem-id path still reports '$UNKNOWN_MSG'"
assert_eq 1 "$(field unknown_safe)" \
  "the unknown-subsystem-id path frees the spec or jumps to $CLEANUP_LABEL:"
assert_eq 0 "$(field success_free)" \
  "the success return does not free the spec (the codec owns it from there)"

finish
