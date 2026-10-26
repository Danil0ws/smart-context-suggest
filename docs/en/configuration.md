# Configuration

All settings are environment variables set in `~/.zshrc` **before** `source $ZSH/oh-my-zsh.sh`.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZSH_AUTOSUGGEST_STRATEGY` | `(smart_context history)` | Suggestion chain order |
| `SMART_SUGGEST_MENU_KEY` | `^F` | Key for the fzf interactive menu |
| `SMART_SUGGEST_TOGGLE_KEY` | `^\` | Key to pause/resume ghost text |
| `SMART_SUGGEST_CLEAR_KEY` | `^L` | Key for smart clear screen (set `""` to disable) |
| `SMART_SUGGEST_CLEAR_SEPARATOR` | `1` | Show time/dir/branch bar after clear (`0` = plain clear) |
| `SMART_SUGGEST_MOUSE` | `1` | Enable click-to-cursor mouse support (`0` = disable) |
| `SMART_SUGGEST_HALF_LIFE_HOURS` | `168` (7 days) | Recency decay half-life |
| `SMART_SUGGEST_STALE_DAYS` | `90` | Days before weak entries are deleted |
| `SMART_SUGGEST_MATURE_RUNS` | `2` | Min successful runs before suggesting |
| `SMART_SUGGEST_MENU_LIMIT` | `50` | Max items in the fzf menu |
| `SMART_SUGGEST_IGNORE_SPACE` | `1` | Skip commands prefixed with space |
| `SMART_SUGGEST_DEBUG` | `0` | Write debug log (`1` = on) |
| `SMART_SUGGEST_DATA_DIR` | `~/.local/share/smart-context-suggest` | Database location |
| `SMART_SUGGEST_BIN` | `<plugin>/bin/smart-suggest` | Path to the Rust binary |

## Examples

```zsh
# More aggressive decay (3 days instead of 7)
SMART_SUGGEST_HALF_LIFE_HOURS=72

# Keep entries longer (6 months)
SMART_SUGGEST_STALE_DAYS=180

# Change menu key to Alt+F
SMART_SUGGEST_MENU_KEY="^[f"

# Change pause key to Ctrl+]
SMART_SUGGEST_TOGGLE_KEY="^]"

# Store database on a fast SSD
SMART_SUGGEST_DATA_DIR="/fast-ssd/.smart-suggest"

# Enable debug log permanently
SMART_SUGGEST_DEBUG=1
```

## Tuning Score Weights

Edit `src/score.rs` and rebuild:

```rust
pub const W_FREQ: f64    = 0.35;   // frequency weight
pub const W_RECENCY: f64 = 0.25;   // recency weight
pub const W_CONTEXT: f64 = 0.30;   // prefix-match weight
pub const W_PROJECT: f64 = 0.05;   // project-target bonus
pub const W_SUCCESS: f64 = 0.05;   // success-rate bonus
```

```zsh
cargo build --release && cp target/release/smart-suggest bin/
```
