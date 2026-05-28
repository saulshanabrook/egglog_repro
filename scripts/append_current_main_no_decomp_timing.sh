#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/results"
CSV="$OUT_DIR/timings_scatter.csv"
TIMING_SUMMARY_CSV="$OUT_DIR/timing_mean_ci.csv"
SPEC="$ROOT/scripts/timings_scatter.vl.json"
PNG="$OUT_DIR/timings_scatter.png"
PERCENT_CSV="$OUT_DIR/timing_percent_change.csv"
PERCENT_SPEC="$ROOT/scripts/timing_percent_change.vl.json"
PERCENT_PNG="$OUT_DIR/timing_percent_change.png"
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/egglog-repro-current-main-bins.XXXXXX")"
RUNS="${RUNS:-5}"
VARIANT="current main no-decomp"
BIN="$BIN_DIR/bench_current_main_no_decomp"

trap 'rm -rf "$BIN_DIR"' EXIT

mkdir -p "$OUT_DIR"

bench_files=(
  "llama.egg"
  "whisper.egg"
  "gemma.egg"
  "qwen3_moe.egg"
  "qwen.egg"
  "paged_llama.egg"
)
bench_experiments=(
  "llama"
  "whisper"
  "gemma"
  "qwen3_moe"
  "qwen"
  "paged_llama"
)
bench_timeout_seconds=(
  60
  61
  147
  60
  60
  60
)
parallel_labels=("parallel off" "parallel on")
rayon_threads=("1" "")

cd "$ROOT"

if [[ ! -f "$CSV" ]]; then
  printf 'missing existing timing CSV: %s\n' "$CSV" >&2
  exit 1
fi
if [[ ! -f "$SPEC" ]]; then
  printf 'missing Vega-Lite spec: %s\n' "$SPEC" >&2
  exit 1
fi
if [[ ! -f "$PERCENT_SPEC" ]]; then
  printf 'missing Vega-Lite spec: %s\n' "$PERCENT_SPEC" >&2
  exit 1
fi

cargo build --release --features latest_main_no_decomp --no-default-features
cp target/release/bench "$BIN"

tmp_csv="$(mktemp "${TMPDIR:-/tmp}/egglog-repro-current-main-csv.XXXXXX")"
awk -F, -v variant="$VARIANT" 'NR == 1 || $3 != variant' "$CSV" > "$tmp_csv"
mv "$tmp_csv" "$CSV"

run_bench() {
  local bin="$1"
  local file="$2"
  local top_n="$3"
  local rayon_thread_count="$4"
  local timeout_seconds="$5"

  if [[ -n "$rayon_thread_count" ]]; then
    RAYON_NUM_THREADS="$rayon_thread_count" perl -e 'alarm shift; exec @ARGV' \
      "$timeout_seconds" "$bin" "$file" "$top_n" 2>&1
  else
    perl -e 'alarm shift; exec @ARGV' "$timeout_seconds" "$bin" "$file" "$top_n" 2>&1
  fi
}

append_total_timing() {
  local parallel="$1"
  local run="$2"
  local experiment="$3"
  local file="$4"
  local rayon_thread_count="$5"
  local timeout_seconds="$6"
  local out
  local time_ms
  local tuples

  printf 'Running %-12s | %-18s | %-10s | run %s/%s | timeout %ss\n' \
    "$experiment" "$VARIANT" "$parallel" "$run" "$RUNS" "$timeout_seconds" >&2

  if ! out="$(run_bench "$BIN" "$file" 0 "$rayon_thread_count" "$timeout_seconds")"; then
    printf 'benchmark timed out or failed after %ss for %s %s %s run %s\n' \
      "$timeout_seconds" "$parallel" "$VARIANT" "$experiment" "$run" >&2
    printf '%s\n' "$out" >&2
    printf '%s,%s,%s,%s,total runtime ms,%s,,timeout_or_failed\n' \
      "$parallel" "$experiment" "$VARIANT" "$run" "$((timeout_seconds * 1000))" >> "$CSV"
    return
  fi

  time_ms="$(printf '%s\n' "$out" | awk '/egglog total:/ { gsub("s", "", $3); print $3 * 1000; exit }')"
  tuples="$(printf '%s\n' "$out" | awk '/tuples after:/ { print $3; exit }')"

  if [[ -z "$time_ms" || -z "$tuples" ]]; then
    printf 'failed to parse total timing for %s %s %s run %s\n' "$parallel" "$VARIANT" "$experiment" "$run" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  printf '%s,%s,%s,%s,total runtime ms,%s,%s,complete\n' \
    "$parallel" "$experiment" "$VARIANT" "$run" "$time_ms" "$tuples" >> "$CSV"
}

for mode_i in "${!parallel_labels[@]}"; do
  parallel="${parallel_labels[$mode_i]}"
  rayon_thread_count="${rayon_threads[$mode_i]}"

  for bench_i in "${!bench_files[@]}"; do
    for ((run = 1; run <= RUNS; run += 1)); do
      append_total_timing "$parallel" "$run" \
        "${bench_experiments[$bench_i]}" "${bench_files[$bench_i]}" "$rayon_thread_count" \
        "${bench_timeout_seconds[$bench_i]}"
    done
  done
done

node "$ROOT/scripts/compute_timing_mean_ci.mjs" "$CSV" "$TIMING_SUMMARY_CSV"
node "$ROOT/scripts/compute_timing_percent_change.mjs" "$CSV" "$PERCENT_CSV"

npx --yes --package vega-lite@6.4.3 --package canvas vl2png --seed 1 "$SPEC" "$PNG"
npx --yes --package vega-lite@6.4.3 --package canvas vl2png "$PERCENT_SPEC" "$PERCENT_PNG"

printf 'Updated %s with %s\n' "$CSV" "$VARIANT"
printf 'Wrote %s\n' "$TIMING_SUMMARY_CSV"
printf 'Rendered %s from %s\n' "$PNG" "$SPEC"
printf 'Wrote %s\n' "$PERCENT_CSV"
printf 'Rendered %s from %s\n' "$PERCENT_PNG" "$PERCENT_SPEC"
