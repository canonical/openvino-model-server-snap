# openvino-model-server-2404

OpenVINO Model Server (OVMS) built from source against the OpenVINO runtime of
the [openvino-toolkit-2404](https://snapcraft.io/openvino-toolkit-2404)
snap (2026/stable), for use by inference snaps.

| Component        | Version / source                                              |
|------------------|---------------------------------------------------------------|
| OVMS             | 2026.4.1 (`--config=mp_on_py_off`, MediaPipe on, Python off)  |
| OpenVINO         | 2026.4.1, GenAI + tokenizers 2026.4.1.0, from openvino-toolkit-2404 |
| oneTBB           | 2021.13.1 built with the `tpause` backoff disabled ([openvino-toolkit-snap#54](https://github.com/canonical/openvino-toolkit-snap/issues/54)) |
| OpenCV           | 4.14.0 (same module set as upstream OVMS)                     |
| Base             | core24                                                        |

## What's in the snap

Every delivery mechanism ships the same two relocatable directories:

```
ovms/
  bin/ovms
  bin/ovms-env              optional wrapper: adds the GPU runtime and NPU
                            libraries to the library path, then runs ovms
  lib/                      OVMS, OpenVINO, plugins (lib/openvino-2026.4.1/), TBB,
                            OpenCV, Azure SDK, libcurl, libxml2, ...
  share/espeak-ng-data/
  LICENSE  thirdparty-licenses/  metadata.json
gpu-runtime/                Intel GPU user-space runtime from
                            intel-compute-runtime-bundle 26.22.38646.4:
  usr/lib/x86_64-linux-gnu/ OpenCL ICD loader, IGC, Level Zero GPU driver, GMM,
                            intel-opencl/ (current + legacy platforms)
  etc/OpenCL/vendors/       ICD files using bare library names (relocatable)
  VERSION
```

`ovms/` works on its own for CPU: all ELF files use `$ORIGIN`-relative
RUNPATHs, so `ovms/bin/ovms` runs from anywhere with no `LD_LIBRARY_PATH`.

## GPU and NPU

Like upstream OVMS, the snap runs inference on Intel GPUs and NPUs. Use
`--target_device GPU` or `NPU`.

| Device | Driver source | How `ovms` finds it |
|---|---|---|
| GPU | bundled `gpu-runtime/` (or one you supply) | `ovms-env` adds `<ovms>/../gpu-runtime` to the library path and sets `OCL_ICD_VENDORS` |
| NPU | the `intel-npu-driver` snap, through its `npu-libs` content slot (same as existing inference snaps) | `ovms-env` adds `<ovms>/../npu-libs` to the library path |

The kernel drivers come from the host. The snap needs the `opengl` plug for
GPU device access, and the `accel` interface (provided by snapd, auto-connected)
for the NPU device node `/dev/accel/accel*`.

Using the standalone snap:

```
sudo snap install openvino-model-server-2404 --edge
sudo snap install intel-npu-driver --edge            # NPU only
sudo snap connect openvino-model-server-2404:npu-libs  intel-npu-driver:npu-libs
# Models live in the snap's $SNAP_USER_DATA (~/snap/openvino-model-server-2404/current).
# The snap has no home plug, so it can't read other directories in $HOME.
M=~/snap/openvino-model-server-2404/current/models
openvino-model-server-2404.ovms --source_model OpenVINO/Qwen3-4B-int4-ov \
  --model_repository_path $M --rest_port 8000 --target_device GPU
```

### `ovms-env`

`ovms/bin/ovms-env <command>` puts directories on `LD_LIBRARY_PATH` in this
order:

1. `ovms/lib`. This must come first: `npu-libs` ships its own `libtbb.so.12`
   (stock 2021.11, with tpause) and `libhwloc`, and `LD_LIBRARY_PATH` is
   searched before RUNPATH. If `ovms/lib` weren't first, the TBB fix would be
   silently lost.
2. `$OVMS_GPU_RUNTIME` (default `<ovms>/../gpu-runtime`), if it exists.
3. `$OVMS_NPU_LIBS` (default `<ovms>/../npu-libs`), if it holds
   `libze_intel_npu.so.1`.

Set either variable to another directory to point at your own copy, or to an
empty string to disable it. If you build your own launcher instead, keep
`ovms/lib` ahead of `npu-libs`.

### Bringing your own GPU runtime

`gpu-runtime/` is a separate tree, so a consumer that needs a different
compute-runtime version can leave it out and supply its own:

- stage-snaps or tarball: drop `gpu-runtime` from the part's `stage:` list.
- content interface: don't plug `intel-gpu-runtime`.

Then either:

- stage [intel-compute-runtime-bundle](https://github.com/canonical/intel-compute-runtime-bundle)
  at `<tag>` into a `gpu-runtime/` directory next to `ovms/`. Rewrite the
  `.icd` files to bare library names (see the `gpu-runtime` part in
  `snap/snapcraft.yaml`), and `ovms-env` keeps working. Or
- set `OVMS_GPU_RUNTIME` to wherever you staged it, or set it to an empty
  string and provide `LD_LIBRARY_PATH`/`OCL_ICD_VENDORS` yourself (for example
  the existing `layout: /etc/OpenCL/vendors` approach used by inference snaps).

## Delivery mechanisms

### 1. stage-snaps (build time)

The tree is copied into your snap when it is built. This is the simplest
option, and your snap stays self-contained.

```yaml
plugs:
  npu-libs:
    interface: content
    content: npu-libs-2404
    target: $SNAP/npu-libs

parts:
  openvino-model-server:
    plugin: nil
    stage-snaps:
      - openvino-model-server-2404/latest/edge
    stage:
      - ovms
      - gpu-runtime       # remove to bring your own GPU runtime
    # inference-snaps component:
    # organize:
    #   ovms: (component/openvino-model-server)/ovms
    #   gpu-runtime: (component/openvino-model-server)/gpu-runtime
apps:
  server:
    command: ovms/bin/ovms-env $SNAP/ovms/bin/ovms
    plugs: [network-bind, opengl, accel, npu-libs]
```

Full example: `examples/stage-snap/`.

### 2. Content interface (run time)

The trees are mounted from the installed `openvino-model-server-2404` snap.
Your snap stays small and receives OVMS updates without being rebuilt, but it
depends on a second snap being installed and connected.

```yaml
plugs:
  openvino-model-server:
    interface: content
    content: openvino-model-server-2404
    target: $SNAP/ovms
    default-provider: openvino-model-server-2404
  intel-gpu-runtime:        # omit to bring your own GPU runtime
    interface: content
    content: openvino-model-server-2404-gpu-runtime
    target: $SNAP/gpu-runtime
    default-provider: openvino-model-server-2404
  # + npu-libs as above; add accel to the app's plugs
```

snapd creates the content mount points itself. Run `$SNAP/ovms/bin/ovms-env $SNAP/ovms/bin/ovms`. Full example with a
wrapper that checks the connection: `examples/content/`.

```
sudo snap install openvino-model-server-2404 --edge
sudo snap install --dangerous ovms-consumer-content_0.1_amd64.snap
sudo snap connect ovms-consumer-content:openvino-model-server openvino-model-server-2404:openvino-model-server
sudo snap connect ovms-consumer-content:intel-gpu-runtime openvino-model-server-2404:intel-gpu-runtime
```

The provider has two content slots, so `snap connect` needs the slot name.

### 3. Release tarball (build time)

Each GitHub release has `openvino-model-server-2404_<version>_amd64.tar.gz`
and a `.sha256` file attached. It contains the same `ovms/` and `gpu-runtime/`
trees as the snap for that version, unpacked from the published snap. You can
use it in a snap:

```yaml
parts:
  openvino-model-server:
    plugin: dump
    source: https://github.com/canonical/openvino-model-server-snap/releases/download/2026.4.1/openvino-model-server-2404_2026.4.1_amd64.tar.gz
    source-checksum: sha256/<from the .sha256 asset>
    stage:
      - ovms
      - gpu-runtime       # remove to bring your own GPU runtime
```

Plugs, the npu-libs mount point and the app are the same as in the stage-snaps
example. You can also unpack the tarball on an Ubuntu 24.04 host and run
`ovms/bin/ovms-env ovms/bin/ovms` directly. Full example: `examples/tarball/`.

### Which one?

| | stage-snaps | content interface | tarball |
|---|---|---|---|
| Consumer snap size | +~100 MB compressed | minimal | +~100 MB compressed |
| OVMS update | rebuild consumer | refresh provider | rebuild consumer |
| Pinning | store channel | none (provider decides) | exact URL + checksum |
| Extra install/connect step | no | yes | no |
| Usable outside snaps | no | no | yes (24.04 host) |

## Building

```
snapcraft pack
```

Building takes about 15 minutes on 96 cores. You need roughly 60 GB of free
disk.

## Testing

```
tests/check-tree.sh <dir-containing-bin-and-lib>   # self-containment, plugins, no tpause in TBB
tests/smoke-test.sh openvino-model-server-2404.ovms   # installed snap, CPU chat completion
tests/smoke-test.sh ./ovms/bin/ovms-env ./ovms/bin/ovms   # unpacked tarball
DEVICE=GPU tests/smoke-test.sh ...                    # or DEVICE=NPU
DEVICES="CPU GPU NPU" tests/test-examples.sh <snap> <tarball> [stage-snap content tarball]
                      # builds, installs and smoke-tests the examples against
                      # local, unpublished artifacts (needs snapcraft + sudo)
```

`check-tree.sh` resolves every library with the core24 loader and core24
library directories only. A library that is missing from the tree, or that
would come from the host, therefore makes it fail.

## CI

- `.github/workflows/snap.yaml` runs on pull requests and on pushes to `main`.
  It builds the snap, runs `check-tree.sh`, installs the snap and runs the
  confined smoke test. Publishing to `<track>/edge` (on `main` or a manual
  dispatch) is commented out until the snap name is registered. When enabled,
  it needs the `SNAP_STORE_PE_BOT` secret. The build needs the self-hosted
  xlarge runners.
- `.github/workflows/release-tarball.yaml` runs when a GitHub release is
  published with an OVMS version tag (for example `2026.4.1`). It downloads
  that snap version from the store, checks the tree, runs `make-tarball.sh`,
  smoke-tests the tarball, and attaches it to the release.

Release flow: merge to `main` → snap is on `latest/edge` → test it → publish
GitHub release `2026.4.1` → tarball is attached → promote the snap in the store.

## License

Packaging: Apache-2.0 (`LICENSE`). OVMS, OpenVINO and third-party licenses
ship in `ovms/LICENSE` and `ovms/thirdparty-licenses/`.
