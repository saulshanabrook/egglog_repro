use std::time::Instant;

#[cfg(feature = "new")]
use egglog_new as egglog;
#[cfg(feature = "old")]
use egglog_old as egglog;
#[cfg(feature = "pr857")]
use egglog_pr857 as egglog;
#[cfg(feature = "latest_main")]
use egglog_latest_main as egglog;

#[cfg(not(any(
    feature = "old",
    feature = "new",
    feature = "pr857",
    feature = "latest_main"
)))]
compile_error!("enable exactly one of the old, new, pr857, or latest_main features");
#[cfg(any(
    all(feature = "old", feature = "new"),
    all(feature = "old", feature = "pr857"),
    all(feature = "old", feature = "latest_main"),
    all(feature = "new", feature = "pr857"),
    all(feature = "new", feature = "latest_main"),
    all(feature = "pr857", feature = "latest_main"),
))]
compile_error!("enable exactly one of the old, new, pr857, or latest_main features");

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: bench <program.egg> [top_n]");
    let top_n: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    let program = std::fs::read_to_string(&path).expect("read program");
    eprintln!("loaded {} bytes from {}", program.len(), path);

    let mut egraph = egglog::EGraph::default();

    let t0 = Instant::now();
    if let Err(e) = egraph.parse_and_run_program(None, &program) {
        eprintln!("ERROR: {e}");
        std::process::exit(1);
    }
    let elapsed = t0.elapsed();
    println!("egglog total: {:.3}s", elapsed.as_secs_f64());
    println!("tuples after: {}", egraph.num_tuples());

    let report = egraph.get_overall_run_report();
    let mut rules: Vec<(String, std::time::Duration, usize)> = report
        .search_and_apply_time_per_rule
        .iter()
        .map(|(k, v)| {
            let m = report.num_matches_per_rule.get(k).copied().unwrap_or(0);
            (k.to_string(), *v, m)
        })
        .collect();
    rules.sort_by(|a, b| b.1.cmp(&a.1));
    if top_n > 0 {
        println!("--- top {} rules by search+apply time ---", top_n);
        for (name, dur, matches) in rules.iter().take(top_n) {
            let mut display = name.replace('\n', " ");
            if display.len() > 96 {
                display.truncate(93);
                display.push_str("...");
            }
            println!(
                "  {:>10.3} ms  matches={:>6}  {}",
                dur.as_secs_f64() * 1000.0,
                matches,
                display
            );
        }
    }
}
