#![forbid(unsafe_code)]
#![warn(missing_docs)]

//! Standalone binary entry point for the `cool-tunnel-core` engine.
//!
//! The binary now supports two operating modes from the same Mach-O
//! — same component, two front-ends:
//!
//!   * **Client mode** (default, no flags): long-lived JSON-over-stdio
//!     engine spawned by the macOS app. Reads `Request` frames on
//!     stdin, writes `Outbound` frames (response / error / event)
//!     on stdout, supervises the bundled `naive` subprocess.
//!     Implementation: [`client_mode::run`].
//!
//!   * **Server mode** (`--mode server [--listen ADDR]`): HTTP API
//!     for the Cool Tunnel admin UI (Filament/PHP server tier).
//!     Same engine logic — config + PAC generation, validation —
//!     exposed over HTTP/1.1 + JSON. Implementation:
//!     [`server_mode::run`].
//!
//! Both modes share the lib crate (`cool_tunnel_core::*`); the
//! split is purely about transport. That is the whole point of
//! the v0.2.0 cross-platform architecture: one Rust crate, many
//! UI layers — macOS today, Filament server tier tomorrow,
//! Win/Linux/iOS/Android clients after that.
//!
//! Error handling on every protocol boundary is total: malformed
//! frames produce structured errors rather than panicking, and
//! unknown CLI flags produce a usage hint rather than crashing.

use std::net::SocketAddr;
use std::process::ExitCode;

mod client_mode;
mod server_mode;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    // Short-circuit before tracing init so `--version` works on
    // sandboxed inspections that may not have stderr available.
    // The Swift `RustCoreResolver` greps the first line of stdout
    // for the canonical pattern; keep that wire format stable.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let parsed = match parse_args(&args) {
        Ok(p) => p,
        Err(message) => {
            eprintln!("cool-tunnel-core: {message}");
            eprintln!("try --help");
            return ExitCode::FAILURE;
        }
    };

    match parsed {
        Cli::Version => {
            // First line is the canonical wire format that the Swift
            // `RustCoreResolver` greps for: `cool-tunnel-core <semver>`.
            // Do not change. Everything below is metadata for support
            // tickets — safe to add to.
            println!("cool-tunnel-core {}", env!("CARGO_PKG_VERSION"));
            println!(
                "build:    {} {} ({})",
                env!("COOL_TUNNEL_BUILD_SHA"),
                env!("COOL_TUNNEL_BUILD_DATE"),
                if cfg!(debug_assertions) {
                    "debug"
                } else {
                    "release"
                },
            );
            ExitCode::SUCCESS
        }
        Cli::Help => {
            print_help();
            ExitCode::SUCCESS
        }
        Cli::Client => {
            init_tracing();
            tracing::info!("cool-tunnel-core starting (client mode)");
            if let Err(err) = client_mode::run().await {
                tracing::error!(error = %err, "client mode exited with error");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Cli::Server { listen } => {
            init_tracing();
            if let Err(err) = server_mode::run(listen).await {
                tracing::error!(error = %err, "server mode exited with error");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
    }
}

/// Parsed CLI surface. Keep tiny — full clap-style parsing is
/// overkill for two flags.
enum Cli {
    Version,
    Help,
    Client,
    Server { listen: SocketAddr },
}

/// Minimal argv parser. Recognises:
///
///   `--version` / `-V`
///   `--help` / `-h`
///   `--mode client` (same as no args)
///   `--mode server [--listen ADDR]`
///
/// Anything else returns `Err(usage)`. Order-sensitive on
/// `--mode <value>` and `--listen <value>` (value must follow the
/// flag); we don't accept `--mode=server` form to keep the parser
/// trivial.
fn parse_args(args: &[String]) -> Result<Cli, String> {
    if args.is_empty() {
        return Ok(Cli::Client);
    }
    let mut iter = args.iter().peekable();
    let mut mode = "client".to_owned();
    let mut listen = server_mode::DEFAULT_LISTEN.to_owned();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--version" | "-V" => return Ok(Cli::Version),
            "--help" | "-h" => return Ok(Cli::Help),
            "--mode" => {
                let Some(value) = iter.next() else {
                    return Err("--mode requires a value (client | server)".into());
                };
                value.clone_into(&mut mode);
            }
            "--listen" => {
                let Some(value) = iter.next() else {
                    return Err("--listen requires an address (e.g. 127.0.0.1:8787)".into());
                };
                value.clone_into(&mut listen);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    match mode.as_str() {
        "client" => Ok(Cli::Client),
        "server" => {
            let listen_addr: SocketAddr = listen
                .parse()
                .map_err(|err| format!("invalid --listen address {listen:?}: {err}"))?;
            Ok(Cli::Server {
                listen: listen_addr,
            })
        }
        other => Err(format!("unknown --mode value {other:?}")),
    }
}

fn print_help() {
    println!(
        "cool-tunnel-core {} ({} {})",
        env!("CARGO_PKG_VERSION"),
        env!("COOL_TUNNEL_BUILD_SHA"),
        env!("COOL_TUNNEL_BUILD_DATE"),
    );
    println!();
    println!("USAGE:");
    println!("    cool-tunnel-core [--mode client]                        # default");
    println!("    cool-tunnel-core --mode server [--listen ADDR]");
    println!();
    println!("MODES:");
    println!("    client    JSON-over-stdio engine driven by the macOS app");
    println!("              (default; this is what the bundled binary does).");
    println!();
    println!("    server    HTTP/1.1 + JSON API for the Cool Tunnel admin");
    println!("              UI (Filament/PHP). Default listen address:");
    println!("              {}", server_mode::DEFAULT_LISTEN);
    println!("              Endpoints: /health /version /naive/validate");
    println!("                         /naive/config /naive/pac");
    println!();
    println!("FLAGS:");
    println!("    --version, -V    Print version and exit");
    println!("    --help, -h       Print this help and exit");
}

fn init_tracing() {
    // Hard-clamped to `info`. We deliberately do **not** honour
    // `RUST_LOG` because a parent that sets `RUST_LOG=debug` could
    // enable verbose tracing on a future code path that touches
    // credentials, leaking them through stderr. Engine logs are a
    // stable, audited surface; raise the ceiling by editing this
    // line, not by setting an env var.
    let filter = tracing_subscriber::EnvFilter::new("info");
    // `try_init` instead of `init` so a future code path that
    // calls `init_tracing` twice (e.g. a test that drives both
    // client and server modes) doesn't panic on the second call.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .compact()
        .try_init();
}
