#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";

// Summarize raw process-level timing runs. timeout_or_failed rows are treated
// as right-censored runtimes: the recorded time_ms is the timeout cutoff, so
// true runtime is >= time_ms. Groups with any censored rows get one-sided
// lower-bounded 95% CIs: [lower, Infinity).

const [, , inputPath = "results/timings_scatter.csv", outputPath = "results/timing_mean_ci.csv"] =
  process.argv;

const parallelLabels = new Map([
  ["parallel off", { label: "serial", order: 0 }],
  ["parallel on", { label: "default Rayon", order: 1 }],
]);

const tCriticalTwoSided95 = [
  null,
  12.706,
  4.303,
  3.182,
  2.776,
  2.571,
  2.447,
  2.365,
  2.306,
  2.262,
  2.228,
  2.201,
  2.179,
  2.16,
  2.145,
  2.131,
  2.12,
  2.11,
  2.101,
  2.093,
  2.086,
  2.08,
  2.074,
  2.069,
  2.064,
  2.06,
  2.056,
  2.052,
  2.048,
  2.045,
  2.042,
];

const tCriticalOneSided95 = [
  null,
  6.314,
  2.92,
  2.353,
  2.132,
  2.015,
  1.943,
  1.895,
  1.86,
  1.833,
  1.812,
  1.796,
  1.782,
  1.771,
  1.761,
  1.753,
  1.746,
  1.74,
  1.734,
  1.729,
  1.725,
  1.721,
  1.717,
  1.714,
  1.711,
  1.708,
  1.706,
  1.703,
  1.701,
  1.699,
  1.697,
];

function parseCsv(text) {
  const [headerLine, ...lines] = text.trim().split(/\r?\n/);
  const headers = parseCsvLine(headerLine);
  return lines.filter(Boolean).map((line) => {
    const fields = parseCsvLine(line);
    return Object.fromEntries(headers.map((header, index) => [header, fields[index] ?? ""]));
  });
}

function parseCsvLine(line) {
  const fields = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        field += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === "," && !inQuotes) {
      fields.push(field);
      field = "";
    } else {
      field += char;
    }
  }

  fields.push(field);
  return fields;
}

function csvEscape(value) {
  const text = String(value);
  if (/[",\n\r]/.test(text)) {
    return `"${text.replaceAll('"', '""')}"`;
  }
  return text;
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function sampleVariance(values, valueMean) {
  if (values.length < 2) return 0;
  return (
    values.reduce((sum, value) => sum + (value - valueMean) ** 2, 0) /
    (values.length - 1)
  );
}

function interpolateTCritical(df, table, largeDfCritical) {
  if (!Number.isFinite(df) || df <= 1) return table[1];
  if (df >= 30) return largeDfCritical;

  const lower = Math.floor(df);
  const upper = Math.ceil(df);
  if (lower === upper) return table[lower];

  const lowerT = table[lower];
  const upperT = table[upper];
  return lowerT + (upperT - lowerT) * (df - lower);
}

function finiteMeanCi(values) {
  const n = values.length;
  const valueMean = mean(values);
  const valueVariance = sampleVariance(values, valueMean);
  const t = interpolateTCritical(n - 1, tCriticalTwoSided95, 1.96);
  const halfWidth = t * Math.sqrt(valueVariance / n);
  return {
    mean: valueMean,
    lower: Math.max(0, valueMean - halfWidth),
    upper: valueMean + halfWidth,
    method: "t_two_sided",
  };
}

function allTimeoutLowerBound(samples, alpha) {
  const cutoffs = samples.map((sample) => sample.timeMs);
  const uniqueCutoffs = new Set(cutoffs);
  const tau = uniqueCutoffs.size === 1 ? cutoffs[0] : Math.min(...cutoffs);
  return tau * alpha ** (1 / samples.length);
}

function censoredMeanCi(samples) {
  const values = samples.map((sample) => sample.timeMs);
  const timeoutCount = samples.filter((sample) => sample.timedOut).length;

  if (timeoutCount === samples.length) {
    return {
      mean: mean(values),
      lower: allTimeoutLowerBound(samples, 0.05),
      upper: Infinity,
      method: "right_censored_all_timeout_lower_bound",
    };
  }

  const valueMean = mean(values);
  const valueVariance = sampleVariance(values, valueMean);
  const t = interpolateTCritical(samples.length - 1, tCriticalOneSided95, 1.645);
  return {
    mean: valueMean,
    lower: Math.max(0, valueMean - t * Math.sqrt(valueVariance / samples.length)),
    upper: Infinity,
    method: "right_censored_mixed_lower_bound",
  };
}

function keyFor(row) {
  return `${row.experiment}\u0000${row.variant}\u0000${row.parallel}`;
}

function sampleFromRow(row) {
  if (row.status === "complete") {
    return { timeMs: Number(row.time_ms), timedOut: false };
  }
  if (row.status === "timeout_or_failed") {
    return { timeMs: Number(row.time_ms), timedOut: true };
  }
  throw new Error(`unsupported timing row status: ${row.status}`);
}

const rows = parseCsv(readFileSync(inputPath, "utf8"));
const experiments = new Map();
const variants = new Map();
const groups = new Map();

for (const row of rows) {
  if (!experiments.has(row.experiment)) {
    experiments.set(row.experiment, experiments.size);
  }
  if (!variants.has(row.variant)) {
    variants.set(row.variant, variants.size);
  }

  const key = keyFor(row);
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(sampleFromRow(row));
}

const outputRows = [];
for (const [key, samples] of groups) {
  const [experiment, variant, rawParallel] = key.split("\u0000");
  const parallel = parallelLabels.get(rawParallel);
  if (!parallel) throw new Error(`unknown parallel mode: ${rawParallel}`);

  const timeoutCount = samples.filter((sample) => sample.timedOut).length;
  const ci = timeoutCount > 0 ? censoredMeanCi(samples) : finiteMeanCi(samples.map((sample) => sample.timeMs));
  outputRows.push({
    experiment,
    experiment_order: experiments.get(experiment),
    variant,
    variant_order: variants.get(variant),
    parallel: parallel.label,
    parallel_order: parallel.order,
    n: samples.length,
    n_timeout: timeoutCount,
    mean_ms: ci.mean,
    ci_lower_ms: ci.lower,
    ci_upper_ms: Number.isFinite(ci.upper) ? ci.upper : "Infinity",
    ci_upper_is_infinite: !Number.isFinite(ci.upper),
    ci_upper_ms_plot: Number.isFinite(ci.upper) ? ci.upper : "",
    ci_method: ci.method,
  });
}

const maxMsForPlot = Math.max(
  1,
  ...outputRows.flatMap((row) =>
    [row.mean_ms, row.ci_lower_ms, Number(row.ci_upper_ms)]
      .filter((value) => Number.isFinite(value) && value > 0),
  ),
);
const msPlotUpper = maxMsForPlot * 1.35;
for (const row of outputRows) {
  if (row.ci_upper_is_infinite) {
    row.ci_upper_ms_plot = msPlotUpper;
  }
}

outputRows.sort(
  (a, b) =>
    a.experiment_order - b.experiment_order ||
    a.variant_order - b.variant_order ||
    a.parallel_order - b.parallel_order,
);

const headers = [
  "experiment",
  "experiment_order",
  "variant",
  "variant_order",
  "parallel",
  "parallel_order",
  "n",
  "n_timeout",
  "mean_ms",
  "ci_lower_ms",
  "ci_upper_ms",
  "ci_upper_is_infinite",
  "ci_upper_ms_plot",
  "ci_method",
];

const csv = [
  headers.join(","),
  ...outputRows.map((row) =>
    headers
      .map((header) => {
        const value = row[header];
        return typeof value === "number" ? String(value) : csvEscape(value);
      })
      .join(","),
  ),
].join("\n");

writeFileSync(outputPath, `${csv}\n`);
