#!/bin/bash

# 标准评测：固定评测集与运行方式，产出统一命名的归档结果。
# 用法：
#   scripts/run_standard_evaluation.sh                      # 用 App 当前生效连接
#   SPOKEN_EVAL_MODEL=qwen3.8-flash SPOKEN_EVAL_THINKING_MODE=off scripts/run_standard_evaluation.sh
# 结果写入 evaluations/results_<日期>_<模型>.json；评审方法见 evaluations/README.md。

set -euo pipefail

SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLES_FILE="${SPOKEN_EVAL_SAMPLES_FILE:-$SPOKEN_ROOT/evaluations/scene_targeted_samples_2026-09-30.json}"

if [[ ! -f "$SAMPLES_FILE" ]]; then
  printf '标准评测集不存在：%s\n' "$SAMPLES_FILE" >&2
  exit 1
fi

# 与 App 当前生效连接一致的模型名，供结果文件命名；SPOKEN_EVAL_MODEL 覆盖时优先。
CONNECTIONS_JSON="${SPOKEN_EVAL_CONNECTIONS_JSON:-${HOME}/Library/Application Support/Spoken/Configuration/model-connections-v1.json}"
MODEL_FOR_NAME="${SPOKEN_EVAL_MODEL:-}"
if [[ -z "$MODEL_FOR_NAME" && -f "$CONNECTIONS_JSON" ]]; then
  MODEL_FOR_NAME="$(jq -r '. as $root | $root.connections[] | select(.id == $root.activeID) | .model' "$CONNECTIONS_JSON")"
fi
MODEL_FOR_NAME="${MODEL_FOR_NAME:-unknown-model}"

STAMP="$(date +%Y-%m-%d)"
OUTPUT_PATH="${1:-$SPOKEN_ROOT/evaluations/results_${STAMP}_${MODEL_FOR_NAME}.json}"

export SPOKEN_EVAL_MATCHED_ONLY=1
export SPOKEN_EVAL_SAMPLES_FILE="$SAMPLES_FILE"

printf '标准评测集：%s\n结果输出：%s\n' "$SAMPLES_FILE" "$OUTPUT_PATH" >&2
"$SPOKEN_ROOT/scripts/run_prompt_evaluation.sh" "$OUTPUT_PATH"
printf '完成。评审 rubric 见 evaluations/README.md，评审 prompt 见 evaluations/review_prompt.md。\n' >&2
