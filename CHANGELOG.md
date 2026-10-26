# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- Fig-style interactive fzf menu (`Ctrl+F`) with memory, project, dir, path, and history sources
- Smart `cd` path resolution: case-insensitive glob + root directory search
- Pause/resume toggle (`Ctrl+\`) to silence ghost text temporarily
- Multilingual documentation: EN, PT-BR, RU, ZH
- Open source project structure: CONTRIBUTING.md, LICENSE, CHANGELOG, GitHub templates

### Fixed
- p10k instant prompt compatibility: all background hooks now redirect to `/dev/null`
- `ZSH_AUTOSUGGEST_STRATEGY` must be set before `source $ZSH/oh-my-zsh.sh`

---

## [0.1.0] — 2026-10-25

### Added
- Initial release
- Rust backend with SQLite (WAL mode): record, mark-success, query, decay, list, stats, clear, export, debug
- Zsh plugin: preexec/precmd hooks, smart_context autosuggest strategy
- Project context: Makefile targets, package.json scripts, Cargo.toml subcommands
- Ebbinghaus-inspired score formula with frequency, recency, prefix-match, project, and success weights
- Daily decay: remove stale weak entries, reduce frequency of aging entries
- 9 Rust unit tests (score monotonicity, DB isolation, decay)
- 20 Zsh integration tests
