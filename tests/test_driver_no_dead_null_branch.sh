#!/usr/bin/env bash
#
# tests/test_driver_no_dead_null_branch.sh
#
# HDA-22: guard that the dead `codec == NULL` branch in
# cs_8409_capture_pcm_hook() (patch_cirrus/patch_cirrus_new84.h) stays gone.
#
# The branch cast `hinfo` (a struct hda_pcm_stream *) to a struct hda_codec *
# and dereferenced it.  It was unreachable: the function is registered only as
# spec->gen.pcm_capture_hook, and every caller passes a codec it has already
# dereferenced.  A positive control checks the rest of the function survives.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

SRC="$REPO_ROOT/patch_cirrus/patch_cirrus_new84.h"
FN_SIG='static void cs_8409_capture_pcm_hook('

assert_file_exists "$SRC" "the driver header patch_cirrus/patch_cirrus_new84.h exists"

# fn_body -- print the function from its signature to the first closing brace
# at column 0.
fn_body() {
  awk -v sig="$FN_SIG" '
    !in_fn && index($0, sig) { in_fn = 1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$SRC"
}

BODY=$(fn_body)
assert_ne "" "$BODY" "cs_8409_capture_pcm_hook() is found in new84.h"

# --- removed construct ---------------------------------------------------------

assert_not_contains "$BODY" 'if (codec == NULL)' \
  "the dead codec == NULL check is gone"
assert_not_contains "$BODY" '(struct hda_codec *) hinfo' \
  "the hinfo-to-hda_codec type-confusion cast is gone"
assert_not_contains "$BODY" 'CODEC NULL' \
  "the CODEC NULL diagnostics are gone"
assert_not_contains "$BODY" 'CODEC NOT NULL' \
  "the CODEC NOT NULL debug print is gone"

# --- positive control: remaining logic survives --------------------------------

assert_contains "$BODY" 'spec = codec->spec;' \
  "the function still loads spec from codec"
assert_contains "$BODY" 'if (action == HDA_GEN_PCM_ACT_OPEN)' \
  "the OPEN action branch survives"
assert_contains "$BODY" 'performing UNSOL responses' \
  "the unsolicited-response handling survives"

# --- survivors outside the function --------------------------------------------

assert_contains "$(cat "$SRC")" 'static int read_gpio_status_check(struct hda_codec *codec);' \
  "the read_gpio_status_check forward declaration survives"
assert_contains "$(cat "$SRC")" '#include "patch_cirrus_data84.h"' \
  "the USE_DATA include block survives"

finish
