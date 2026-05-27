#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";

// Percent-change reporting follows the ratio-of-execution-time-means framing
// from Kalibera and Jones, "Quantifying Performance Changes with Effect Size
// Confidence Intervals" (University of Kent Technical Report 4-12,
// arXiv:2007.10899). This script intentionally computes a one-level summary
// over the process-level runs in timings_scatter.csv; it does not attempt the
// full hierarchical experiment design from Kalibera and Jones, "Rigorous
// Benchmarking in Reasonable Time" (ISMM 2013, doi:10.1145/2464157.2464160),
// and it does not implement the HPT suite-level method from Chen, Chen, Guo,
// Temam, Wu, and Hu, "Statistical Performance Comparisons of Computers"
// (HPCA 2012, doi:10.1109/HPCA.2012.6169043).
//
// timeout_or_failed rows are exact capped-runtime observations for
// C=min(T, timeout). If a comparison has timeouts, we compute the ordinary
// ratio CI on capped values, then use only its lower bound for the true
// uncapped runtime ratio because E[C] <= E[T]. The uncapped upper bound is
// therefore Infinity.

const [, , inputPath = "results/timings_scatter.csv", outputPath = "results/timing_percent_change.csv"] =
  process.argv;

const parallelLabels = new Map([
  ["parallel off", { label: "serial", order: 0 }],
  ["parallel on", { label: "default Rayon", order: 1 }],
]);

const tCritical95 = [
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

function welchDegreesOfFreedom(oldVariance, oldN, newVariance, newN) {
  const oldTerm = oldVariance / oldN;
  const newTerm = newVariance / newN;
  const numerator = (oldTerm + newTerm) ** 2;
  const denominator =
    oldN > 1 && newN > 1
      ? oldTerm ** 2 / (oldN - 1) + newTerm ** 2 / (newN - 1)
      : 0;
  return denominator > 0 ? numerator / denominator : Math.min(oldN, newN) - 1;
}

function interpolateTCriticalFromTable(df, table, largeDfCritical) {
  if (!Number.isFinite(df) || df <= 1) return table[1];
  if (df >= 30) return largeDfCritical;

  const lower = Math.floor(df);
  const upper = Math.ceil(df);
  if (lower === upper) return table[lower];

  const lowerT = table[lower];
  const upperT = table[upper];
  return lowerT + (upperT - lowerT) * (df - lower);
}

function interpolateTCritical(df) {
  return interpolateTCriticalFromTable(df, tCritical95, 1.96);
}

function ratioConfidenceInterval(oldValues, newValues) {
  const oldN = oldValues.length;
  const newN = newValues.length;
  const oldMean = mean(oldValues);
  const newMean = mean(newValues);
  const oldVariance = sampleVariance(oldValues, oldMean);
  const newVariance = sampleVariance(newValues, newMean);
  const ratio = newMean / oldMean;
  const df = welchDegreesOfFreedom(oldVariance, oldN, newVariance, newN);
  const t = interpolateTCritical(df);

  const oldFactor = oldMean ** 2 - (t ** 2 * oldVariance) / oldN;
  const newFactor = newMean ** 2 - (t ** 2 * newVariance) / newN;
  const radicand = (oldMean * newMean) ** 2 - newFactor * oldFactor;

  // Fieller-style confidence interval for the ratio of means, in the
  // one-level shape used by the JupyterLab benchmark reporter. The raw output
  // is a ratio; CSV percent columns are derived as (ratio - 1) * 100.
  if (oldFactor > 0 && radicand >= 0) {
    const center = (oldMean * newMean) / oldFactor;
    const halfWidth = Math.sqrt(radicand) / oldFactor;
    return {
      ratio,
      lower: Math.max(center - halfWidth, Number.MIN_VALUE),
      upper: center + halfWidth,
      method: "fieller",
      oldMean,
      newMean,
      oldVariance,
      newVariance,
      df,
    };
  }

  const ratioVariance =
    ratio ** 2 *
    (oldVariance / (oldN * oldMean ** 2) + newVariance / (newN * newMean ** 2));
  const halfWidth = t * Math.sqrt(ratioVariance);
  return {
    ratio,
    lower: Math.max(ratio - halfWidth, Number.MIN_VALUE),
    upper: ratio + halfWidth,
    method: "delta",
    oldMean,
    newMean,
    oldVariance,
    newVariance,
    df,
  };
}

function sampleValues(samples) {
  return samples.map((sample) => sample.timeMs);
}

function countTimeouts(samples) {
  return samples.filter((sample) => sample.timedOut).length;
}

function cappedRuntimeRatioLowerBound(oldValues, newSamples) {
  const cappedCi = ratioConfidenceInterval(oldValues, sampleValues(newSamples));
  return {
    ...cappedCi,
    upper: Infinity,
    method: `${cappedCi.method}_capped_runtime_lower_bound`,
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
for (const [experiment, experimentOrder] of experiments) {
  const baselineKey = `${experiment}\u0000old\u0000parallel off`;
  const baselineSamples = groups.get(baselineKey);
  if (!baselineSamples || baselineSamples.length < 2 || countTimeouts(baselineSamples) > 0) {
    continue;
  }
  const baselineValues = sampleValues(baselineSamples);

  for (const [key, samples] of groups) {
    const [groupExperiment, variant, rawParallel] = key.split("\u0000");
    if (groupExperiment !== experiment) continue;
    if (variant === "old" && rawParallel === "parallel off") continue;
    if (samples.length < 2) continue;

    const parallel = parallelLabels.get(rawParallel);
    if (!parallel) throw new Error(`unknown parallel mode: ${rawParallel}`);

    const nTimeout = countTimeouts(samples);
    const ci =
      nTimeout > 0
        ? cappedRuntimeRatioLowerBound(baselineValues, samples)
        : ratioConfidenceInterval(baselineValues, sampleValues(samples));
    outputRows.push({
      experiment,
      experiment_order: experimentOrder,
      variant,
      variant_order: variants.get(variant),
      parallel: parallel.label,
      parallel_order: parallel.order,
      n_baseline: baselineValues.length,
      n: samples.length,
      n_timeout: nTimeout,
      baseline_mean_ms: ci.oldMean,
      mean_ms: ci.newMean,
      ratio_mean: ci.ratio,
      percent_change: (ci.ratio - 1) * 100,
      ci_lower_ratio: ci.lower,
      ci_upper_ratio: Number.isFinite(ci.upper) ? ci.upper : "Infinity",
      ci_lower_percent: (ci.lower - 1) * 100,
      ci_upper_percent: Number.isFinite(ci.upper) ? (ci.upper - 1) * 100 : "Infinity",
      ci_upper_is_infinite: !Number.isFinite(ci.upper),
      ci_upper_ratio_plot: Number.isFinite(ci.upper) ? ci.upper : "",
      ci_method: ci.method,
    });
  }
}

const maxRatioForPlot = Math.max(
  1,
  ...outputRows.flatMap((row) =>
    [row.ratio_mean, row.ci_lower_ratio, Number(row.ci_upper_ratio)]
      .filter((value) => Number.isFinite(value) && value > 0),
  ),
);
const ratioPlotUpper = maxRatioForPlot * 1.35;
for (const row of outputRows) {
  if (row.ci_upper_is_infinite) {
    row.ci_upper_ratio_plot = ratioPlotUpper;
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
  "n_baseline",
  "n",
  "n_timeout",
  "baseline_mean_ms",
  "mean_ms",
  "ratio_mean",
  "percent_change",
  "ci_lower_ratio",
  "ci_upper_ratio",
  "ci_lower_percent",
  "ci_upper_percent",
  "ci_upper_is_infinite",
  "ci_upper_ratio_plot",
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
