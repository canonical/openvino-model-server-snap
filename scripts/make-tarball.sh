#!/bin/bash
# Turn an openvino-model-server-2404 snap into the release tarball:
#   openvino-model-server-2404_<version>_<arch>.tar.gz  (+ .sha256)
# The tarball holds the snap's ovms/ and gpu-runtime/ trees unchanged, so it
# has the same bits as the snap.
#
# Usage: scripts/make-tarball.sh <snap-file> <out-dir> [expected-version]
set -euo pipefail
snap_file="$(realpath "${1:?usage: $0 <snap-file> <out-dir> [expected-version]}")"
out_dir="$(realpath -m "${2:?}")"
expected="${3:-}"

meta="$(unsquashfs -cat "$snap_file" meta/snap.yaml)"
version="$(echo "$meta" | awk '/^version:/ {gsub(/["\x27]/, "", $2); print $2}')"
arch="$(echo "$meta" | awk '/^architectures:/ {getline; gsub(/[- ]/, ""); print}')"
if [ -n "$expected" ] && [ "$version" != "$expected" ]; then
  echo "ERROR: snap version '$version' does not match expected '$expected'" >&2
  exit 1
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
unsquashfs -q -d "$work/root" "$snap_file" ovms gpu-runtime >/dev/null
[ -x "$work/root/ovms/bin/ovms" ] || { echo "ERROR: ovms/bin/ovms missing in snap" >&2; exit 1; }
[ -d "$work/root/gpu-runtime" ] || { echo "ERROR: gpu-runtime missing in snap" >&2; exit 1; }

name="openvino-model-server-2404_${version}_${arch}.tar.gz"
mkdir -p "$out_dir"
tar -C "$work/root" --owner=0 --group=0 --sort=name -czf "$out_dir/$name" ovms gpu-runtime
( cd "$out_dir" && sha256sum "$name" > "$name.sha256" && cat "$name.sha256" )
echo "$out_dir/$name"
