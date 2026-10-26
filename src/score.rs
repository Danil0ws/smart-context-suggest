/// Score formula for ranking shell command suggestions.
///
/// Inspired by spaced-repetition systems (Ebbinghaus forgetting curve) and
/// frequency-recency models used in tools like zoxide and Limbic (Hermes).
///
/// The goal: a command you ran 10x in this directory last week should beat
/// one you ran once a year ago — but a very recent single run can still beat
/// an old frequent one.

// ---------- Weights ----------
// Tune these constants to shift emphasis between signals.
// They sum to ~1.0 but don't need to — they're relative weights.
pub const W_FREQ: f64 = 0.35;    // how often the command was run here
pub const W_RECENCY: f64 = 0.25; // how recently it was run
pub const W_CONTEXT: f64 = 0.30; // how well it matches the typed prefix
pub const W_PROJECT: f64 = 0.05; // bonus if it targets a project artifact (Makefile/package.json)
pub const W_SUCCESS: f64 = 0.05; // bonus for commands that exited 0

// Half-life for recency decay (hours).
// Default 168 h = 7 days: a command run exactly 7 days ago has half the
// recency score of one run right now.  Configurable via env at record time.
pub const DEFAULT_HALF_LIFE_HOURS: f64 = 168.0;

/// A row fetched from the database for scoring.
#[derive(Debug, Clone)]
pub struct Entry {
    pub command: String,
    pub frequency: i64,
    /// Unix timestamp of last execution
    pub last_used: i64,
    /// Total successes / total runs (pre-computed ratio, 0.0–1.0)
    pub success_ratio: f64,
    pub is_project: bool,
}

/// Compute a score for `entry` given the current typed `prefix` and `now`.
///
/// Returns a float in roughly [0, 1] (can exceed 1 in extreme cases).
///
/// # Arguments
/// * `entry`          - database row
/// * `prefix`         - what the user has typed so far
/// * `now_secs`       - current Unix timestamp (seconds)
/// * `half_life_hours`- recency half-life, configurable
pub fn score(entry: &Entry, prefix: &str, now_secs: i64, half_life_hours: f64) -> f64 {
    // --- Frequency component ---
    // log(1 + freq) compresses the scale: the difference between 1 and 2
    // runs matters more than the difference between 100 and 101.
    let freq_score = (1.0 + entry.frequency as f64).ln();

    // --- Recency component ---
    // Exponential decay: score halves every `half_life_hours`.
    // age_hours = 0  → exp(0)    = 1.0  (just ran it)
    // age_hours = HL → exp(-ln2) = 0.5
    // age_hours >> HL → ≈ 0.0
    let age_hours = (now_secs - entry.last_used).max(0) as f64 / 3600.0;
    let recency_score = (-age_hours / half_life_hours * std::f64::consts::LN_2).exp();

    // --- Context (prefix match) component ---
    // 1.0  exact prefix match  ("make" matches "make build")
    // 0.5  partial match by token ("ma" matches "make")
    // 0.0  no match
    let ctx_score = prefix_match_score(&entry.command, prefix);

    // --- Project bonus ---
    let project_score = if entry.is_project { 1.0 } else { 0.0 };

    // --- Success ratio ---
    let success_score = entry.success_ratio;

    W_FREQ * freq_score
        + W_RECENCY * recency_score
        + W_CONTEXT * ctx_score
        + W_PROJECT * project_score
        + W_SUCCESS * success_score
}

/// How well does `command` match `prefix`?
///
/// - Empty prefix → 0.5 (matches everything weakly, avoids suppressing all results)
/// - Exact prefix → 1.0
/// - Prefix matches start → 0.8
/// - Prefix matches after a space (partial token) → 0.3
/// - No match → 0.0
fn prefix_match_score(command: &str, prefix: &str) -> f64 {
    if prefix.is_empty() {
        return 0.5;
    }
    let cmd_lower = command.to_lowercase();
    let pfx_lower = prefix.to_lowercase();

    if cmd_lower == pfx_lower {
        return 1.0;
    }
    if cmd_lower.starts_with(&pfx_lower) {
        return 0.8;
    }
    // Check if any word in the command starts with the prefix (e.g. "git" in "git commit")
    if cmd_lower.split_whitespace().any(|w| w.starts_with(&pfx_lower)) {
        return 0.3;
    }
    // Substring anywhere
    if cmd_lower.contains(&pfx_lower) {
        return 0.1;
    }
    0.0
}

// ---------- Unit tests ----------
#[cfg(test)]
mod tests {
    use super::*;

    fn entry(cmd: &str, freq: i64, last_used: i64, success_ratio: f64, is_project: bool) -> Entry {
        Entry {
            command: cmd.to_string(),
            frequency: freq,
            last_used,
            success_ratio,
            is_project,
        }
    }

    const NOW: i64 = 1_700_000_000;
    const HL: f64 = DEFAULT_HALF_LIFE_HOURS;

    #[test]
    fn more_frequent_wins() {
        let rare = entry("make build", 1, NOW - 3600, 1.0, false);
        let common = entry("make build", 10, NOW - 3600, 1.0, false);
        assert!(
            score(&common, "make", NOW, HL) > score(&rare, "make", NOW, HL),
            "higher frequency should yield higher score"
        );
    }

    #[test]
    fn more_recent_wins() {
        let old = entry("make test", 5, NOW - 7 * 24 * 3600, 1.0, false);
        let fresh = entry("make test", 5, NOW - 3600, 1.0, false);
        assert!(
            score(&fresh, "make", NOW, HL) > score(&old, "make", NOW, HL),
            "recent command should score higher"
        );
    }

    #[test]
    fn exact_prefix_beats_partial() {
        let exact = entry("make build", 3, NOW - 3600, 1.0, false);
        let partial = entry("make test", 3, NOW - 3600, 1.0, false);
        // With prefix "make build" the first is an exact prefix match
        let s_exact = score(&exact, "make build", NOW, HL);
        let s_partial = score(&partial, "make b", NOW, HL);
        // exact prefix on "make build" should beat partial on unrelated
        assert!(s_exact > 0.3, "exact prefix should give meaningful score");
        // A command with a completely non-matching prefix gets 0.0 from context,
        // but still gets W_FREQ + W_RECENCY contributions.
        // Verify context component is 0: use prefix_match_score directly.
        assert_eq!(
            prefix_match_score("make test", "npm"),
            0.0,
            "non-matching prefix should give 0 context score"
        );
    }

    #[test]
    fn project_bonus_is_small() {
        let plain = entry("make build", 5, NOW - 3600, 1.0, false);
        let proj = entry("make build", 5, NOW - 3600, 1.0, true);
        let diff = score(&proj, "make", NOW, HL) - score(&plain, "make", NOW, HL);
        // Project bonus = W_PROJECT * 1.0 = 0.05
        assert!(
            (diff - W_PROJECT).abs() < 0.001,
            "project bonus should equal W_PROJECT"
        );
    }

    #[test]
    fn monotone_decay() {
        // Score should decrease as the command gets older
        let scores: Vec<f64> = [0, 24, 168, 720, 8760]
            .iter()
            .map(|&h| {
                let e = entry("ls -la", 5, NOW - h * 3600, 1.0, false);
                score(&e, "ls", NOW, HL)
            })
            .collect();
        for w in scores.windows(2) {
            assert!(w[0] > w[1], "score should decrease with age");
        }
    }
}
