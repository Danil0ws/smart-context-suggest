# Contributing to smart-context-suggest

Thank you for considering a contribution! This is an educational project — clarity and readability matter as much as correctness.

---

## Ways to contribute

- **Bug reports** — open an issue with the template below
- **Documentation** — typos, translations, new examples
- **New languages** — add a translation in `docs/<lang>/`
- **Score tuning** — propose different weights with benchmark data
- **Platform support** — WSL, FreeBSD, NixOS
- **New project context sources** — go.mod, pyproject.toml, CMakeLists.txt, etc.

---

## Development setup

```zsh
# Clone
git clone https://github.com/yourname/smart-context-suggest
cd smart-context-suggest

# Build
cargo build

# Run tests
cargo test
zsh tests/integration.zsh

# Test the plugin live (no OMZ needed)
SMART_SUGGEST_BIN="$PWD/target/debug/smart-suggest" \
  zsh -c 'source smart-context-suggest.plugin.zsh; smart-suggest stats'
```

---

## Code style

- **Rust:** `cargo fmt` before committing; `cargo clippy` must pass with no warnings
- **Zsh:** 2-space indent; every function must have a one-line comment explaining its purpose
- **Docs:** match the style of the existing docs in the target language

---

## Submitting a pull request

1. Fork the repo and create a branch: `git checkout -b feat/my-feature`
2. Make your changes; add/update tests if the logic changed
3. Run `cargo test && zsh tests/integration.zsh` — both must pass
4. Update the relevant `docs/` files if behaviour changed
5. Open a PR with a clear description of what and why

---

## Reporting a bug

Please include:
- OS and Zsh version (`zsh --version`)
- Oh My Zsh and plugin versions
- Steps to reproduce
- Output of `smart-suggest debug on` + the debug log

---

## Adding a translation

1. Copy `docs/en/` to `docs/<lang-code>/` (e.g. `docs/de/` for German)
2. Translate all `.md` files
3. Add a row to the language table in the root `README.md`
4. Open a PR — no Rust/Zsh knowledge needed

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
