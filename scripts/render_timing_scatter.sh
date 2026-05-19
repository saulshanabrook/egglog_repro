#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/results"
CSV="$OUT_DIR/timings_scatter.csv"
SPEC="$OUT_DIR/timings_scatter.vl.json"
PNG="$OUT_DIR/timings_scatter.png"
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/egglog-repro-bins.XXXXXX")"

trap 'rm -rf "$BIN_DIR"' EXIT

mkdir -p "$OUT_DIR"

features=("old" "new" "pr857")
variants=("old" "new" "PR #857")
bins=("$BIN_DIR/bench_old" "$BIN_DIR/bench_new" "$BIN_DIR/bench_pr857")

cd "$ROOT"

if [[ ! -f "$SPEC" ]]; then
  printf 'missing Vega-Lite spec: %s\n' "$SPEC" >&2
  exit 1
fi

for i in "${!features[@]}"; do
  cargo build --release --features "${features[$i]}" --no-default-features
  cp target/release/bench "${bins[$i]}"
done

printf 'experiment,variant,run,metric,time_ms,tuples\n' > "$CSV"

append_rule_timing() {
  local bin="$1"
  local variant="$2"
  local run="$3"
  local experiment="$4"
  local file="$5"
  local out
  local time_ms
  local tuples

  out="$("$bin" "$file" 200 2>&1)"
  time_ms="$(printf '%s\n' "$out" | awk '/cublaslt batched column-major/ { print $1; exit }')"
  tuples="$(printf '%s\n' "$out" | awk '/tuples after:/ { print $3; exit }')"

  if [[ -z "$time_ms" || -z "$tuples" ]]; then
    printf 'failed to parse rule timing for %s %s run %s\n' "$variant" "$experiment" "$run" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  printf '%s,%s,%s,rule search+apply ms,%s,%s\n' \
    "$experiment" "$variant" "$run" "$time_ms" "$tuples" >> "$CSV"
}

append_total_timing() {
  local bin="$1"
  local variant="$2"
  local run="$3"
  local out
  local time_ms
  local tuples

  out="$("$bin" qwen_all_cublaslt_rules.egg 0 2>&1)"
  time_ms="$(printf '%s\n' "$out" | awk '/egglog total:/ { gsub("s", "", $3); print $3 * 1000; exit }')"
  tuples="$(printf '%s\n' "$out" | awk '/tuples after:/ { print $3; exit }')"

  if [[ -z "$time_ms" || -z "$tuples" ]]; then
    printf 'failed to parse total timing for %s run %s\n' "$variant" "$run" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  printf 'qwen_all total runtime,%s,%s,total runtime ms,%s,%s\n' \
    "$variant" "$run" "$time_ms" "$tuples" >> "$CSV"
}

for i in "${!variants[@]}"; do
  for run in 1 2 3 4 5; do
    append_rule_timing "${bins[$i]}" "${variants[$i]}" "$run" \
      "qwen_minimal target rule" qwen_minimal.egg
  done

  for run in 1 2 3 4 5; do
    append_rule_timing "${bins[$i]}" "${variants[$i]}" "$run" \
      "qwen_one target rule" qwen_one_cublaslt_rule.egg
  done

  for run in 1 2 3 4 5; do
    append_total_timing "${bins[$i]}" "${variants[$i]}" "$run"
  done
done

npx --yes --package vega-lite@5 --package canvas vl2png --seed 1 "$SPEC" "$PNG"

printf 'Wrote %s\n' "$CSV"
printf 'Rendered %s from %s\n' "$PNG" "$SPEC"
