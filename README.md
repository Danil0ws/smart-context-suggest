# smart-context-suggest

> Fig-inspired, context-aware autocomplete for Oh My Zsh — no AI, no cloud, no tracking.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-1.70%2B-orange.svg)](https://www.rust-lang.org)
[![Shell](https://img.shields.io/badge/shell-zsh-green.svg)](https://www.zsh.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue.svg)](#)

Ghost-text completions that learn from **your commands, in your directories** — scored by frequency, recency, and context. A Rust backend with SQLite keeps every suggestion under 5 ms.

```
~/projects/api ❯ make b▌uild test           ← press → to accept

~/projects/api ❯ cd cl                       ← press Ctrl+F
╭─────────────────────────────────────────╮
│ ❯ cd cl                                 │
├─────────────────────────────────────────┤
│ cd ~/Dev/cleanyourtv        [dir]        │
│ cd ~/Dev/cli-tools          [dir]        │
│ make clean          0.8231  [memory]     │
│ cargo clippy                [project]    │
╰─────────────────────────────────────────╯
```

---

## 📖 Documentation

| Language | Link |
|----------|------|
| 🇺🇸 English | **[docs/en/README.md](docs/en/README.md)** (this page) |
| 🇧🇷 Português | [docs/pt-br/README.md](docs/pt-br/README.md) |
| 🇷🇺 Русский | [docs/ru/README.md](docs/ru/README.md) |
| 🇨🇳 中文 | [docs/zh/README.md](docs/zh/README.md) |

---

## ⚡ Quick Install

```zsh
git clone https://github.com/Danil0ws/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest

cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh
```

Add to `~/.zshrc` **before** `source $ZSH/oh-my-zsh.sh`:

```zsh
plugins=(... smart-context-suggest)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
```

Reload: `exec zsh`

→ Full guide: [docs/en/installation.md](docs/en/installation.md)

---

## ✨ Features

- **Ghost text** — inline suggestions as you type, accepted with `→`
- **Directory-scoped memory** — `make build` in `~/api` never bleeds into `~/frontend`
- **Fuzzy `cd`** — `cd dev/mycorp` finds `~/Dev/MyCorp` even with wrong case
- **Fig-style menu** — `Ctrl+F` opens a scored, multi-source picker (memory + project + PATH + history)
- **Project context** — reads Makefile targets, `package.json` scripts, `Cargo.toml` subcommands
- **Pause toggle** — `Ctrl+\` silences suggestions when you need to think
- **Scored decay** — Ebbinghaus-inspired forgetting curve keeps memory fresh
- **Zero dependencies** — no jq, no node, no Python required

---

## 🔑 Key Bindings

| Key | Action |
|-----|--------|
| `→` or `End` | Accept ghost-text suggestion |
| `Ctrl+F` | Open Fig-style interactive menu |
| `Ctrl+\` | Pause / resume suggestions |
| `Ctrl+E` | Dismiss current suggestion |
| `Ctrl+L` | Smart clear (separator with time/dir/branch) |
| Click | Move cursor to clicked position |

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## 📄 License

[MIT](LICENSE) — © 2026 Danilo Rodrigues
