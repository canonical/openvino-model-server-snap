# Checkbox provider for the openvino-model-server-2404 snap

This directory contains the Checkbox provider for the openvino-model-server-2404 snap,
including the snap recipe for building it and integrating with the Checkbox
snap. The test plan runs the repository's `tests/check-tree.sh` and
`tests/smoke-test.sh` (confined, on CPU, GPU and NPU) against the installed
snap. The CI runs it on Intel machines through Testflinger
(`.github/workflows/integration-tests.yaml`).

## Installation

Prerequisites:

```
sudo snap install --classic snapcraft
sudo snap install checkbox24
sudo snap install lxd
sudo adduser ubuntu lxd
lxd init --auto
```

Build and install the provider from this directory:

```
cd openvino-model-server-snap
mkdir -p checkbox/checkbox-provider-openvino-model-server-2404/bin
cp tests/check-tree.sh tests/smoke-test.sh checkbox/checkbox-provider-openvino-model-server-2404/bin/
cd checkbox
snapcraft pack
sudo snap install --dangerous --classic ./checkbox-openvino-model-server-2404_1.0.0_amd64.snap
```

## Installing test dependencies

```
checkbox-openvino-model-server-2404.install-full-deps
```

This installs `intel-npu-driver`. By default it does NOT install the
openvino-model-server-2404 snap, as tests typically run against a locally built
snap. To install `latest/stable` from the Snap Store, pass
`--install_from_store`. `--clean_model_dirs` removes the test model from
`~/snap/openvino-model-server-2404/common/models` so that it is downloaded again.

The user running the tests needs read/write access to `/dev/dri/render*` and
`/dev/accel/accel*` (the `render` group).

## Automated run

```
checkbox-openvino-model-server-2404.test-runner-automated
```

## Manual run

```
checkbox-openvino-model-server-2404.test-runner
```
