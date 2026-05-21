#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/results"
CSV="$OUT_DIR/timings_scatter.csv"
SPEC="$ROOT/scripts/timings_scatter.vl.json"
PNG="$OUT_DIR/timings_scatter.png"
PERCENT_CSV="$OUT_DIR/timing_percent_change.csv"
PERCENT_SPEC="$ROOT/scripts/timing_percent_change.vl.json"
PERCENT_PNG="$OUT_DIR/timing_percent_change.png"
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/egglog-repro-bins.XXXXXX")"
RUNS="${RUNS:-2}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-75}"

trap 'rm -rf "$BIN_DIR"' EXIT

mkdir -p "$OUT_DIR"

features=("old" "new" "pr857" "latest_main")
variants=("old" "new" "PR #857" "main 8c1c70b")
bins=("$BIN_DIR/bench_old" "$BIN_DIR/bench_new" "$BIN_DIR/bench_pr857" "$BIN_DIR/bench_latest_main")
parallel_labels=("parallel off" "parallel on")
rayon_threads=("1" "")
bench_files=(
  "gemma4_moe.egg"
  "llama.egg"
  "whisper.egg"
  "gemma.egg"
  "qwen3_moe.egg"
  "qwen.egg"
  "paged_llama.egg"
)
bench_experiments=(
  "gemma4_moe"
  "llama"
  "whisper"
  "gemma"
  "qwen3_moe"
  "qwen"
  "paged_llama"
)

cd "$ROOT"

if [[ ! -f "$SPEC" ]]; then
  printf 'missing Vega-Lite spec: %s\n' "$SPEC" >&2
  exit 1
fi
if [[ ! -f "$PERCENT_SPEC" ]]; then
  printf 'missing Vega-Lite spec: %s\n' "$PERCENT_SPEC" >&2
  exit 1
fi

for i in "${!features[@]}"; do
  cargo build --release --features "${features[$i]}" --no-default-features
  cp target/release/bench "${bins[$i]}"
done

printf 'parallel,experiment,variant,run,metric,time_ms,tuples,status\n' > "$CSV"

run_bench() {
  local bin="$1"
  local file="$2"
  local top_n="$3"
  local rayon_thread_count="$4"

  if [[ -n "$rayon_thread_count" ]]; then
    RAYON_NUM_THREADS="$rayon_thread_count" perl -e 'alarm shift; exec @ARGV' \
      "$BENCH_TIMEOUT_SECONDS" "$bin" "$file" "$top_n" 2>&1
  else
    perl -e 'alarm shift; exec @ARGV' "$BENCH_TIMEOUT_SECONDS" "$bin" "$file" "$top_n" 2>&1
  fi
}

append_total_timing() {
  local bin="$1"
  local variant="$2"
  local parallel="$3"
  local run="$4"
  local experiment="$5"
  local file="$6"
  local rayon_thread_count="$7"
  local out
  local time_ms
  local tuples

  printf 'Running %-12s | %-13s | %-10s | run %s/%s\n' \
    "$experiment" "$variant" "$parallel" "$run" "$RUNS" >&2

  if ! out="$(run_bench "$bin" "$file" 0 "$rayon_thread_count")"; then
    printf 'benchmark timed out or failed after %ss for %s %s %s run %s\n' \
      "$BENCH_TIMEOUT_SECONDS" "$parallel" "$variant" "$experiment" "$run" >&2
    printf '%s\n' "$out" >&2
    printf '%s,%s,%s,%s,total runtime ms,%s,,timeout_or_failed\n' \
      "$parallel" "$experiment" "$variant" "$run" "$((BENCH_TIMEOUT_SECONDS * 1000))" >> "$CSV"
    return
  fi
  time_ms="$(printf '%s\n' "$out" | awk '/egglog total:/ { gsub("s", "", $3); print $3 * 1000; exit }')"
  tuples="$(printf '%s\n' "$out" | awk '/tuples after:/ { print $3; exit }')"

  if [[ -z "$time_ms" || -z "$tuples" ]]; then
    printf 'failed to parse total timing for %s %s %s run %s\n' "$parallel" "$variant" "$experiment" "$run" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  printf '%s,%s,%s,%s,total runtime ms,%s,%s,complete\n' \
    "$parallel" "$experiment" "$variant" "$run" "$time_ms" "$tuples" >> "$CSV"
}

for mode_i in "${!parallel_labels[@]}"; do
  parallel="${parallel_labels[$mode_i]}"
  rayon_thread_count="${rayon_threads[$mode_i]}"

  for i in "${!variants[@]}"; do
    for bench_i in "${!bench_files[@]}"; do
      for ((run = 1; run <= RUNS; run += 1)); do
        append_total_timing "${bins[$i]}" "${variants[$i]}" "$parallel" "$run" \
          "${bench_experiments[$bench_i]}" "${bench_files[$bench_i]}" "$rayon_thread_count"
      done
    done
  done
done

node "$ROOT/scripts/compute_timing_percent_change.mjs" "$CSV" "$PERCENT_CSV"

npx --yes --package vega-lite@6.4.3 --package canvas vl2png --seed 1 "$SPEC" "$PNG"
npx --yes --package vega-lite@6.4.3 --package canvas vl2png "$PERCENT_SPEC" "$PERCENT_PNG"

printf 'Wrote %s\n' "$CSV"
printf 'Rendered %s from %s\n' "$PNG" "$SPEC"
printf 'Wrote %s\n' "$PERCENT_CSV"
printf 'Rendered %s from %s\n' "$PERCENT_PNG" "$PERCENT_SPEC"
