#!/bin/bash
# Functional smoke test: serve a small LLM with OVMS on CPU and send one chat
# completion request.
#
# Usage: tests/smoke-test.sh <ovms-command...>
#   tests/smoke-test.sh openvino-model-server-2404.ovms          # installed snap
#   tests/smoke-test.sh ./ovms/bin/ovms                          # unpacked tree (Ubuntu 24.04 host)
#
# Environment:
#   MODEL_DIR  where the model is downloaded/reused. Default for a snap
#              command <snap>.ovms: $HOME/snap/<snap>/current/models/... (the
#              snap's $SNAP_USER_DATA, which it can read without the home
#              interface); otherwise $HOME/ovms-test-models/...
#   DEVICE     OpenVINO target device (default: CPU)
#   PORT       REST port (default: 18080)
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,12p' "$0"; exit 2; }
case "$1" in
  *.ovms) default_dir="$HOME/snap/${1%.ovms}/current/models/smollm2-360m-int8-ov" ;;
  *)      default_dir="$HOME/ovms-test-models/smollm2-360m-int8-ov" ;;
esac
model_dir="${MODEL_DIR:-$default_dir}"
device="${DEVICE:-CPU}"
port="${PORT:-18080}"

# SmolLM2-360M-Instruct INT8 OpenVINO IR (~400 MB), pinned revision. It is the
# same model the smollm2 inference snap ships.
repo=AIFunOver/SmolLM2-360M-Instruct-openvino-8bit
rev=4d5c9cbb82354e2f0929283ac5fa187761f43332
files=(config.json generation_config.json openvino_config.json
  openvino_model.xml openvino_model.bin openvino_tokenizer.xml openvino_tokenizer.bin
  openvino_detokenizer.xml openvino_detokenizer.bin special_tokens_map.json
  tokenizer.json tokenizer_config.json vocab.json)
# Run once first: snapd creates/updates $HOME/snap/<snap>/current on launch.
"$@" --version
mkdir -p "$model_dir"
for f in "${files[@]}"; do
  [ -s "$model_dir/$f" ] || curl -fsSL --retry 3 -o "$model_dir/$f" \
    "https://huggingface.co/$repo/resolve/$rev/$f"
done

log="$(mktemp "${TMPDIR:-/tmp}/ovms-smoke.XXXXXX.log")"
"$@" --rest_port "$port" --rest_bind_address 127.0.0.1 \
  --model_name smollm2 --model_path "$model_dir" \
  --task text_generation --target_device "$device" >"$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true' EXIT

# Wait until the model is AVAILABLE, not just until the REST port answers.
for _ in $(seq 1 300); do
  if curl -fs "http://127.0.0.1:$port/v2/models/smollm2/ready" >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || { echo "FAIL: ovms exited"; cat "$log"; exit 1; }
  sleep 1
done
curl -fs "http://127.0.0.1:$port/v2/models/smollm2/ready" >/dev/null || {
  echo "FAIL: model not ready after 300 s"; tail -50 "$log"; exit 1; }

resp="$(curl -fsS "http://127.0.0.1:$port/v3/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"smollm2","max_tokens":32,"temperature":0,
       "messages":[{"role":"user","content":"What is the capital of France? Answer in one sentence."}]}')" || {
  echo "FAIL: chat request failed"; tail -50 "$log"; exit 1; }
echo "$resp"
if echo "$resp" | grep -q 'Paris'; then
  echo "PASS: $device chat completion"
else
  echo "FAIL: unexpected response"; tail -50 "$log"; exit 1
fi
