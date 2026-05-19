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

node - "$CSV" "$SPEC" <<'NODE'
const fs = require("fs");

const [csvPath, specPath] = process.argv.slice(2);
const rows = fs
  .readFileSync(csvPath, "utf8")
  .trim()
  .split(/\r?\n/)
  .slice(1)
  .map((line) => {
    const [experiment, variant, run, metric, time_ms, tuples] = line.split(",");
    return {
      experiment,
      variant,
      run: Number(run),
      metric,
      time_ms: Number(time_ms),
      tuples: Number(tuples),
    };
  });

const spec = {
  $schema: "https://vega.github.io/schema/vega-lite/v5.json",
  title: "egglog #872 repro timings, 5 runs per variant",
  width: 860,
  height: 430,
  data: { values: rows },
  mark: {
    type: "point",
    filled: true,
    size: 70,
    opacity: 0.85,
    stroke: "white",
    strokeWidth: 0.8,
  },
  encoding: {
    x: {
      field: "experiment",
      type: "nominal",
      sort: [
        "qwen_minimal target rule",
        "qwen_one target rule",
        "qwen_all total runtime",
      ],
      axis: {
        title: "Experiment",
        labelAngle: 0,
        labelLimit: 180,
      },
    },
    xOffset: {
      field: "run",
      type: "ordinal",
      sort: [1, 2, 3, 4, 5],
    },
    y: {
      field: "time_ms",
      type: "quantitative",
      scale: {
        type: "log",
        base: 10,
        domain: [0.04, 3000],
      },
      axis: {
        title: "Time (ms, log scale)",
        format: "~g",
      },
    },
    color: {
      field: "variant",
      type: "nominal",
      sort: ["old", "new", "PR #857"],
      scale: {
        domain: ["old", "new", "PR #857"],
        range: ["#4c78a8", "#e45756", "#54a24b"],
      },
      legend: {
        title: "Variant",
        orient: "top",
      },
    },
    tooltip: [
      { field: "experiment", type: "nominal", title: "Experiment" },
      { field: "variant", type: "nominal", title: "Variant" },
      { field: "run", type: "ordinal", title: "Run" },
      { field: "metric", type: "nominal", title: "Metric" },
      {
        field: "time_ms",
        type: "quantitative",
        title: "Time (ms)",
        format: ".3f",
      },
      { field: "tuples", type: "quantitative", title: "Tuples" },
    ],
  },
  config: {
    axis: {
      grid: true,
      titleFontSize: 13,
      labelFontSize: 12,
    },
    legend: {
      labelFontSize: 12,
      titleFontSize: 12,
    },
    title: {
      fontSize: 16,
      anchor: "start",
    },
    view: {
      stroke: null,
    },
  },
};

fs.writeFileSync(specPath, `${JSON.stringify(spec, null, 2)}\n`);
NODE

npx --yes --package vega-lite@5 --package canvas vl2png "$SPEC" "$PNG"

printf 'Wrote %s\n' "$CSV"
printf 'Wrote %s\n' "$SPEC"
printf 'Wrote %s\n' "$PNG"
