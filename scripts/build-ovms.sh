#!/bin/bash
# Build OVMS (python_off, mediapipe on) with Bazel inside the snapcraft build
# environment, against the OpenVINO runtime staged from openvino-toolkit-2404.
#
# Mirrors the "build" stage of upstream Dockerfile.ubuntu (v2026.4.1) with the
# OpenVINO / OpenCV / Azure SDK locations redirected from /opt/... to
# $CRAFT_STAGE.  Called from the ovms part's override-build.
set -euxo pipefail

: "${CRAFT_PART_BUILD:?}" "${CRAFT_STAGE:?}" "${CRAFT_ARCH_TRIPLET_BUILD_FOR:?}"
JOBS="${CRAFT_PARALLEL_BUILD_COUNT:-$(nproc)}"
BAZEL_VERSION="$(cat .bazelversion)"
PROJECT_VERSION="${OVMS_VERSION:?}"
BAZEL_FLAGS=(--strip=always --config=mp_on_py_off --//:distro=ubuntu)
triplet="$CRAFT_ARCH_TRIPLET_BUILD_FOR"

# --- Bazel (same installer as upstream; cached across rebuilds) -------------
bazel_prefix=/root/.cache/bazel-install/$BAZEL_VERSION
if [ ! -x "$bazel_prefix/bin/bazel" ]; then
  installer="bazel-$BAZEL_VERSION-installer-linux-x86_64.sh"
  curl -fsSL -o "/tmp/$installer" \
    "https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/$installer"
  bash "/tmp/$installer" --prefix="$bazel_prefix"
  rm -f "/tmp/$installer"
fi
export PATH="$bazel_prefix/bin:$PATH"
bazel --version

# --- OpenVINO runtime tree in the layout OVMS's Bazel files expect ----------
#   <root>/include/openvino/**      (core + genai headers)
#   <root>/lib/intel64/libopenvino.so, libopenvino_genai.so
ov_root="$CRAFT_PART_BUILD/ov-runtime"
rm -rf "$ov_root"
mkdir -p "$ov_root/include" "$ov_root/lib/intel64"
cp -a "$CRAFT_STAGE/usr/include/openvino" "$ov_root/include/"
cp -a "$CRAFT_STAGE/usr/runtime/include/openvino/genai" "$ov_root/include/openvino/"
for lib in libopenvino.so libopenvino_genai.so libopenvino_tokenizers.so; do
  cp -L "$CRAFT_STAGE/usr/lib/$triplet/$lib" "$ov_root/lib/intel64/$lib"
done
# CMake package configs (used by rules_foreign_cc builds, e.g. mediapipe's
# model_api, via -DOpenVINO_DIR=/opt/intel/openvino/runtime/cmake). Wrappers
# include the toolkit's real config files so their relative import prefix
# still resolves to $CRAFT_STAGE/usr.
mkdir -p "$ov_root/cmake"
ov_cmake="$(ls -d "$CRAFT_STAGE"/usr/lib/$triplet/cmake/openvino2026*)"
for f in OpenVINOConfig.cmake OpenVINOConfig-version.cmake; do
  echo "include(\"$ov_cmake/$f\")" > "$ov_root/cmake/$f"
done
for f in OpenVINOGenAIConfig.cmake OpenVINOGenAIConfigVersion.cmake; do
  echo "include(\"$CRAFT_STAGE/usr/runtime/cmake/$f\")" > "$ov_root/cmake/$f"
done

# --- Upstream build files hardcode /opt/intel/openvino/runtime, /opt/opencv
# and /azure-sdk-install (WORKSPACE and mediapipe's model_api cmake build).
# Point those paths at the staged dependencies inside the (disposable)
# snapcraft build instance instead of patching every reference.
mkdir -p /opt/intel/openvino
ln -sfn "$ov_root" /opt/intel/openvino/runtime
ln -sfn "$CRAFT_STAGE/opt/opencv" /opt/opencv
ln -sfn "$CRAFT_STAGE/opt/azure-sdk" /azure-sdk-install
export OpenVINO_DIR=/opt/intel/openvino/runtime/cmake

# Version strings (Dockerfile.ubuntu)
sed -i -e "s|REPLACE_PROJECT_VERSION|${PROJECT_VERSION}|g" \
       -e "s|REPLACE_BAZEL_BUILD_FLAGS|${BAZEL_FLAGS[*]}|g" src/version.hpp

export TF_SYSTEM_LIBS=curl
export LD_LIBRARY_PATH="$ov_root/lib/intel64:$CRAFT_STAGE/usr/lib/$triplet:$CRAFT_STAGE/opt/opencv/lib:$CRAFT_STAGE/opt/azure-sdk/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OPENVINO_TOKENIZERS_PATH_GENAI="$ov_root/lib/intel64/libopenvino_tokenizers.so"

# --- python3 switching, as upstream: 3.10 for deps + TF, 3.12 for ovms ------
restore_python() { ln -sf python3.12 /usr/bin/python3; }
trap restore_python EXIT
ln -sf python3.10 /usr/bin/python3
python3 --version
bazel build --jobs="$JOBS" "${BAZEL_FLAGS[@]}" //:ovms_dependencies
bazel build --jobs="$JOBS" "${BAZEL_FLAGS[@]}" @org_tensorflow//tensorflow/core:framework
restore_python
python3 --version

bazel build --jobs="$JOBS" "${BAZEL_FLAGS[@]}" //src:ovms
bazel build --jobs="$JOBS" "${BAZEL_FLAGS[@]}" //third_party:espeak_ng //third_party:espeak_ng_data

./bazel-bin/src/ovms --version
