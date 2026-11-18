#!/bin/bash
# Check that an OVMS tree is self-contained and relocatable. Every NEEDED
# library of bin/ovms and of each ovms/lib/*.so* must resolve either inside the
# tree (through RUNPATH) or to a core24 base library. LD_LIBRARY_PATH isn't
# used, and no OpenVINO/TBB/OpenCV library may come from anywhere else.
#
# Usage: tests/check-tree.sh <ovms-dir>   (the directory containing bin/ and lib/)
# Runs on any amd64 host with the core24 snap installed. The core24 loader and
# library dirs are used, so the host's own libraries can't mask a missing one.
set -euo pipefail
root="$(realpath "${1:?usage: $0 <ovms-dir>}")"
core="$(realpath /snap/core24/current)"
T=x86_64-linux-gnu
loader="$core/lib64/ld-linux-x86-64.so.2"
[ -x "$root/bin/ovms" ] || { echo "FAIL: $root/bin/ovms missing"; exit 1; }
[ -x "$loader" ] || { echo "FAIL: core24 snap not installed ($loader)"; exit 1; }

fail=0
check() {   # $1 = ELF file
  local out
  # --library-path works like LD_LIBRARY_PATH: it is searched before RUNPATH.
  # It lists only core24 base-system dirs, which hold none of the tree's own
  # libraries, so it can't mask them. It just stands in for the host's libc
  # and friends.
  out="$(env -i "$loader" --library-path "$core/lib/$T:$core/usr/lib/$T" --list "$1" 2>&1)" || true
  if echo "$out" | grep -q "not found"; then
    echo "FAIL: $1"; echo "$out" | grep "not found"; fail=1
  fi
  if echo "$out" | grep -E "=> /" | grep -vE "=> ($root/|$core/)" | grep .; then
    echo "FAIL: $1 resolves libraries outside the tree and core24"; fail=1
  fi
  if echo "$out" | grep -E "(openvino|tbb|opencv)" | grep -v "=> $root/" | grep .; then
    echo "FAIL: $1 resolves OpenVINO/TBB/OpenCV outside the tree"; fail=1
  fi
}

check "$root/bin/ovms"
while IFS= read -r -d '' f; do check "$f"; done < <(find "$root/lib" -type f -name '*.so*' -print0)

echo "=== ovms --version"
env -i "$loader" --library-path "$core/lib/$T:$core/usr/lib/$T" "$root/bin/ovms" --version
echo "=== ovms resolution (bin/ovms)"
env -i "$loader" --library-path "$core/lib/$T:$core/usr/lib/$T" --list "$root/bin/ovms" \
  | grep -E "openvino|tbb|opencv|OpenCL" | sed "s|$root|<tree>|"
for lib in libopenvino_intel_cpu_plugin.so libopenvino_intel_gpu_plugin.so libopenvino_intel_npu_plugin.so; do
  ls "$root"/lib/openvino-*/"$lib" >/dev/null 2>&1 || { echo "FAIL: plugin $lib missing"; fail=1; }
done
if objdump -d "$root"/lib/libtbb.so.12.* | grep -q tpause; then
  echo "FAIL: libtbb contains tpause (see canonical/openvino-toolkit-snap#54)"; fail=1
fi
[ "$fail" = 0 ] && echo "PASS: tree is self-contained"
exit "$fail"
