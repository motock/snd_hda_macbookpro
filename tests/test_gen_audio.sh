#!/usr/bin/env bash
#
# tests/test_gen_audio.sh -- tests/gen-test-audio.sh produces WAVs in the
# format the removed fixtures had (44100 Hz, 4 channels, 32-bit PCM), and the
# repository no longer tracks any WAV.

. "$(dirname "$0")/lib/assert.sh"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEN="$REPO_ROOT/tests/gen-test-audio.sh"

# Recorded from the deleted fixtures' RIFF headers.
EXPECT_CHANNELS=4
EXPECT_RATE=44100
EXPECT_BITS=32

# le <file> <offset> <bytes>: little-endian unsigned integer from a header.
le() {
  od -An -t u"$3" -j "$2" -N "$3" "$1" | tr -d ' '
}

assert_eq "0" "$(git -C "$REPO_ROOT" ls-files tests | grep -c '\.wav$')" \
  "no WAV file is tracked under tests/"

# Negative: neither tool available.
msg=$(PATH="" "$BASH" "$GEN" "$(make_tmpdir)/out" 2>&1)
rc=$?
assert_eq "1" "$rc" "generator exits 1 when neither sox nor ffmpeg exists"
assert_contains "$msg" "neither sox nor ffmpeg" "generator explains the missing tools"

if ! command -v sox > /dev/null 2>&1 && ! command -v ffmpeg > /dev/null 2>&1; then
  echo "SKIP generation checks: neither sox nor ffmpeg is on PATH"
  finish
fi

out=$(make_tmpdir)/audio
paths=$("$BASH" "$GEN" "$out")
assert_eq "0" "$?" "generator succeeds"

full="$out/StereoTest32.wav"
reduced="$out/StereoTest32_reduced_m24dB.wav"
assert_eq "$full"$'\n'"$reduced" "$paths" "generator prints both output paths"

for f in "$full" "$reduced"; do
  name=$(basename "$f")
  assert_file_exists "$f" "$name exists"
  assert_eq "1" "$([ -s "$f" ] && echo 1 || echo 0)" "$name is non-empty"
  assert_eq "RIFF" "$(head -c 4 "$f")" "$name starts with RIFF"
  assert_eq "WAVE" "$(dd if="$f" bs=1 skip=8 count=4 2> /dev/null)" "$name has WAVE form type"
  assert_eq "$EXPECT_CHANNELS" "$(le "$f" 22 2)" "$name channel count"
  assert_eq "$EXPECT_RATE" "$(le "$f" 24 4)" "$name sample rate"
  assert_eq "$EXPECT_BITS" "$(le "$f" 34 2)" "$name bit depth"
done

# Negative: default output dir must not be inside the repository.
assert_not_contains "${TMPDIR:-/tmp}/hda-test-audio" "$REPO_ROOT" "default output dir is outside the repo"

finish
