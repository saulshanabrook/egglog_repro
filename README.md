# egglog 0a8cc35 → 2e5657b: large multi-atom rule regression

## Summary

Between egglog rev `0a8cc35a6c68d0460c20449d5fa19ca3caba2923` and
`2e5657bbb2c1a90fba31002da61381815f891b6f` (~250 commits), full luminal-shaped
model `.egg` programs show large total-runtime regressions. With the bounded
local sweep checked in here (`RUNS=3`), `new` serial completes `llama`,
`qwen3_moe`, and `qwen` at roughly 18-23x the old serial mean, while
`whisper`, `gemma`, and `paged_llama` exceed their per-benchmark caps.

The same harness also compares PR
[`#857`](https://github.com/egraphs-good/egglog/pull/857), pinned to
`345fa8d93ff904865c1b69cffbaeeedf6b88cc09`, and latest upstream `main`,
pinned to `8c1c70b03b805b9a0062272ba64552cd5738454c`. On these full-model
inputs, PR #857 and latest main improve the qwen/llama-family cases relative
to `new`, but still time out on the larger model files under the current caps.

## Files

Seven self-contained `.egg` programs are checked in. The current default sweep
intentionally excludes `gemma4_moe.egg`, because old/original did not complete
under the previous cap and a manual probe ran past two minutes.

| file | size | cap | old serial mean | new serial | PR #857 serial | main serial |
|---|---:|---:|---:|---:|---:|---:|
| `llama.egg` | 445 KB | 60 s | 1.24 s | 21.94 s | 2.56 s | 2.65 s |
| `whisper.egg` | 478 KB | 61 s | 30.38 s | >61 s | >61 s | >61 s |
| `gemma.egg` | 916 KB | 147 s | 74.43 s | >147 s | >147 s | >147 s |
| `qwen3_moe.egg` | 524 KB | 60 s | 2.33 s | 53.07 s | 5.87 s | 6.02 s |
| `qwen.egg` | 474 KB | 60 s | 1.59 s | 33.30 s | 3.41 s | 3.48 s |
| `paged_llama.egg` | 437 KB | 60 s | 1.22 s | >60 s | >60 s | >60 s |
| `gemma4_moe.egg` | 1.4 MB | excluded | n/a | n/a | n/a | n/a |

These are total `parse_and_run_program` times from
`results/timings_scatter.csv`, using three runs per cell. The caps are
`max(ceil(2x max old/original complete timing), 60s)`, derived from the prior
old/original sweep: `llama 60s`, `whisper 61s`, `gemma 147s`, `qwen3_moe 60s`,
`qwen 60s`, and `paged_llama 60s`. A `>` value means all three runs in that
cell exceeded the cap and were recorded as `timeout_or_failed`. The scatter
plot includes those timeout rows at the cap; the percent-change CSV excludes
timeout rows and only reports cells with at least two complete samples and a
complete old-serial baseline.

## Reproduce

```bash
scripts/render_timing_scatter.sh
```

The script builds the bench harness against `old`, `new`, `pr857`, and
`latest_main`, then runs every model file both with Rayon parallelism disabled
(`RAYON_NUM_THREADS=1`, labeled `parallel off`) and with the default Rayon
thread pool (`parallel on`). By default it uses three runs per cell and the
per-benchmark timeout caps listed above. Override the run count with `RUNS=...`
if you want a longer sweep. It reads the static Vega-Lite specs in `scripts/`
and writes:

- `results/timings_scatter.csv`
- `results/timings_scatter.png`
- `results/timing_percent_change.csv`
- `results/timing_percent_change.png`

The percent-change CSV uses the old serial (`parallel off`) mean for each
benchmark as the baseline and reports ratio-of-means percent change with a
one-level Fieller-style 95% confidence interval, following the
ratio-of-execution-time-means effect-size framing from Kalibera and Jones'
*Quantifying Performance Changes with Effect Size Confidence Intervals*.
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
  the configured cap. They are useful in the scatter plot but are not used for
  ratio-of-means confidence intervals.
