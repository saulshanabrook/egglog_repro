# egglog 0a8cc35 → 2e5657b: large multi-atom rule regression

## Summary

Between egglog rev `0a8cc35a6c68d0460c20449d5fa19ca3caba2923` and the tree
decomposition work later found in PR
[`#785`](https://github.com/egraphs-good/egglog/pull/785), full luminal-shaped
model `.egg` programs showed large total-runtime regressions. The current
bounded local sweep compares:

- `old`: `0a8cc35a6c68d0460c20449d5fa19ca3caba2923`
- `PR #896`: [`#896`](https://github.com/egraphs-good/egglog/pull/896) at
  `f58a47bf3a7dd252e44f7b1863f32a38fb6aa0c5`, with tree decomposition enabled
- `PR #896 no-decomp`: the same PR #896 commit with `EGraph::no_decomp = true`

With `RUNS=5`, all three variants complete every included model file under the
current caps in both serial and default Rayon modes.

## Files

Seven self-contained `.egg` programs are checked in. The current default sweep
intentionally excludes `gemma4_moe.egg`, because old/original did not complete
under the previous cap and a manual probe ran past two minutes.

| file | size | cap | old serial mean | PR #896 serial | PR #896 no-decomp serial |
|---|---:|---:|---:|---:|---:|
| `llama.egg` | 445 KB | 60 s | 1.29 s | 1.76 s | 1.86 s |
| `whisper.egg` | 478 KB | 61 s | 30.26 s | 25.61 s | 8.62 s |
| `gemma.egg` | 916 KB | 147 s | 73.52 s | 142.43 s | 47.22 s |
| `qwen3_moe.egg` | 524 KB | 60 s | 2.29 s | 3.59 s | 2.36 s |
| `qwen.egg` | 474 KB | 60 s | 1.55 s | 2.32 s | 2.24 s |
| `paged_llama.egg` | 437 KB | 60 s | 1.20 s | 1.73 s | 1.12 s |
| `gemma4_moe.egg` | 1.4 MB | excluded | n/a | n/a | n/a |

These are total `parse_and_run_program` times from
`results/timings_scatter.csv`, using five runs per cell. The caps are
`max(ceil(2x max old/original complete timing), 60s)`, derived from the prior
old/original sweep: `llama 60s`, `whisper 61s`, `gemma 147s`, `qwen3_moe 60s`,
`qwen 60s`, and `paged_llama 60s`. A `>` value means all runs in that
cell exceeded the cap and were recorded as `timeout_or_failed`. The timing
chart treats those timeout rows as right-censored lower bounds. The
percent-change chart treats them as exact capped-runtime observations for
`C = min(T, timeout)`, then uses the capped-runtime Fieller lower bound as a
lower bound for the true uncapped runtime ratio.

## Reproduce

```bash
scripts/render_timing_scatter.sh
```

The script builds the bench harness against `old`, `pr896`, and
`pr896_no_decomp`, then runs every model file both with
Rayon parallelism disabled (`RAYON_NUM_THREADS=1`, labeled `parallel off`) and
with the default Rayon thread pool (`parallel on`). The `pr896_no_decomp`
feature sets `EGraph::no_decomp = true`, equivalent to PR #896's global
`--no-decomp` option. By default it uses five runs per cell and the
per-benchmark timeout caps listed above. Override the run count with `RUNS=...`
if you want a longer sweep. It reads the static Vega-Lite specs in `scripts/`
and writes:

- `results/timings_scatter.csv`
- `results/timing_mean_ci.csv`
- `results/timings_scatter.png`
- `results/timing_percent_change.csv`
- `results/timing_percent_change.png`

To append only the PR #896 no-decomposition variant to an existing
`results/timings_scatter.csv` and then regenerate the summaries and PNGs, run:

```bash
scripts/append_pr896_no_decomp_timing.sh
```

The percent-change CSV uses the old serial (`parallel off`) mean for each
benchmark as the baseline and reports ratio-of-means percent change with a
one-level Fieller-style 95% confidence interval, following the
ratio-of-execution-time-means effect-size framing from Kalibera and Jones'
*Quantifying Performance Changes with Effect Size Confidence Intervals*.
When a ratio comparison has timed-out runs, the timeout cutoff is treated as an
exact capped-runtime observation for the capped metric. The reported true
uncapped runtime-ratio CI is `[capped Fieller lower, infinity)`, and the chart
draws the bar upward to the plot cap with a triangle marker.
This script treats each process-level run in `results/timings_scatter.csv`
as one sample; it does not attempt the full hierarchical experiment
dimensioning from Kalibera and Jones' *Rigorous Benchmarking in Reasonable
Time*. It also does not implement Chen et al.'s HPT method, which is better
suited as a suite-level decision layer than as the per-benchmark diagnostic
shown here. In that summary chart, `serial` means `RAYON_NUM_THREADS=1`;
`default Rayon` means no `RAYON_NUM_THREADS` override.

## Performance-change references

- Tomas Kalibera and Richard Jones, [*Quantifying Performance Changes with
  Effect Size Confidence Intervals*](https://arxiv.org/abs/2007.10899),
  University of Kent Technical Report 4-12 / arXiv:2007.10899.
- Tomas Kalibera and Richard E. Jones, [*Rigorous Benchmarking in Reasonable
  Time*](https://doi.org/10.1145/2464157.2464160), ISMM 2013.
- Tianshi Chen, Yunji Chen, Qi Guo, Olivier Temam, Yue Wu, and Weiwu Hu,
  [*Statistical Performance Comparisons of
  Computers*](https://doi.org/10.1109/HPCA.2012.6169043), HPCA 2012.

## The slow rule

The model files contain 25-30 atom `matmul_backend` joins with several
`nth_from_end` lookups and constraint atoms. A representative rule shape is:

```egglog
(rule
    (
        (= ?mul (Op (Mul ?mul_shape ?a_stride ?b_stride ?mul_out_stride)
                    (ICons ?a (ICons ?b (INil)))))
        (= ?sum (Op (Sum ?out_shape ?k ?sum_in_stride ?k_stride ?sum_out_stride)
                    (ICons ?mul (INil))))

        (= ?batch (nth_from_end ?out_shape 2))
        (= ?m     (nth_from_end ?out_shape 1))
        (= ?n     (nth_from_end ?out_shape 0))
        (!= ?m (MNum 0)) (!= ?n (MNum 0))
        (!= ?k (MNum 1)) (!= ?batch (MNum 0))

        (= ?a_batch_stride (nth_from_end ?a_stride 3))
        (= ?a_m_stride     (nth_from_end ?a_stride 2))
        (= ?a_n_stride     (nth_from_end ?a_stride 1))
        (= ?a_k_stride     (nth_from_end ?a_stride 0))

        (= ?b_batch_stride (nth_from_end ?b_stride 3))
        (= ?b_m_stride     (nth_from_end ?b_stride 2))
        (= ?b_n_stride     (nth_from_end ?b_stride 1))
        (= ?b_k_stride     (nth_from_end ?b_stride 0))

        (= ?k_stride (MIter))
        (= ?a_m_stride (MIter)) (= ?a_n_stride (MNum 0))
        (= ?a_k_stride (MMul (MIter) ?m))
        (= ?b_n_stride (MIter)) (= ?b_m_stride (MNum 0))
        (= ?b_k_stride (MMul (MIter) ?n))
        (= ?a_batch_stride (MMul ?k ?a_k_stride))
        (= ?b_batch_stride (MMul ?k ?b_k_stride))

        (= ?dt (dtype ?a)) (= ?dt (dtype ?b))
        (cublaslt_base_dtype ?dt)
    )
    ( ;; RHS — never fires in this repro
      (let ?sgemm (Op (cublaslt …) (ICons ?b (ICons ?a (INil)))))
      (union ?sum ?sgemm)
      (set (dtype ?sgemm) ?dt)
    )
    :ruleset matmul_backend
    :name "cublaslt batched column-major × row-major"
)
```

## Stage where slowdown lives

`EGraph::default()` and `parse_and_run_program(setup_code)` both run fine —
they load thousands of let-bindings in ~25-200 ms. It's the first
`(run-schedule …)` that contains the slow rule that explodes.

`set_report_level(ReportLevel::WithPlan)` triggers a separate `todo!()`
panic in `core-relations/src/free_join/plan.rs:254`
(`DecomposedPlan::to_report`) on exactly these rules. That strongly suggests
the rules are now compiling to a tree-decomposed query plan that the new
free-join planner picks poorly for this LHS shape, and that this is the
same code path that drives the runtime cost. (The repro here uses
`TimeOnly` to avoid that panic; the slowness shows up regardless.)

## Why these rules

These are matmul-pattern recognisers from luminal's CUDA backend: each
rule matches an `Op(Sum, …, Op(Mul, …))` pair, checks all the strides at
each axis via `nth_from_end`, makes sure batch/m/n/k are nonzero, and
finally constructs a `cublaslt` op invocation. The 4-element stride lists
+ shape-list joins are the structural reason there are so many premises.

## Notes

- E-graph contents are luminal-shaped HLIR (`Op (Mul …)`, `Op (Sum …)`,
  etc.) but the current evidence still points at planner/runtime behavior,
  not a semantic difference in the data.
- Timeout rows in `results/timings_scatter.csv` are censored observations at
  the configured cap. The raw timing chart treats them as lower-bounded
  right-censored observations; the percent-change chart uses capped-runtime
  Fieller lower bounds with infinite upper bounds for true uncapped runtime
  ratios.
