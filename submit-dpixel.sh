#!/bin/bash
set -euo pipefail

PATCH=${1:?Usage: submit-dpixel.sh <patch_name> [start] [end]}
START=${2:-2022-06-01}
END=${3:-2023-06-01}
COMMIT=$(git ls-remote https://github.com/mtelvers/ocaml-tessera-tools.git HEAD | cut -f1)

SPECFILE=$(mktemp /tmp/dpixel-job.XXXXXX.spec)
trap "rm -f $SPECFILE" EXIT
m4 -DPATCH="$PATCH" -DSTART="$START" -DEND="$END" dpixel.spec.m4 > "$SPECFILE"

LOGDIR="${LOGDIR:-logs/dpixel}"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/${PATCH}_${START}_${END}.log"

echo "Submitting ${PATCH} (${START} to ${END})... -> $LOGFILE"
ocluster-client submit-obuilder \
  --connect /home/mtelvers/mtelvers.cap \
  --pool linux-arm64 \
  --secret edl_bearer_token:$HOME/.edl_bearer_token \
  --secret dpixel_token:$HOME/.dpixel_token \
  --local-file "$SPECFILE" \
  https://github.com/mtelvers/ocaml-tessera-tools.git "$COMMIT" \
  > "$LOGFILE" 2>&1
echo "Finished ${PATCH} (${START} to ${END}): exit $?"
