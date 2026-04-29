#!/usr/bin/env bash
set -euo pipefail

exec >>/var/log/llama-server.log 2>&1

source /etc/default/llama-server

BOOL_ARGS=()

if [[ "${LLAMA_ARG_NO_MMAP:-false}" == "true" ]]; then
  BOOL_ARGS+=("--no-mmap")
fi

if [[ "${LLAMA_ARG_METRICS:-true}" == "true" ]]; then
  BOOL_ARGS+=("--metrics")
fi

if [[ "${LLAMA_ARG_FLASH_ATTN:-true}" == "true" ]]; then
  BOOL_ARGS+=("--flash-attn")
fi

if [[ "${LLAMA_ARG_CONT_BATCHING:-true}" == "true" ]]; then
  BOOL_ARGS+=("--cont-batching")
fi

exec /usr/bin/docker run --rm \
  --name llama-server \
  --gpus all \
  --network host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -v /models:/models:ro \
  -e NVIDIA_VISIBLE_DEVICES=all \
  "${LLAMA_CPP_IMAGE}:${LLAMA_CPP_IMAGE_TAG}" \
  /app/llama-server \
  --model "${LLAMA_ARG_MODEL}" \
  --alias "${LLAMA_ARG_ALIAS}" \
  --ctx-size "${LLAMA_ARG_CTX_SIZE}" \
  --parallel "${LLAMA_ARG_PARALLEL}" \
  --n-gpu-layers "${LLAMA_ARG_N_GPU_LAYERS}" \
  --temp "${LLAMA_ARG_TEMP}" \
  --top-p "${LLAMA_ARG_TOP_P}" \
  --top-k "${LLAMA_ARG_TOP_K}" \
  --min-p "${LLAMA_ARG_MIN_P}" \
  --reasoning-budget "${LLAMA_ARG_REASONING_BUDGET}" \
  --host "${LLAMA_ARG_HOST}" \
  --port "${LLAMA_ARG_PORT}" \
  --batch-size "${LLAMA_ARG_BATCH_SIZE}" \
  --ubatch-size "${LLAMA_ARG_UBATCH_SIZE}" \
  --threads "${LLAMA_ARG_THREADS}" \
  "${BOOL_ARGS[@]}"
