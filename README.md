# egglog 0a8cc35 → 2e5657b: large multi-atom rule regression

## Summary

Between egglog rev `0a8cc35a6c68d0460c20449d5fa19ca3caba2923` and
`2e5657bbb2c1a90fba31002da61381815f891b6f` (~250 commits), small-graph rule
application got a bit faster, but **multi-atom rules with ~25-30 LHS atoms
regressed 400-1600× per invocation** against e-graphs of a few thousand
tuples. The slow rules in this repro have **0 matches** on both egglog
versions — the optimisation is correct, same final e-graph in both cases,
only the time differs.

The same regression manifests upstream as luminal LLM compile-time hangs
(gemma, paged_llama, gemma4_moe), 4 flashinfer cuda tests that pass in
~1.5 s on the old rev hanging >120 s on the new one, and a 14× egglog-runtime
regression on the qwen LLM compile pipeline.

## Files

Three self-contained `.egg` programs, each runnable by `parse_and_run_program`:

| file | rules | lets | bytes | OLD total | NEW total | target-rule OLD | target-rule NEW |
|---|---:|---:|---:|---:|---:|---:|---:|
| `qwen_minimal.egg`              | 138 | 1213 | 149 KB | 0.24 s | 0.20 s | **0.11 ms** | **51 ms** (~470×) |
| `qwen_one_cublaslt_rule.egg`    | 138 | 2053 | 230 KB | 0.52 s | 0.50 s | **0.15 ms** | **245 ms** (~1600×) |
| `qwen_all_cublaslt_rules.egg`   |  95 | 2053 | 329 KB | 0.57 s | 4.26 s | — | — (7.4× total) |

- `qwen_minimal.egg` — the smallest variant that still triggers the slow
  path. Has `expr` + `dtype_prop` rulesets plus the one slow rule. Below
  ~1213 let-defs the slow rule's first premise has no candidate `Op(Mul,...)`
  to enumerate so the planner short-circuits and the regression vanishes.
- `qwen_one_cublaslt_rule.egg` — same rules as `qwen_minimal` but with the
  full qwen-3-4b e-graph (2053 let-defs). Same rule, bigger per-rule time.
- `qwen_all_cublaslt_rules.egg` — drops `expr`+`dtype_prop` rules that
  weren't firing, keeps all 17 multi-atom `matmul_backend` rules so the
  total saturation time shows the cumulative regression.

All three produce **identical final tuple counts** on OLD and NEW, so the
optimisation is still correct.

## Candidate fix branch

This harness can also build against PR
[`#857`](https://github.com/egraphs-good/egglog/pull/857), pinned to head
commit `345fa8d93ff904865c1b69cffbaeeedf6b88cc09`.

On a local run, that branch reduces the target zero-match cublaslt rule from
~22 ms to ~0.4 ms on `qwen_minimal.egg`, and from ~104 ms to ~0.7 ms on
`qwen_one_cublaslt_rule.egg`. The full cublaslt ruleset total drops from
~1.85 s on NEW to ~0.19 s on the PR branch, with identical final tuple counts.

The harness also includes latest upstream `main`, pinned to commit
`8c1c70b03b805b9a0062272ba64552cd5738454c` (`main 8c1c70b` in the plot).
On the same five-run local timing sweep, latest `main` stays in the same
range as PR #857: ~0.40 ms on `qwen_minimal.egg`, ~0.77 ms on
`qwen_one_cublaslt_rule.egg`, and ~0.19 s on the full cublaslt ruleset.

## Reproduce

```bash
# Build the bench harness against each rev / branch
cargo build --release --features old --no-default-features
cp target/release/bench /tmp/bench_old
cargo build --release --features new --no-default-features
cp target/release/bench /tmp/bench_new
cargo build --release --features pr857 --no-default-features
cp target/release/bench /tmp/bench_pr857
cargo build --release --features latest_main --no-default-features
cp target/release/bench /tmp/bench_latest_main

# Cleanest single-rule signal (149 KB file, 0 matches)
/tmp/bench_old qwen_minimal.egg 5
/tmp/bench_new qwen_minimal.egg 5
/tmp/bench_pr857 qwen_minimal.egg 5
/tmp/bench_latest_main qwen_minimal.egg 5

# Bigger e-graph: 1600× on the same rule
/tmp/bench_old qwen_one_cublaslt_rule.egg 5
/tmp/bench_new qwen_one_cublaslt_rule.egg 5
/tmp/bench_pr857 qwen_one_cublaslt_rule.egg 5
/tmp/bench_latest_main qwen_one_cublaslt_rule.egg 5

# Full ruleset: 7.4× total saturation time
/tmp/bench_old qwen_all_cublaslt_rules.egg 10
/tmp/bench_new qwen_all_cublaslt_rules.egg 10
/tmp/bench_pr857 qwen_all_cublaslt_rules.egg 10
/tmp/bench_latest_main qwen_all_cublaslt_rules.egg 10
```

To regenerate the five-run timing scatter plot:

```bash
scripts/render_timing_scatter.sh
```

This runs each benchmark both with Rayon parallelism disabled
(`RAYON_NUM_THREADS=1`, labeled `parallel off`) and with the default Rayon
thread pool (`parallel on`). It reads `scripts/timings_scatter.vl.json` and
writes:

- `results/timings_scatter.csv`
- `results/timings_scatter.png`

## The slow rule

All slow rules are 25-30 atom joins with several `nth_from_end` lookups
and constraint atoms. The single rule in `qwen_minimal.egg` /
`qwen_one_cublaslt_rule.egg`:

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

- The minimal file (`qwen_minimal.egg`) is the cleanest signal: ~0.11 ms vs
  ~51 ms for **one** invocation of **one** rule, with 0 matches, against
  ~4750 tuples. Smaller e-graphs (below ~1213 let-defs in the slimmed
  file) eliminate all candidate `Op(Mul,...)` shapes the rule's first
  premise could even enumerate, so the planner short-circuits and the
  regression vanishes.
- E-graph contents are luminal-shaped HLIR (`Op (Mul …)`, `Op (Sum …)`,
  etc.) but the regression is the planner's, not the data's.
