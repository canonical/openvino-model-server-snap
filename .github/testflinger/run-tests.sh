#!/bin/bash
# Run on the test device by job-def.yaml. Runs the repository's tests against
# the installed openvino-model-server-2404 snap:
#   - tests/check-tree.sh on the snap's ovms/ tree
#   - tests/smoke-test.sh (confined) on CPU, GPU and NPU
# Writes one PASS/FAIL line per test to <out-dir>/results.txt, with each
# test's log next to it, and always exits 0 so that both runs are collected.
# The workflow decides pass/fail from results.txt.
#
# Usage: run-tests.sh <out-dir>
set -uo pipefail
out="${1:?usage: $0 <out-dir>}"
here="$(cd "$(dirname "$0")" && pwd)"
snap_name=openvino-model-server-2404
mkdir -p "$out"
results="$out/results.txt"
: > "$results"

{
  uname -a
  snap version
  snap list "$snap_name" intel-npu-driver
  snap connections "$snap_name"
  ls -l /dev/dri /dev/accel 2>&1
  id
} > "$out/system.log" 2>&1

if bash "$here/tests/check-tree.sh" "/snap/$snap_name/current/ovms" > "$out/check-tree.log" 2>&1; then
  echo "PASS check-tree" >> "$results"
else
  echo "FAIL check-tree" >> "$results"
fi

for device in ${DEVICES:-CPU GPU NPU}; do
  log="$out/smoke-$device.log"
  if DEVICE="$device" timeout 1800 bash "$here/tests/smoke-test.sh" "$snap_name.ovms" > "$log" 2>&1; then
    echo "PASS smoke $device" >> "$results"
  else
    echo "FAIL smoke $device" >> "$results"
  fi
done

cat "$results"
exit 0
