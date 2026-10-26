/// smart-suggest — CLI backend for the smart-context-suggest zsh plugin.
///
/// All subcommands are designed to be called from Zsh hooks.
/// Design goals:
///   - `record` and `mark-success`: < 2 ms (run on every command)
///   - `query`: < 5 ms (run on every keystroke via autosuggest)
///   - `decay`: can be slower, runs once per day
///
/// Usage:
///   smart-suggest record    --dir <D> --cmd <C> --ts <T> [--is-project]
///   smart-suggest mark-success --dir <D> --cmd <C> --ok <0|1>
///   smart-suggest query     --dir <D> --prefix <P> [--limit <N>] [--json] [--scores]
///   smart-suggest decay     [--stale-days <N>]
///   smart-suggest list      [--dir <D>]
///   smart-suggest stats
///   smart-suggest clear     [--dir <D> | --all]
///   smart-suggest export
///   smart-suggest debug     <on|off>

mod db;
mod score;

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: smart-suggest <subcommand> [options]");
        eprintln!("Subcommands: record, mark-success, query, decay, list, stats, clear, export, debug");
        std::process::exit(1);
    }

    let db_path = db_path();
    let result = match args[1].as_str() {
        "record" => cmd_record(&args[2..], &db_path),
        "mark-success" => cmd_mark_success(&args[2..], &db_path),
        "query" => cmd_query(&args[2..], &db_path),
        "decay" => cmd_decay(&args[2..], &db_path),
        "list" => cmd_list(&args[2..], &db_path),
        "stats" => cmd_stats(&db_path),
        "clear" => cmd_clear(&args[2..], &db_path),
        "export" => cmd_export(&db_path),
        "debug" => cmd_debug(&args[2..]),
        "index" => cmd_index(&args[2..], &db_path),
        "query-cmd" => cmd_query_cmd(&args[2..], &db_path),
        "index-stats" => cmd_index_stats(&db_path),
        _ => {
            eprintln!("Unknown subcommand: {}", args[1]);
            std::process::exit(1);
        }
    };

    if let Err(e) = result {
        eprintln!("smart-suggest error: {e}");
        std::process::exit(1);
    }
}

// ---------- Subcommand implementations ----------

/// `record --dir D --cmd C [--ts T] [--is-project]`
fn cmd_record(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let dir = require_flag(args, "--dir")?;
    let cmd = require_flag(args, "--cmd")?;
    let ts = flag_i64(args, "--ts").unwrap_or_else(now_secs);
    let is_project = args.contains(&"--is-project".to_string());

    // Skip empty or whitespace-only commands
    if cmd.trim().is_empty() {
        return Ok(());
    }

    let conn = db::open_and_migrate(db_path)?;
    db::upsert_record(&conn, &dir, &cmd, ts, is_project)?;

    debug_log(&format!("record dir={dir} cmd={cmd} ts={ts} project={is_project}"));
    Ok(())
}

/// `mark-success --dir D --cmd C --ok 0|1`
fn cmd_mark_success(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let dir = require_flag(args, "--dir")?;
    let cmd = require_flag(args, "--cmd")?;
    let ok_str = flag_value(args, "--ok").unwrap_or_default();
    let ok = ok_str == "1" || ok_str == "true";

    let conn = db::open_and_migrate(db_path)?;
    db::mark_success(&conn, &dir, &cmd, ok)?;

    debug_log(&format!("mark-success dir={dir} cmd={cmd} ok={ok}"));
    Ok(())
}

/// `query --dir D --prefix P [--limit N] [--json] [--scores]`
///
/// Prints top suggestions, one per line.
/// With --json: prints JSON array of {command, score}.
/// With --scores: appends score after a tab.
fn cmd_query(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let dir = require_flag(args, "--dir")?;
    let prefix = flag_value(args, "--prefix").unwrap_or_default();
    let limit = flag_usize(args, "--limit").unwrap_or(10);
    let json = args.contains(&"--json".to_string());
    let show_scores = args.contains(&"--scores".to_string());
    let half_life = flag_f64(args, "--half-life")
        .unwrap_or(score::DEFAULT_HALF_LIFE_HOURS);

    // Skip query if prefix is empty and we're not in list mode (avoids noisy results)
    // But allow it so callers can get the top-N for interactive menus.

    let conn = db::open_and_migrate(db_path)?;
    let results = db::query_prefix(&conn, &dir, &prefix, limit, now_secs(), half_life)?;

    if json {
        let items: Vec<serde_json::Value> = results
            .iter()
            .map(|(cmd, s)| {
                serde_json::json!({"command": cmd, "score": s})
            })
            .collect();
        println!("{}", serde_json::to_string(&items)?);
    } else if show_scores {
        for (cmd, s) in &results {
            println!("{cmd}\t{s:.4}");
        }
    } else {
        for (cmd, _) in &results {
            println!("{cmd}");
        }
    }

    if let Some((top_cmd, top_score)) = results.first() {
        debug_log(&format!(
            "query dir={dir} prefix={prefix:?} top={top_cmd:?} score={top_score:.4} results={}",
            results.len()
        ));
    }

    Ok(())
}

/// `decay [--stale-days N]`
fn cmd_decay(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let stale_days = flag_i64(args, "--stale-days").unwrap_or(90);
    let conn = db::open_and_migrate(db_path)?;
    let (deleted, decayed) = db::apply_decay(&conn, stale_days, now_secs())?;
    // Only print if called interactively (stdout is a tty)
    if atty() {
        println!("Decay complete: {deleted} entries removed, {decayed} entries weakened.");
    }
    debug_log(&format!("decay stale_days={stale_days} deleted={deleted} decayed={decayed}"));
    Ok(())
}

/// `list [--dir D]`
fn cmd_list(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let dir = flag_value(args, "--dir").unwrap_or_else(|| {
        std::env::current_dir()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    });
    let half_life = flag_f64(args, "--half-life").unwrap_or(score::DEFAULT_HALF_LIFE_HOURS);
    let json = args.contains(&"--json".to_string());

    let conn = db::open_and_migrate(db_path)?;
    let entries = db::list_dir(&conn, &dir, now_secs(), half_life)?;

    if entries.is_empty() {
        if !json {
            eprintln!("No entries for directory: {dir}");
        } else {
            println!("[]");
        }
        return Ok(());
    }

    if json {
        let items: Vec<serde_json::Value> = entries
            .iter()
            .map(|(cmd, score, freq, lu)| {
                serde_json::json!({
                    "command": cmd,
                    "score": score,
                    "frequency": freq,
                    "last_used": lu,
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items)?);
    } else {
        println!("Commands in {dir}:");
        println!("{:<50} {:>8} {:>10}", "COMMAND", "FREQ", "SCORE");
        println!("{}", "-".repeat(72));
        for (cmd, s, freq, _) in &entries {
            println!("{:<50} {:>8} {:>10.4}", cmd, freq, s);
        }
    }
    Ok(())
}

/// `stats`
fn cmd_stats(db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let conn = db::open_and_migrate(db_path)?;
    let s = db::stats(&conn)?;

    println!("smart-context-suggest statistics");
    println!("  Total entries:      {}", s.total_entries);
    println!("  Total directories:  {}", s.total_directories);
    println!();
    println!("  Top directories by usage:");
    for (dir, freq) in &s.top_directories {
        println!("    {:>8}  {}", freq, dir);
    }
    println!();
    println!("  Top commands globally:");
    for (cmd, freq) in &s.top_commands {
        println!("    {:>8}  {}", freq, cmd);
    }
    Ok(())
}

/// `clear [--dir D | --all]`
fn cmd_clear(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let all = args.contains(&"--all".to_string());
    let dir = flag_value(args, "--dir");

    if !all && dir.is_none() {
        eprintln!("Specify --dir <path> or --all");
        std::process::exit(1);
    }

    let conn = db::open_and_migrate(db_path)?;
    let n = db::clear(&conn, if all { None } else { dir.as_deref() })?;
    println!("Cleared {n} entries.");
    Ok(())
}

/// `export` — prints all entries as JSON to stdout.
fn cmd_export(db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let conn = db::open_and_migrate(db_path)?;
    let rows = db::export_all(&conn)?;
    println!("{}", serde_json::to_string_pretty(&rows)?);
    Ok(())
}

/// `debug on|off`
fn cmd_debug(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let flag_path = debug_flag_path();
    match args.first().map(|s| s.as_str()) {
        Some("on") => {
            if let Some(parent) = flag_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&flag_path, "")?;
            println!("Debug logging enabled. Log: {}", debug_log_path().display());
        }
        Some("off") => {
            std::fs::remove_file(&flag_path).ok();
            println!("Debug logging disabled.");
        }
        _ => {
            let status = if flag_path.exists() { "on" } else { "off" };
            println!("Debug is {status}.");
        }
    }
    Ok(())
}

/// `index --binary B --completion C --kind K [--desc D] [--ts T]`
///
/// Stores one completion entry for a binary.
/// Called in batch from the Zsh indexer for each discovered subcommand/flag.
fn cmd_index(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let binary = require_flag(args, "--binary")?;
    let completion = require_flag(args, "--completion")?;
    let kind = flag_value(args, "--kind").unwrap_or_else(|| "subcommand".into());
    let desc = flag_value(args, "--desc");
    let ts = flag_i64(args, "--ts").unwrap_or_else(now_secs);

    if binary.trim().is_empty() || completion.trim().is_empty() {
        return Ok(());
    }

    let conn = db::open_and_migrate(db_path)?;
    db::index_command(&conn, &binary, &completion, &kind, desc.as_deref(), ts)?;
    Ok(())
}

/// `query-cmd --prefix P [--limit N] [--json]`
///
/// Query the command index for completions matching a prefix.
/// Used by the fzf menu to show system-wide completions.
fn cmd_query_cmd(args: &[String], db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let prefix = flag_value(args, "--prefix").unwrap_or_default();
    let limit = flag_usize(args, "--limit").unwrap_or(30);
    let json = args.contains(&"--json".to_string());

    let conn = db::open_and_migrate(db_path)?;
    let results = db::query_commands(&conn, &prefix, limit)?;

    if json {
        let items: Vec<serde_json::Value> = results
            .iter()
            .map(|(c, k, d)| serde_json::json!({"completion": c, "kind": k, "description": d}))
            .collect();
        println!("{}", serde_json::to_string(&items)?);
    } else {
        for (completion, _kind, desc) in &results {
            if let Some(d) = desc {
                println!("{completion}\t{d}");
            } else {
                println!("{completion}");
            }
        }
    }
    Ok(())
}

/// `index-stats`
fn cmd_index_stats(db_path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let conn = db::open_and_migrate(db_path)?;
    let (completions, binaries) = db::index_stats(&conn)?;
    println!("Command index: {completions} completions across {binaries} binaries");
    Ok(())
}

// ---------- Helpers ----------

fn db_path() -> PathBuf {
    let base = std::env::var("SMART_SUGGEST_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let xdg = std::env::var("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|_| {
                    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
                    PathBuf::from(home).join(".local/share")
                });
            xdg.join("smart-context-suggest")
        });
    base.join("memory.db")
}

fn debug_flag_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join(".cache/smart-context-suggest/debug.enabled")
}

fn debug_log_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join(".cache/smart-context-suggest/debug.log")
}

fn debug_log(msg: &str) {
    let flag = debug_flag_path();
    if !flag.exists() {
        return;
    }
    let log_path = debug_log_path();
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        let ts = now_secs();
        writeln!(f, "[{ts}] {msg}").ok();
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn atty() -> bool {
    // Rough check: if stdin is a tty, we're probably interactive
    unsafe { libc_isatty(1) }
}

#[cfg(unix)]
fn libc_isatty(fd: i32) -> bool {
    extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    unsafe { isatty(fd) != 0 }
}

#[cfg(not(unix))]
fn libc_isatty(_fd: i32) -> bool {
    false
}

fn require_flag(args: &[String], flag: &str) -> Result<String, Box<dyn std::error::Error>> {
    flag_value(args, flag).ok_or_else(|| format!("missing required flag {flag}").into())
}

fn flag_value(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].clone())
}

fn flag_i64(args: &[String], flag: &str) -> Option<i64> {
    flag_value(args, flag)?.parse().ok()
}

fn flag_usize(args: &[String], flag: &str) -> Option<usize> {
    flag_value(args, flag)?.parse().ok()
}

fn flag_f64(args: &[String], flag: &str) -> Option<f64> {
    flag_value(args, flag)?.parse().ok()
}
