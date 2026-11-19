#!/usr/bin/env python3
"""Work out the upstream versions snap/snapcraft.yaml should build, and update
it in place.

The OVMS release decides everything else, because OVMS pins its dependencies:

  ovms part           newest stable openvinotoolkit/model_server tag (vX.Y[.Z])
  openvino-toolkit    openvino-toolkit-2404/<major>/stable, which must have the
                      OpenVINO version OVMS pins (versions.mk). If the track
                      doesn't have it yet, OVMS (and its deps) stay where they
                      are and a warning is printed.
  opencv part         ARG OPENCV_VERSION in OVMS Dockerfile.ubuntu
  azure-sdk part      azure-storage-blobs_* tag in OVMS Dockerfile.ubuntu
  onetbb part         oneTBB release that OpenVINO's cmake/dependencies.cmake
                      downloads for Linux x86_64
  gpu-runtime part    newest canonical/intel-compute-runtime-bundle tag (not
                      pinned by OVMS; the driver OVMS ships in its own GPU
                      image is reported for reference)

Usage: upstream-versions.py [snapcraft.yaml]
Prints a summary and, when run in GitHub Actions, writes outputs to
$GITHUB_OUTPUT: update (true/false), ovms_tag, openvino_version, summary
(multi-line Markdown table). Uses $GH_TOKEN for the GitHub API if set.
"""
import json
import os
import re
import sys
import urllib.request

YAML = sys.argv[1] if len(sys.argv) > 1 else "snap/snapcraft.yaml"
TOOLKIT = "openvino-toolkit-2404"


def get(url, raw=True):
    headers = {"User-Agent": "upstream-versions"}
    if "api.github.com" in url:
        headers["Accept"] = "application/vnd.github.raw" if raw else "application/vnd.github+json"
        if os.environ.get("GH_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    if "api.snapcraft.io" in url:
        headers["Snap-Device-Series"] = "16"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
        return r.read().decode()


def gh_file(repo, path, ref):
    return get(f"https://api.github.com/repos/{repo}/contents/{path}?ref={ref}")


def gh_tags(repo):
    tags, page = [], 1
    while True:
        batch = json.loads(get(f"https://api.github.com/repos/{repo}/tags?per_page=100&page={page}", raw=False))
        tags += [t["name"] for t in batch]
        if len(batch) < 100:
            return tags
        page += 1


def vkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def search(pattern, text, what):
    m = re.search(pattern, text)
    if not m:
        sys.exit(f"ERROR: could not find {what}")
    return m.group(1)


# --- snapcraft.yaml helpers -------------------------------------------------
def part_block(text, part):
    m = re.search(rf"(?ms)^  {re.escape(part)}:\n.*?(?=^  \S|^\S|\Z)", text)
    if not m:
        sys.exit(f"ERROR: part {part} not found in {YAML}")
    return m


def get_tag(text, part):
    return search(r"(?m)^    source-tag:\s*\"?([^\"\s]+)\"?", part_block(text, part).group(0), f"{part} source-tag")


def set_tag(text, part, tag):
    m = part_block(text, part)
    block = re.sub(r"(?m)^(    source-tag:\s*)(\"?)[^\"\s]+(\"?)", lambda x: f"{x.group(1)}{x.group(2)}{tag}{x.group(3)}", m.group(0), count=1)
    return text[: m.start()] + block + text[m.end():]


# --- resolve ------------------------------------------------------------------
def ovms_deps(tag):
    """Versions an OVMS release pins."""
    versions = gh_file("openvinotoolkit/model_server", "versions.mk", tag)
    dockerfile = gh_file("openvinotoolkit/model_server", "Dockerfile.ubuntu", tag)
    makefile = gh_file("openvinotoolkit/model_server", "Makefile", tag)
    pkg = search(r"DLDT_PACKAGE_URL_UBUNTU24\s*\?=\s*\S+_(\d+\.\d+\.\d+)[.\w]*_x86_64\.tar\.gz", versions, "OpenVINO version in versions.mk")
    deps = {
        "openvino": pkg,
        "opencv": search(r"ARG OPENCV_VERSION=(\S+)", dockerfile, "OPENCV_VERSION"),
        "azure-sdk": search(r"--branch (azure-storage-blobs_\S+)", dockerfile, "azure-sdk branch"),
        "gpu-driver": search(r"ifeq \(\$\(BASE_OS_TAG\),24\.04\)[^\n]*\n(?:[^\n]*\n){0,3}?\s*INSTALL_DRIVER_VERSION \?= \"([^\"]+)\"", makefile, "Ubuntu 24.04 INSTALL_DRIVER_VERSION"),
    }
    cmake = gh_file("openvinotoolkit/openvino", "cmake/dependencies.cmake", deps["openvino"])
    deps["onetbb"] = "v" + search(r"oneapi-tbb-([\d.]+)-lin-release\.tgz", cmake, "oneTBB version in OpenVINO dependencies.cmake")
    return deps


def toolkit_tracks():
    info = json.loads(get(f"https://api.snapcraft.io/v2/snaps/info/{TOOLKIT}"))
    return {c["channel"]["track"]: c["version"] for c in info["channel-map"]
            if c["channel"]["risk"] == "stable" and c["channel"]["architecture"] == "amd64"}


def main():
    text = open(YAML).read()
    cur = {p: get_tag(text, p) for p in ("ovms", "opencv", "azure-sdk", "onetbb", "gpu-runtime")}
    cur["toolkit"] = search(rf"(?m)^\s*- ({TOOLKIT}/\S+)", text, "toolkit stage-snap")
    print("current:", json.dumps(cur, indent=2))

    tags = [t for t in gh_tags("openvinotoolkit/model_server") if re.fullmatch(r"v\d+\.\d+(\.\d+)?", t)]
    latest = max(tags, key=vkey)
    tracks = toolkit_tracks()
    warnings = []

    tag = latest
    deps = ovms_deps(tag)
    major = deps["openvino"].split(".")[0]
    if tracks.get(major) != deps["openvino"]:
        warnings.append(f"OVMS {latest} needs OpenVINO {deps['openvino']}, but {TOOLKIT} {major}/stable has "
                        f"{tracks.get(major, 'no such track')}. Keeping OVMS at {cur['ovms']}.")
        tag = cur["ovms"]
        deps = ovms_deps(tag)
        major = deps["openvino"].split(".")[0]

    bundle = max((t for t in gh_tags("canonical/intel-compute-runtime-bundle") if re.fullmatch(r"\d+(\.\d+)+", t)), key=vkey)
    new = {"ovms": tag, "opencv": deps["opencv"], "azure-sdk": deps["azure-sdk"], "onetbb": deps["onetbb"],
           "gpu-runtime": bundle, "toolkit": f"{TOOLKIT}/{major}/stable"}

    for p in ("ovms", "opencv", "azure-sdk", "onetbb", "gpu-runtime"):
        text = set_tag(text, p, new[p])
    text = text.replace(cur["toolkit"], new["toolkit"])
    text = re.sub(r"oneTBB [\d.]+ \(the version upstream OpenVINO [\d.]+ pins\)",
                  f"oneTBB {new['onetbb'].lstrip('v')} (the version upstream OpenVINO {deps['openvino']} pins)", text)
    open(YAML, "w").write(text)

    rows = ["| Component | Current | New |", "|---|---|---|"]
    rows += [f"| {k} | `{cur[k]}` | `{new[k]}`{' (changed)' if cur[k] != new[k] else ''} |" for k in new]
    summary = "\n".join(rows) + (
        f"\n\nOpenVINO pinned by OVMS {tag}: `{deps['openvino']}`. GPU driver in the OVMS {tag} "
        f"Ubuntu 24.04 GPU image (for reference): `{deps['gpu-driver']}`.")
    if warnings:
        summary += "\n\n" + "\n".join(f"> [!WARNING]\n> {w}" for w in warnings)
    print(summary)
    for w in warnings:
        print(f"::warning::{w}")

    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"update={'true' if cur != new else 'false'}\n")
            f.write(f"ovms_tag={tag}\nopenvino_version={deps['openvino']}\n")
            f.write(f"summary<<EOF_SUMMARY\n{summary}\nEOF_SUMMARY\n")


if __name__ == "__main__":
    main()
