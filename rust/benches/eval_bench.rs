//! Native Rust micro-benchmarks for `eval_blocking` against a real
//! `emacs --daemon`, using `criterion` rather than a shared
//! cross-language driver -- these numbers are for tracking this
//! language's own per-call cost over time, not for a cross-language
//! latency comparison.
//!
//! Gated on `SPRITE_TEST_SOCKET`, same convention as
//! `tests/integration.rs`. If unset, both benchmark groups are skipped
//! (criterion has no first-class "skip" concept, so this just prints a
//! notice and exits 0 without registering any benchmarks). Run with:
//!
//! ```sh
//! SPRITE_TEST_SOCKET=/path/to/socket cargo bench --bench eval_bench
//! ```

use std::process::Command;

use criterion::{criterion_group, criterion_main, Criterion};
use sprite_direct::eval_blocking;
use sprite_direct::sexp::Sexp;

fn forms() -> Vec<(&'static str, Sexp)> {
    vec![
        (
            "small-int",
            Sexp::List(vec![Sexp::Sym("+".into()), Sexp::Int(1), Sexp::Int(2)]),
        ),
        (
            "large-string",
            Sexp::List(vec![
                Sexp::Sym("make-string".into()),
                Sexp::Int(5000),
                Sexp::Int(120),
            ]),
        ),
    ]
}

fn raw_forms() -> Vec<(&'static str, &'static str)> {
    vec![
        ("small-int", "(+ 1 2)"),
        ("large-string", "(make-string 5000 120)"),
    ]
}

fn bench_eval_blocking(c: &mut Criterion) {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        eprintln!("SPRITE_TEST_SOCKET not set; skipping benchmark");
        return;
    };

    let mut group = c.benchmark_group("eval_blocking");
    for (name, form) in forms() {
        group.bench_function(name, |b| {
            b.iter(|| eval_blocking(&socket, &form, None, None).expect("eval_blocking failed"));
        });
    }
    group.finish();
}

fn bench_emacsclient_subprocess(c: &mut Criterion) {
    let Ok(socket) = std::env::var("SPRITE_TEST_SOCKET") else {
        return;
    };
    if Command::new("which").arg("emacsclient").output().is_err() {
        eprintln!("emacsclient binary not found on PATH; skipping benchmark");
        return;
    }

    let mut group = c.benchmark_group("emacsclient_subprocess");
    for (name, form) in raw_forms() {
        group.bench_function(name, |b| {
            b.iter(|| {
                let output = Command::new("emacsclient")
                    .arg(format!("--socket-name={socket}"))
                    .arg("--eval")
                    .arg(form)
                    .output()
                    .expect("failed to run emacsclient");
                assert!(output.status.success());
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_eval_blocking, bench_emacsclient_subprocess);
criterion_main!(benches);
