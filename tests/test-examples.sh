#!/bin/bash
# Build, install and smoke-test the three consumer examples against a LOCAL
# openvino-model-server-2404 snap and tarball, before anything is published.
# The store and release URLs in a temporary copy of each example are replaced
# with the local files. The repo itself is not modified.
#
# Usage: [DEVICES="CPU GPU NPU"] tests/test-examples.sh <snap-file> <tarball> [example...]
#   examples: stage-snap content tarball (default: all)
#   DEVICES:  devices to smoke-test each example on (default: CPU)
# Requires snapcraft (LXD) and sudo (snap install/connect). To test on a host
# without snapcraft, build the example snaps elsewhere and set PREBUILT=<dir>
# containing ovms-consumer-<example>_*.snap.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
snap_file="$(realpath "${1:?usage: $0 <snap-file> <tarball> [example...]}")"
tarball="$(realpath "${2:?}")"
shift 2
examples=("$@")
[ $# -eq 0 ] && examples=(stage-snap content tarball)
work="$(mktemp -d "${TMPDIR:-/tmp}/ovms-examples.XXXXXX")"
echo "work dir: $work"
results=()

for ex in "${examples[@]}"; do
  echo "===== $ex"
  d="$work/$ex"; cp -r "$here/examples/$ex" "$d"
  y="$d/snap/snapcraft.yaml"
  case "$ex" in
    stage-snap)
      # stage-snaps only takes store names. A part with source-type: snap
      # unpacks the local file the same way.
      cp "$snap_file" "$d/ovms.snap"
      sed -i '0,/    plugin: nil/s//    plugin: dump/; s|    stage-snaps:|    source: ovms.snap\n    source-type: snap\n    #stage-snaps:|; s|^      - openvino-model-server-2404/.*|      #&|' "$y"
      ;;
    content)
      sudo snap install --dangerous "$snap_file"
      # snapcraft installs default-provider from the store while building.
      sed -i '/default-provider:/d' "$y"
      ;;
    tarball)
      cp "$tarball" "$d/ovms.tar.gz"
      sed -i "s|^    source: https://.*|    source: ovms.tar.gz|" "$y"
      ;;
  esac
  if [ -n "${PREBUILT:-}" ]; then
    cp "$PREBUILT"/ovms-consumer-"$ex"_*.snap "$d/"
  else
    ( cd "$d" && snapcraft pack )
  fi
  name="ovms-consumer-$ex"; [ "$ex" = stage-snap ] && name=ovms-consumer-stage-snap
  sudo snap install --dangerous "$d"/*.snap
  if [ "$ex" = content ]; then
    sudo snap connect "$name:openvino-model-server" openvino-model-server-2404:openvino-model-server
    sudo snap connect "$name:intel-gpu-runtime" openvino-model-server-2404:intel-gpu-runtime
  fi
  # NPU libraries: connected only if the intel-npu-driver snap is installed.
  if snap list intel-npu-driver >/dev/null 2>&1; then
    sudo snap connect "$name:npu-libs" intel-npu-driver:npu-libs
  fi
  for dev in ${DEVICES:-CPU}; do
    if DEVICE=$dev PORT=$((18100 + ${#results[@]})) "$here/tests/smoke-test.sh" "$name.ovms"; then
      results+=("PASS $ex $dev")
    else
      results+=("FAIL $ex $dev")
    fi
  done
done
printf '%s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q FAIL
