# smart-context-suggest — English Documentation

> Context-aware shell autocomplete for Oh My Zsh. Learns your commands per directory.  
> No AI · No cloud · No tracking · Pure algorithms + SQLite.

---

## Table of Contents

- [How it works](#how-it-works)
- [Installation](installation.md)
- [Configuration](configuration.md)
- [Key bindings](#key-bindings)
- [Commands](commands.md)
- [Score formula](#score-formula)
- [Architecture](#architecture)
- [FAQ](#faq)

---

## How it works

Every command you run is silently recorded in a local SQLite database, keyed by the **directory** you were in. The next time you start typing the same command in the same directory, it appears as ghost text — a faded completion you accept with `→`.

```
[you type]  → strategy: project_context → memory (SQLite) → history
[Enter]     → preexec hook → record command (background, < 2 ms)
[done]      → precmd hook  → record success/failure (background)
[daily]     → decay pass   → remove stale/weak entries
```

### Why per-directory?

`make build` in `~/projects/api` is unrelated to `make build` in `~/projects/docs`. Scoping to directories prevents cross-project noise — the same insight behind [zoxide](https://github.com/ajeetdsouza/zoxide).

### The Fig-style menu

Press `Ctrl+F` at any point to open a scored interactive picker showing:

| Source | Color | Description |
|--------|-------|-------------|
| memory | green | Your past commands here, ranked by score |
| project | yellow | Makefile targets, npm scripts, cargo commands |
| dir | magenta | Real directory paths for `cd` commands |
| path | cyan | Executables on `$PATH` |
| history | gray | Shell history |

### Fuzzy `cd`

Typing `cd dev/mycorp` when the real path is `~/Dev/MyCorp` (different case, different prefix) — the plugin finds it via:
1. Exact path test
2. Case-insensitive glob in the same parent
3. Search across `~/Dev`, `~/Projects`, `~/src`, `~`

---

## Key Bindings

| Key | Action |
|-----|--------|
| `→` or `End` | Accept ghost-text suggestion |
| `Ctrl+F` | Open Fig-style interactive menu |
| `Ctrl+\` | **Pause / resume** ghost text |
| `Ctrl+E` | Dismiss current suggestion (built into zsh-autosuggestions) |

---

## Score Formula

```
score = 0.35 × log(1 + frequency)
      + 0.25 × exp(−age_hours × ln2 / half_life_hours)
      + 0.30 × prefix_match_score          # 1.0 exact, 0.8 starts-with, 0.3 word, 0.0 none
      + 0.05 × is_project                  # Makefile/package.json target
      + 0.05 × success_ratio               # fraction of runs that exited 0
```

**Why `log(1 + freq)`?** Compresses the scale — the gap between 1 and 2 runs matters more than 100 vs 101. A single dominant command can't crowd out everything else.

**Why exponential decay?** Models the [Ebbinghaus forgetting curve](https://en.wikipedia.org/wiki/Forgetting_curve). A command used 8 days ago is naturally de-emphasized vs one used today. Default half-life: **7 days**.

---

## Architecture

```
plugin root/
├── smart-context-suggest.plugin.zsh   # Zsh: hooks, strategy, fzf menu, widgets
├── bin/smart-suggest                  # Rust binary (backend)
├── src/
│   ├── main.rs    CLI subcommands
│   ├── db.rs      SQLite operations
│   └── score.rs   Scoring formula + unit tests
├── docs/
│   ├── en/        English docs (this)
│   ├── pt-br/     Portuguese docs
│   ├── ru/        Russian docs
│   └── zh/        Chinese docs
├── tests/
│   └── integration.zsh
└── install.sh

Data:  ~/.local/share/smart-context-suggest/memory.db
Cache: ~/.cache/smart-context-suggest/debug.log  (when debug=on)
```

The Zsh/Rust split is intentional: Zsh owns shell integration (hooks, widgets, key bindings); Rust owns data (SQLite, scoring). The binary is invoked via subshell; budget: < 2 ms record/mark-success, < 5 ms query.

---

## FAQ

**Does it send data anywhere?**  
No. Everything stays in `~/.local/share/smart-context-suggest/`. No network calls, ever.

**Does it slow down my shell?**  
Record and mark-success run in background (`&! >/dev/null`). Query targets < 5 ms. The only synchronous part is the strategy function — it returns immediately on cache hit (project context) or after one SQLite read.

**Can I use it without zsh-autosuggestions?**  
The ghost text requires zsh-autosuggestions. The `Ctrl+F` fzf menu and `smart-suggest` commands work standalone.

**Can I use it with zoxide?**  
Yes — add `z` to the cd-aware verbs. The plugin already handles `cd`, `pushd`, and `z` for path resolution.

**How do I see what it learned?**  
```zsh
smart-suggest list              # current directory
smart-suggest list --dir ~/api  # specific directory
smart-suggest stats             # global overview
smart-suggest export | head     # raw JSON
```

**How do I reset everything?**  
```zsh
smart-suggest clear --all
```
