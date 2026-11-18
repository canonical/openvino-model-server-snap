#!/bin/bash
# Assemble the relocatable OVMS tree in $CRAFT_PART_INSTALL/ovms. Called from
# the ovms part's override-build, after build-ovms.sh.
#
# The layout follows the upstream ovms_ubuntu24_*_python_off tarball:
#   ovms/bin/ovms
#   ovms/lib/*.so*                 OVMS, OpenCV, Azure SDK, libcurl/libxml2 ...
#   ovms/share/espeak-ng-data
#   ovms/LICENSE  ovms/thirdparty-licenses/  ovms/metadata.json
# The OpenVINO runtime and TBB are added to ovms/lib by the openvino-runtime
# and onetbb parts. Every ELF file gets a RUNPATH ($ORIGIN-relative) so the
# tree works wherever it is staged, mounted or unpacked, without
# LD_LIBRARY_PATH.
set -euxo pipefail
: "${CRAFT_PART_BUILD:?}" "${CRAFT_PART_INSTALL:?}" "${CRAFT_STAGE:?}" "${OVMS_VERSION:?}"
out="$CRAFT_PART_INSTALL/ovms"
src="$CRAFT_PART_BUILD"
triplet="$CRAFT_ARCH_TRIPLET_BUILD_FOR"
mkdir -p "$out/bin" "$out/lib" "$out/thirdparty-licenses"

# Bazel-built shared libraries (same filters as upstream create_package.sh)
find "$src"/bazel-out/k8-*/bin -iname '*.so*' ! -type d ! -name "libgtest.so" \
  ! -name "*params" ! -name "*.hana.*" ! -name "py_generate_pipeline.cpython*" \
  ! -name "lib_node_*" ! -name "libazure-*" ! -name "pyovms.so" \
  ! -path "*/_solib_k8/*" ! -path "*test_python_binding*" ! -name "*libpython*" \
  -exec cp -vP {} "$out/lib/" \;
( cd "$out/lib" && rm -fv libcurl.so* libssl.so libexternal_Szlib_Slibzlib.so \
    libinference_calculator_cc_proto.so libzlib.so libface_detection_cc_proto.so \
    libface_detection_options_registry.so libinference_calculator_options_registry.so \
    libsrc_Slibovms_Ushared.so libprediction_service_proto.so-2.params \
    libovms_shared.so-2.params _crypt.cpython-*.so _testclinic.cpython-*.so )
# The OpenVINO runtime and TBB come from the openvino-runtime and onetbb parts
rm -fv "$out"/lib/libopenvino* "$out"/lib/libtbb*

# Azure SDK and OpenCV (built in their own parts)
cp -vP "$CRAFT_STAGE"/opt/azure-sdk/lib/libazure-*.so* "$out/lib/"
cp -vP "$CRAFT_STAGE"/opt/opencv/lib/*.so* "$out/lib/"

# stage-packages (libcurl4, libxml2 and the dependencies core24 lacks): move
# them from usr/lib/<triplet> into ovms/lib, and keep their copyright files.
if [ -d "$CRAFT_PART_INSTALL/usr/lib/$triplet" ]; then
  find "$CRAFT_PART_INSTALL/usr/lib/$triplet" -maxdepth 1 -name '*.so*' \
    -exec mv -v {} "$out/lib/" \;
fi
if [ -d "$CRAFT_PART_INSTALL/usr/share/doc" ]; then
  mkdir -p "$out/thirdparty-licenses/debian"
  for d in "$CRAFT_PART_INSTALL"/usr/share/doc/*/; do
    [ -f "$d/copyright" ] && cp "$d/copyright" "$out/thirdparty-licenses/debian/$(basename "$d").copyright"
  done
fi
find "$CRAFT_PART_INSTALL" -mindepth 1 -maxdepth 1 ! -name ovms -exec rm -rf {} +

# espeak-ng data + soname links
espeak_data="$(find "$src"/bazel-out/k8-*/bin/external/espeak_ng -type d -name 'espeak-ng-data' | head -n1 || true)"
if [ -n "$espeak_data" ]; then
  mkdir -p "$out/share"
  cp -rL "$espeak_data" "$out/share/"
  chmod -R u+w "$out/share/espeak-ng-data"
fi
espeak_real="$(find "$out/lib" -maxdepth 1 -type f -name 'libespeak-ng.so.*' -printf '%f\n' | sort -V | tail -n1 || true)"
if [ -n "$espeak_real" ]; then
  ( cd "$out/lib" && rm -f libespeak-ng.so &&
    if [ "$espeak_real" != libespeak-ng.so.1 ]; then rm -f libespeak-ng.so.1; ln -s "$espeak_real" libespeak-ng.so.1; fi &&
    ln -s libespeak-ng.so.1 libespeak-ng.so )
fi

# ovms binary and RUNPATHs
cp -v "$src/bazel-bin/src/ovms" "$out/bin/ovms"
chmod u+w "$out/bin/ovms"
patchelf --remove-rpath "$out/bin/ovms"
patchelf --set-rpath '$ORIGIN/../lib' "$out/bin/ovms"
find "$out/lib" -maxdepth 1 -type f -iname '*.so*' -exec chmod u+w {} +
find "$out/lib" -maxdepth 1 -type f -iname '*.so*' -exec patchelf --remove-rpath {} +
find "$out/lib" -maxdepth 1 -type f -iname '*.so*' -exec patchelf --set-rpath '$ORIGIN' {} +

# Licenses
cp -v release_files/LICENSE "$out/"
cp -rv release_files/thirdparty-licenses/. "$out/thirdparty-licenses/"
mkdir -p "$out/thirdparty-licenses/opencv"
cp -v "$CRAFT_STAGE"/opt/opencv/share/licenses/opencv4/* "$out/thirdparty-licenses/opencv/" || true
espeak_lic="$(find "$src"/bazel-out/k8-*/bin/external/espeak_ng -type f \( -name 'COPYING*' -o -name 'LICENSE*' \) | head -n1 || true)"
[ -n "$espeak_lic" ] && cp -v "$espeak_lic" "$out/thirdparty-licenses/espeak-ng.LICENSE.txt"

# Sanity check against the staged runtime: the binary must start and report
# the toolkit's OpenVINO version. LD_LIBRARY_PATH is needed only here, because
# the OpenVINO libraries are still in the stage dir, not next to ovms/lib.
version_out="$(LD_LIBRARY_PATH="$CRAFT_STAGE/ovms/lib" "$out/bin/ovms" --version)"
echo "$version_out"
ov_backend="$(echo "$version_out" | awk '/OpenVINO backend/ {print $3}')"
genai_ver="$(find "$CRAFT_STAGE/ovms/lib" -maxdepth 1 -name 'libopenvino_genai.so.*.*' -printf '%f\n' | sed 's/libopenvino_genai.so.//' | sort -V | tail -n1)"
cat > "$out/metadata.json" <<EOF
{
    "PROJECT_VERSION": "${OVMS_VERSION}",
    "OPENVINO backend": "${ov_backend}",
    "OPENVINO GenAI": "${genai_ver}",
    "OPENVINO source": "openvino-toolkit-2404 snap (2026/stable)",
    "oneTBB": "2021.13.1 (tpause backoff disabled)",
    "BAZEL_BUILD_FLAGS": "--strip=always --config=mp_on_py_off --//:distro=ubuntu",
    "BASE": "core24 / Ubuntu 24.04"
}
EOF
cat "$out/metadata.json"
