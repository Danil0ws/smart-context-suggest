//! Database layer for smart-context-suggest.
//!
//! Uses SQLite in WAL mode for:
//! - Fast concurrent reads (query on every keystroke)
//! - Non-blocking writes (record in background)
//! - Tiny footprint (~kilobytes per project)
//!
//! Schema: one table `memory` keyed by (directory, command).
//! All heavy work (scoring, ranking) happens in Rust, not SQL — keeps
//! the query simple and the schema stable.
use rusqlite::{params, Connection, Result};
use std::path::Path;

use crate::score::{self, Entry};

/// Open (or create) the database at `path` and run migrations.
pub fn open_and_migrate(path: &Path) -> Result<Connection> {
    // Create parent directories if they don't exist
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }

    let conn = Connection::open(path)?;

    // WAL mode: readers don't block writers and vice-versa.
    // Critical because `query` (foreground) and `record` (background) run concurrently.
    conn.execute_batch("PRAGMA journal_mode=WAL;")?;
    conn.execute_batch("PRAGMA synchronous=NORMAL;")?; // faster than FULL, safe with WAL
    conn.execute_batch("PRAGMA foreign_keys=ON;")?;

    // Schema migration: idempotent CREATE IF NOT EXISTS
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS memory (
            directory  TEXT    NOT NULL,
            command    TEXT    NOT NULL,
            frequency  INTEGER NOT NULL DEFAULT 1,
            first_seen INTEGER NOT NULL,
            last_used  INTEGER NOT NULL,
            success    INTEGER NOT NULL DEFAULT 0,
            total_runs INTEGER NOT NULL DEFAULT 1,
            is_project INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (directory, command)
        );
        CREATE INDEX IF NOT EXISTS idx_dir_last
            ON memory(directory, last_used DESC);

        -- System command index: all installed tools and their subcommands/flags.
        -- Populated by `smart-suggest index` (runs in background, 1x/week).
        CREATE TABLE IF NOT EXISTS commands (
            binary      TEXT NOT NULL,   -- top-level command name (e.g. 'docker')
            completion  TEXT NOT NULL,   -- full completion string (e.g. 'docker run --rm')
            kind        TEXT NOT NULL,   -- 'subcommand', 'flag', 'binary'
            description TEXT,            -- short description from --help (optional)
            indexed_at  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (binary, completion)
        );
        CREATE INDEX IF NOT EXISTS idx_cmd_binary
            ON commands(binary, kind);
        CREATE INDEX IF NOT EXISTS idx_cmd_completion
            ON commands(completion);
        ",
    )?;

    Ok(conn)
}

/// Insert a new record or increment frequency if (directory, command) already exists.
///
/// Called from `preexec` hook — must be fast (< 2 ms).
pub fn upsert_record(
    conn: &Connection,
    directory: &str,
    command: &str,
    now_secs: i64,
    is_project: bool,
) -> Result<()> {
    conn.execute(
        "INSERT INTO memory (directory, command, frequency, first_seen, last_used, success, total_runs, is_project)
         VALUES (?1, ?2, 1, ?3, ?3, 0, 1, ?4)
         ON CONFLICT(directory, command) DO UPDATE SET
             frequency  = frequency + 1,
             last_used  = ?3,
             total_runs = total_runs + 1,
             is_project = MAX(is_project, ?4)",
        params![directory, command, now_secs, is_project as i32],
    )?;
    Ok(())
}

/// Update the success flag for the most recent run of (directory, command).
///
/// Called from `precmd` hook after exit code is known.
pub fn mark_success(
    conn: &Connection,
    directory: &str,
    command: &str,
    ok: bool,
) -> Result<()> {
    // `success` tracks cumulative successful runs for success_ratio calculation
    if ok {
        conn.execute(
            "UPDATE memory SET success = success + 1
             WHERE directory = ?1 AND command = ?2",
            params![directory, command],
        )?;
    }
    Ok(())
}

/// Query top-N suggestions for the given directory and typed prefix.
///
/// Returns commands ordered by score (highest first).
/// `now_secs` and `half_life_hours` are passed in so the caller controls them
/// (avoids time-related test flakiness).
pub fn query_prefix(
    conn: &Connection,
    directory: &str,
    prefix: &str,
    limit: usize,
    now_secs: i64,
    half_life_hours: f64,
) -> Result<Vec<(String, f64)>> {
    // Fetch all rows for this directory that start with the prefix (SQL-level filter
    // to reduce result set before expensive score computation).
    // We intentionally don't do the full score in SQL — keep it simple & testable.
    let like_pattern = format!("{}%", prefix.replace('%', "\\%").replace('_', "\\_"));

    let mut stmt = conn.prepare_cached(
        "SELECT command, frequency, last_used, success, total_runs, is_project
         FROM memory
         WHERE directory = ?1 AND command LIKE ?2 ESCAPE '\\'
         ORDER BY last_used DESC
         LIMIT 200",
    )?;

    let mut entries: Vec<(Entry, f64)> = stmt
        .query_map(params![directory, like_pattern], |row| {
            let success: i64 = row.get(3)?;
            let total_runs: i64 = row.get(4).unwrap_or(1).max(1);
            let is_project: i32 = row.get(5)?;
            Ok(Entry {
                command: row.get(0)?,
                frequency: row.get(1)?,
                last_used: row.get(2)?,
                success_ratio: success as f64 / total_runs as f64,
                is_project: is_project != 0,
            })
        })?
        .filter_map(|r| r.ok())
        .map(|e| {
            let s = score::score(&e, prefix, now_secs, half_life_hours);
            (e, s)
        })
        .collect();

    // Sort by score descending
    entries.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    entries.truncate(limit);

    Ok(entries.into_iter().map(|(e, s)| (e.command, s)).collect())
}

/// Decay: remove stale entries and reduce frequency of old ones.
///
/// - Entries last used more than `stale_days` ago with frequency <= 2 → deleted.
/// - Others with age > stale_days/2 → frequency reduced by 10% (floor, min 1).
///
/// Runs once per day from `precmd`.
pub fn apply_decay(conn: &Connection, stale_days: i64, now_secs: i64) -> Result<(usize, usize)> {
    let stale_cutoff = now_secs - stale_days * 86400;
    let half_cutoff = now_secs - (stale_days / 2).max(1) * 86400;

    // Delete stale weak entries
    let deleted = conn.execute(
        "DELETE FROM memory WHERE last_used < ?1 AND frequency <= 2",
        params![stale_cutoff],
    )?;

    // Reduce frequency of entries in the half-life zone
    let decayed = conn.execute(
        "UPDATE memory
         SET frequency = MAX(1, CAST(frequency * 0.9 AS INTEGER))
         WHERE last_used < ?1 AND last_used >= ?2",
        params![half_cutoff, stale_cutoff],
    )?;

    Ok((deleted, decayed))
}

/// List all entries for a directory, ordered by score.
pub fn list_dir(
    conn: &Connection,
    directory: &str,
    now_secs: i64,
    half_life_hours: f64,
) -> Result<Vec<(String, f64, i64, i64)>> {
    let mut stmt = conn.prepare(
        "SELECT command, frequency, last_used, success, total_runs, is_project
         FROM memory
         WHERE directory = ?1
         ORDER BY last_used DESC",
    )?;

    let mut entries: Vec<(Entry, i64)> = stmt
        .query_map(params![directory], |row| {
            let success: i64 = row.get(3)?;
            let total_runs: i64 = row.get(4).unwrap_or(1).max(1);
            let is_project: i32 = row.get(5)?;
            Ok((
                Entry {
                    command: row.get(0)?,
                    frequency: row.get(1)?,
                    last_used: row.get(2)?,
                    success_ratio: success as f64 / total_runs as f64,
                    is_project: is_project != 0,
                },
                row.get::<_, i64>(1)?,
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();

    let mut scored: Vec<(Entry, f64, i64)> = entries
        .drain(..)
        .map(|(e, freq)| {
            let s = score::score(&e, "", now_secs, half_life_hours);
            (e, s, freq)
        })
        .collect();

    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok(scored
        .into_iter()
        .map(|(e, s, freq)| (e.command, s, freq, e.last_used))
        .collect())
}

/// Global stats: total entries, top directories, top commands.
pub fn stats(conn: &Connection) -> Result<Stats> {
    let total: i64 = conn.query_row("SELECT COUNT(*) FROM memory", [], |r| r.get(0))?;
    let total_dirs: i64 =
        conn.query_row("SELECT COUNT(DISTINCT directory) FROM memory", [], |r| {
            r.get(0)
        })?;

    let mut stmt = conn.prepare(
        "SELECT directory, SUM(frequency) as freq
         FROM memory GROUP BY directory ORDER BY freq DESC LIMIT 10",
    )?;
    let top_dirs: Vec<(String, i64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .filter_map(|r| r.ok())
        .collect();

    let mut stmt2 = conn.prepare(
        "SELECT command, SUM(frequency) as freq
         FROM memory GROUP BY command ORDER BY freq DESC LIMIT 10",
    )?;
    let top_cmds: Vec<(String, i64)> = stmt2
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .filter_map(|r| r.ok())
        .collect();

    Ok(Stats {
        total_entries: total,
        total_directories: total_dirs,
        top_directories: top_dirs,
        top_commands: top_cmds,
    })
}

/// Delete entries: either for a specific directory or all.
pub fn clear(conn: &Connection, directory: Option<&str>) -> Result<usize> {
    match directory {
        Some(dir) => Ok(conn.execute("DELETE FROM memory WHERE directory = ?1", params![dir])?),
        None => Ok(conn.execute("DELETE FROM memory", [])?),
    }
}

/// Export all entries as a Vec of maps (for JSON serialization).
pub fn export_all(conn: &Connection) -> Result<Vec<MemoryRow>> {
    let mut stmt = conn.prepare(
        "SELECT directory, command, frequency, first_seen, last_used, success, total_runs, is_project
         FROM memory ORDER BY directory, last_used DESC",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(MemoryRow {
                directory: r.get(0)?,
                command: r.get(1)?,
                frequency: r.get(2)?,
                first_seen: r.get(3)?,
                last_used: r.get(4)?,
                success: r.get(5)?,
                total_runs: r.get(6)?,
                is_project: r.get::<_, i32>(7)? != 0,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();
    Ok(rows)
}

// ---------- System command index ----------

/// Insert or replace a completion entry in the commands table.
pub fn index_command(
    conn: &Connection,
    binary: &str,
    completion: &str,
    kind: &str,
    description: Option<&str>,
    now_secs: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO commands (binary, completion, kind, description, indexed_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(binary, completion) DO UPDATE SET
             kind        = ?3,
             description = ?4,
             indexed_at  = ?5",
        params![binary, completion, kind, description, now_secs],
    )?;
    Ok(())
}

/// Query completions matching a prefix from the commands table.
/// Returns (completion, kind, description) tuples.
pub fn query_commands(
    conn: &Connection,
    prefix: &str,
    limit: usize,
) -> Result<Vec<(String, String, Option<String>)>> {
    let like = format!("{}%", prefix.replace('%', "\\%").replace('_', "\\_"));
    let mut stmt = conn.prepare_cached(
        "SELECT completion, kind, description
         FROM commands
         WHERE completion LIKE ?1 ESCAPE '\\'
         ORDER BY
           CASE kind WHEN 'binary' THEN 0 WHEN 'subcommand' THEN 1 ELSE 2 END,
           completion
         LIMIT ?2",
    )?;
    let rows = stmt
        .query_map(params![like, limit as i64], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .filter_map(|r| r.ok())
        .collect();
    Ok(rows)
}

#[allow(dead_code)]
pub fn clear_binary_index(conn: &Connection, binary: &str) -> Result<()> {
    conn.execute("DELETE FROM commands WHERE binary = ?1", params![binary])?;
    Ok(())
}

/// Stats about the command index.
pub fn index_stats(conn: &Connection) -> Result<(i64, i64)> {
    let total_completions: i64 =
        conn.query_row("SELECT COUNT(*) FROM commands", [], |r| r.get(0))?;
    let total_binaries: i64 =
        conn.query_row("SELECT COUNT(DISTINCT binary) FROM commands", [], |r| r.get(0))?;
    Ok((total_completions, total_binaries))
}

// ---------- Data types ----------

pub struct Stats {
    pub total_entries: i64,
    pub total_directories: i64,
    pub top_directories: Vec<(String, i64)>,
    pub top_commands: Vec<(String, i64)>,
}

#[derive(serde::Serialize)]
pub struct MemoryRow {
    pub directory: String,
    pub command: String,
    pub frequency: i64,
    pub first_seen: i64,
    pub last_used: i64,
    pub success: i64,
    pub total_runs: i64,
    pub is_project: bool,
}

// ---------- Tests ----------
#[cfg(test)]
mod tests {
    use super::*;

    fn in_memory_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS memory (
                directory  TEXT    NOT NULL,
                command    TEXT    NOT NULL,
                frequency  INTEGER NOT NULL DEFAULT 1,
                first_seen INTEGER NOT NULL,
                last_used  INTEGER NOT NULL,
                success    INTEGER NOT NULL DEFAULT 0,
                total_runs INTEGER NOT NULL DEFAULT 1,
                is_project INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (directory, command)
            );
            CREATE INDEX IF NOT EXISTS idx_dir_last ON memory(directory, last_used DESC);",
        )
        .unwrap();
        conn
    }

    #[test]
    fn upsert_increments_frequency() {
        let conn = in_memory_db();
        upsert_record(&conn, "/proj", "make build", 1000, false).unwrap();
        upsert_record(&conn, "/proj", "make build", 1001, false).unwrap();
        let freq: i64 = conn
            .query_row(
                "SELECT frequency FROM memory WHERE directory='/proj' AND command='make build'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(freq, 2);
    }

    #[test]
    fn query_returns_scored_results() {
        let conn = in_memory_db();
        let now = 1_700_000_000i64;
        upsert_record(&conn, "/proj", "make build", now - 100, false).unwrap();
        upsert_record(&conn, "/proj", "make test", now - 200, false).unwrap();
        upsert_record(&conn, "/other", "make build", now - 50, false).unwrap();

        let results = query_prefix(&conn, "/proj", "make", 10, now, 168.0).unwrap();
        // Both /proj entries should appear
        assert_eq!(results.len(), 2);
        // /other should not appear
        assert!(!results.iter().any(|(c, _)| c == "ls -la"));
    }

    #[test]
    fn directory_isolation() {
        let conn = in_memory_db();
        let now = 1_700_000_000i64;
        upsert_record(&conn, "/proj-a", "make build", now, false).unwrap();
        let results = query_prefix(&conn, "/proj-b", "make", 10, now, 168.0).unwrap();
        assert!(results.is_empty(), "commands from other dirs must not leak");
    }

    #[test]
    fn decay_removes_stale_weak_entries() {
        let conn = in_memory_db();
        let now = 1_700_000_000i64;
        // Insert an old, rarely-used entry
        conn.execute(
            "INSERT INTO memory VALUES ('/p','old-cmd',1,0,0,1,1,0)",
            [],
        )
        .unwrap();
        let (deleted, _) = apply_decay(&conn, 90, now).unwrap();
        assert!(deleted >= 1, "stale weak entry should be deleted");
    }
}
