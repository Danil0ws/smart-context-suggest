# Installation Guide

## Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| Zsh | 5.1+ | `zsh --version` |
| Oh My Zsh | any | [ohmyz.sh](https://ohmyz.sh) |
| zsh-autosuggestions | any | For ghost text |
| Rust / cargo | 1.70+ | For building the backend |
| fzf | any | Optional — for the interactive menu |

---

## Step 1 — Install zsh-autosuggestions (if not already)

```zsh
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

---

## Step 2 — Install Rust (if not already)

```zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

Verify: `cargo --version`

---

## Step 3 — Clone the plugin

```zsh
git clone https://github.com/Danil0ws/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

---

## Step 4 — Build the backend

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh
```

This compiles the Rust backend (~30 s first time) and copies the binary to `bin/smart-suggest`.

---

## Step 5 — Configure ~/.zshrc

Add these lines **before** `source $ZSH/oh-my-zsh.sh`:

```zsh
# 1. Add the plugin to the list
plugins=(zsh-autosuggestions smart-context-suggest git)

# 2. Set the suggestion strategy (must be before source line)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
```

**Verify ordering** — your `.zshrc` should look like:

```zsh
# ... (p10k instant prompt, if you use it, stays at the very top)

plugins=(zsh-autosuggestions smart-context-suggest git)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)

source $ZSH/oh-my-zsh.sh   # ← strategy must be set BEFORE this line

# ... rest of your config
```

---

## Step 6 — Reload

```zsh
exec zsh
```

---

## Step 7 — Verify

```zsh
# Check the binary works
smart-suggest stats

# Check the strategy is registered
echo $ZSH_AUTOSUGGEST_STRATEGY
# → smart_context history

# Test a suggestion: type a command you've used before
# Ghost text should appear — press → to accept
```

---

## Optional: Install fzf (for Ctrl+F menu)

```zsh
# macOS
brew install fzf

# Linux (Debian/Ubuntu)
sudo apt install fzf

# Any platform via git
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install
```

---

## Updating

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
git pull
zsh install.sh   # rebuilds the binary if src/ changed
exec zsh
```

---

## Uninstalling

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh --uninstall

# Remove from plugins=() in ~/.zshrc
# Remove ZSH_AUTOSUGGEST_STRATEGY line
exec zsh
```

---

## Troubleshooting

### `[oh-my-zsh] plugin 'smart-context-suggest' not found`

The plugin directory name must exactly match the name in `plugins=(...)`. Check:

```zsh
ls ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/
# should show: smart-context-suggest
```

If you cloned to a different path, symlink it:

```zsh
ln -sf /path/to/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

### `command not found: _zsh_autosuggest_strategy_smart_context`

`ZSH_AUTOSUGGEST_STRATEGY` is set **after** `source $ZSH/oh-my-zsh.sh`. Move it before.

### Powerlevel10k instant prompt warning

All background hooks already redirect to `/dev/null`. If you still see the warning, check that nothing else in your `.zshrc` prints to stdout between the p10k preamble and the `source` line.

### Ghost text not appearing

1. Confirm `zsh-autosuggestions` is in your `plugins=()` list
2. Confirm `ZSH_AUTOSUGGEST_STRATEGY` includes `smart_context`
3. Type a command you've run before — on first use, memory is empty; ghost text comes from history
4. Run `smart-suggest debug on` and check `~/.cache/smart-context-suggest/debug.log`
