#!/usr/bin/env zsh
# install.sh — Build the Rust backend and set up the plugin.
#
# Usage:
#   zsh install.sh              # build and install
#   zsh install.sh --uninstall  # remove from ~/.zshrc and delete binary

set -e

PLUGIN_DIR="${0:A:h}"
BIN_DIR="$PLUGIN_DIR/bin"

print "\n\033[1msmart-context-suggest installer\033[0m\n"

# ---------- Uninstall ----------

if [[ "$1" == "--uninstall" ]]; then
  print "Removing binary..."
  rm -f "$BIN_DIR/smart-suggest"
  print "Removing plugin line from ~/.zshrc (if present)..."
  sed -i.bak '/smart-context-suggest/d' ~/.zshrc 2>/dev/null || true
  print "\033[32mUninstalled.\033[0m"
  exit 0
fi

# ---------- Build ----------

# Check for Rust
if ! command -v cargo >/dev/null 2>&1; then
  print "\033[31mError: cargo not found. Install Rust from https://rustup.rs\033[0m"
  exit 1
fi

print "Building Rust backend (this takes ~30s first time)..."
(cd "$PLUGIN_DIR" && cargo build --release 2>&1)

mkdir -p "$BIN_DIR"
cp "$PLUGIN_DIR/target/release/smart-suggest" "$BIN_DIR/"
chmod +x "$BIN_DIR/smart-suggest"

print "\033[32m  Binary ready: $BIN_DIR/smart-suggest\033[0m"

# ---------- Configure .zshrc ----------

ZSHRC="$HOME/.zshrc"

# Check if plugin is already configured
if grep -q "smart-context-suggest" "$ZSHRC" 2>/dev/null; then
  print "\nPlugin already in $ZSHRC — skipping .zshrc update."
else
  print "\nAdding plugin to $ZSHRC ..."
  cat >> "$ZSHRC" << 'ZSHRC_BLOCK'

# smart-context-suggest: context-aware shell autocomplete
# Configure before plugins=(...)
# ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
# SMART_SUGGEST_MENU_KEY="^F"   # Ctrl+F for Fig-style menu
# SMART_SUGGEST_HALF_LIFE_HOURS=168
# SMART_SUGGEST_STALE_DAYS=90
ZSHRC_BLOCK

  # Check if plugins array exists and add the plugin
  if grep -q "^plugins=(" "$ZSHRC"; then
    # Insert smart-context-suggest into the plugins array
    sed -i.bak 's/^plugins=(/plugins=(smart-context-suggest /' "$ZSHRC"
    print "\033[32m  Added to plugins array in $ZSHRC\033[0m"
  else
    print "\033[33m  Note: Add 'smart-context-suggest' to your plugins=(...) array in $ZSHRC\033[0m"
  fi
fi

# ---------- Verify fzf ----------

if ! command -v fzf >/dev/null 2>&1; then
  print "\n\033[33mWarning: fzf not found.\033[0m"
  print "The interactive menu (Ctrl+F) requires fzf."
  print "Install: brew install fzf  or  https://github.com/junegunn/fzf"
fi

# ---------- Done ----------

print "\n\033[1mInstallation complete!\033[0m"
print ""
print "Next steps:"
print "  1. Add to ~/.zshrc (before OMZ loading):"
print "       ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)"
print ""
print "  2. Reload your shell:"
print "       exec zsh"
print ""
print "  3. Start typing — ghost-text appears automatically."
print "     Press Ctrl+F for the interactive menu."
print ""
print "  4. Run the tests:"
print "       zsh tests/integration.zsh"
print ""
print "  Type \`smart-suggest help\` for all commands."
