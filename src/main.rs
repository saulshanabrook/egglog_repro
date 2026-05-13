use std::time::Instant;

#[cfg(feature = "old")]
use egglog_old as egglog;
#[cfg(feature = "new")]
use egglog_new as egglog;

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
