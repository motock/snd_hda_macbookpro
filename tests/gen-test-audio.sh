#!/usr/bin/env bash
#
# tests/gen-test-audio.sh -- generate the speaker test waveforms used by the
# manual aplay steps in tests/README.  The WAVs are not tracked in git.
#
# Usage: tests/gen-test-audio.sh [OUTDIR]
#
# Writes two 10 s, 440 Hz sine files into OUTDIR (default:
# ${TMPDIR:-/tmp}/hda-test-audio) and prints their paths, one per line:
#   StereoTest32.wav                full volume (never play with -D hw:0,0)
#   StereoTest32_reduced_m24dB.wav  same, -24 dB (safe for -D hw:0,0)
# Format matches the original fixtures: 44100 Hz, 4 channels, 32-bit PCM.
# Uses sox if present, otherwise ffmpeg.

set -eu

RATE=44100
CHANNELS=4
BITS=32
SECONDS_LONG=10
REDUCED_DB=-24

outdir=${1:-${TMPDIR:-/tmp}/hda-test-audio}

if command -v sox > /dev/null 2>&1; then
  tool=sox
elif command -v ffmpeg > /dev/null 2>&1; then
  tool=ffmpeg
else
  echo "gen-test-audio.sh: neither sox nor ffmpeg found on PATH; install one of them" >&2
  exit 1
fi

mkdir -p "$outdir"

# gen <out.wav> <gain_db>
gen() {
  local out=$1 gain=$2
  if [ "$tool" = sox ]; then
    sox -n -r "$RATE" -c "$CHANNELS" -b "$BITS" "$out" \
      synth "$SECONDS_LONG" sine 440 gain "$gain"
  else
    ffmpeg -nostdin -loglevel error -y \
      -f lavfi -i "sine=frequency=440:duration=$SECONDS_LONG:sample_rate=$RATE" \
      -af "volume=${gain}dB" -ac "$CHANNELS" -c:a "pcm_s${BITS}le" "$out"
  fi
  printf '%s\n' "$out"
}

# sox's default synth level is full scale; keep full volume at 0 dB gain.
gen "$outdir/StereoTest32.wav" 0
gen "$outdir/StereoTest32_reduced_m24dB.wav" "$REDUCED_DB"
