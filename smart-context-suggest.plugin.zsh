# smart-context-suggest.plugin.zsh
#
# Oh My Zsh plugin: context-aware ghost-text autocomplete + Fig-style interactive menu.
#
# Architecture:
#   ┌─ [typing] ──────────────────────────────────────────────────────────────┐
#   │  autosuggest strategy → project_context (sync, cached)                  │
#   │                       → rust query → SQLite → score formula             │
#   │                       → history fallback                                │
#   └─────────────────────────────────────────────────────────────────────────┘
#   ┌─ [Tab / Ctrl+F] ────────────────────────────────────────────────────────┐
#   │  fzf interactive menu with all available completions + memory           │
#   └─────────────────────────────────────────────────────────────────────────┘
#   ┌─ [Enter] ───────────────────────────────────────────────────────────────┐
#   │  preexec → record (background) → SQLite                                 │
#   │  precmd  → mark-success → SQLite                                        │
#   └─────────────────────────────────────────────────────────────────────────┘

# ---------- Configuration (override in .zshrc before sourcing OMZ) ----------

: ${SMART_SUGGEST_DATA_DIR:="${XDG_DATA_HOME:-$HOME/.local/share}/smart-context-suggest"}
: ${SMART_SUGGEST_BIN:="${0:A:h}/bin/smart-suggest"}
: ${SMART_SUGGEST_DEBUG:=0}
: ${SMART_SUGGEST_STALE_DAYS:=90}
: ${SMART_SUGGEST_HALF_LIFE_HOURS:=168}
# Minimum successful runs before a command is considered "mature" for suggestions
: ${SMART_SUGGEST_MATURE_RUNS:=2}
# Key to open the Fig-style interactive menu (default: Ctrl+F)
: ${SMART_SUGGEST_MENU_KEY:="^F"}
# Max results shown in fzf menu
: ${SMART_SUGGEST_MENU_LIMIT:=50}
# When 1, skip recording commands that start with a space (like HIST_IGNORE_SPACE)
: ${SMART_SUGGEST_IGNORE_SPACE:=1}
# Rebuild the system command index after this many days of staleness (0 = never auto-rebuild)
: ${SMART_SUGGEST_INDEX_DAYS:=7}
# Max binaries to deep-index via --help parsing (the rest get registered as binary-only)
: ${SMART_SUGGEST_INDEX_DEEP:=80}

# ---------- Sanity check ----------

_smart_suggest_available() {
  [[ -x "$SMART_SUGGEST_BIN" ]]
}

if ! _smart_suggest_available; then
  # Degrade gracefully: just use history strategy
  if [[ $SMART_SUGGEST_DEBUG -eq 1 ]]; then
    echo "smart-context-suggest: binary not found at $SMART_SUGGEST_BIN" >&2
  fi
  return 0
fi

# ---------- Internal state ----------

# Last command captured by preexec (shared with precmd)
typeset -g _smart_suggest_last_cmd=""
typeset -g _smart_suggest_last_dir=""
typeset -g _smart_suggest_last_ts=0

# Project context cache: avoid re-reading Makefile on every keystroke.
# Cache key = "$PWD:$mtime_of_makefile_or_packagejson"
typeset -g _smart_suggest_proj_cache_key=""
typeset -gA _smart_suggest_proj_cache=()  # prefix → suggestion

# Daily decay: record last decay date
typeset -g _smart_suggest_decay_date=""

# Weekly command index: record last index date
typeset -g _smart_suggest_index_date=""

# Pause flag: when 1, the strategy returns nothing (no ghost text)
typeset -g _smart_suggest_paused=0

# ---------- Debug helpers ----------

_smart_suggest_log() {
  [[ $SMART_SUGGEST_DEBUG -eq 0 ]] && return
  local log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/smart-context-suggest"
  mkdir -p "$log_dir"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$log_dir/debug.log"
}

# ---------- Hook: preexec — fires before each command executes ----------
#
# Captures the command and directory, then records it in the background
# so the terminal doesn't stall.

_smart_suggest_preexec() {
  local cmd="$1"
  local dir="$PWD"
  local ts=$(date +%s)

  # Skip empty or space-prefixed commands
  [[ -z "${cmd// /}" ]] && return
  [[ $SMART_SUGGEST_IGNORE_SPACE -eq 1 && "$cmd" == " "* ]] && return

  _smart_suggest_last_cmd="$cmd"
  _smart_suggest_last_dir="$dir"
  _smart_suggest_last_ts="$ts"

  # Detect if this command references a project artifact
  local is_project=0
  _smart_suggest_is_project_cmd "$cmd" "$dir" && is_project=1

  # Record in the background (&! = fire-and-forget, no zombie)
  # >/dev/null 2>&1 prevents any output from leaking into the terminal
  # (important for p10k instant prompt compatibility)
  "$SMART_SUGGEST_BIN" record \
    --dir "$dir" \
    --cmd "$cmd" \
    --ts "$ts" \
    $([ $is_project -eq 1 ] && echo "--is-project") \
    >/dev/null 2>&1 &!

  _smart_suggest_log "preexec cmd=$cmd dir=$dir project=$is_project"
}

# Returns 0 (true) if the command references a project artifact.
# Used to set the is_project flag.
_smart_suggest_is_project_cmd() {
  local cmd="$1" dir="$2"
  # make <target> where Makefile exists
  if [[ "$cmd" == make* && -f "$dir/Makefile" ]]; then return 0; fi
  # npm/pnpm/yarn run <script>
  if [[ "$cmd" == (npm|pnpm|yarn)" run"* && -f "$dir/package.json" ]]; then return 0; fi
  # cargo <subcommand>
  if [[ "$cmd" == cargo* && -f "$dir/Cargo.toml" ]]; then return 0; fi
  # Local executable
  if [[ "$cmd" == "./"* ]]; then return 0; fi
  return 1
}

# ---------- Hook: precmd — fires after each command returns ----------
#
# Records whether the last command succeeded (exit code 0).
# Also triggers daily decay.

_smart_suggest_precmd() {
  local exit_code=$?

  # Nothing to record if we didn't capture a command
  [[ -z "$_smart_suggest_last_cmd" ]] && return

  local ok=0
  [[ $exit_code -eq 0 ]] && ok=1

  # Mark success in background
  "$SMART_SUGGEST_BIN" mark-success \
    --dir "$_smart_suggest_last_dir" \
    --cmd "$_smart_suggest_last_cmd" \
    --ok "$ok" \
    >/dev/null 2>&1 &!

  _smart_suggest_log "precmd exit=$exit_code cmd=$_smart_suggest_last_cmd"

  # Daily decay (runs at most once per calendar day)
  local today=$(date +%Y-%m-%d)
  if [[ "$_smart_suggest_decay_date" != "$today" ]]; then
    _smart_suggest_decay_date="$today"
    "$SMART_SUGGEST_BIN" decay \
      --stale-days "$SMART_SUGGEST_STALE_DAYS" \
      >/dev/null 2>&1 &!
    _smart_suggest_log "decay triggered for $today"
  fi

  # Weekly command index (runs at most once per INDEX_DAYS days)
  if [[ $SMART_SUGGEST_INDEX_DAYS -gt 0 ]]; then
    local index_stamp_file="${SMART_SUGGEST_DATA_DIR}/.last_index"
    local now_epoch=$(date +%s)
    local last_index=0
    [[ -f "$index_stamp_file" ]] && last_index=$(< "$index_stamp_file")
    local age_days=$(( (now_epoch - last_index) / 86400 ))
    if [[ $age_days -ge $SMART_SUGGEST_INDEX_DAYS ]]; then
      echo "$now_epoch" > "$index_stamp_file"
      _smart_suggest_index_path >/dev/null 2>&1 &!
      _smart_suggest_log "command index rebuild triggered"
    fi
  fi
}

# Register hooks (append to existing hooks if any)
autoload -Uz add-zsh-hook
add-zsh-hook preexec _smart_suggest_preexec
add-zsh-hook precmd  _smart_suggest_precmd

# ---------- Project context: read Makefile/package.json targets ----------
#
# Returns the best completion for `prefix` based on project file targets.
# Results are cached per-directory until the project file changes.

_smart_suggest_project_context() {
  local prefix="$1"
  local dir="$PWD"

  # Build cache key from dir + mtime of project file
  local proj_file=""
  local verb="${prefix%% *}"  # first word of prefix

  case "$verb" in
    make)         [[ -f "$dir/Makefile" ]]      && proj_file="$dir/Makefile" ;;
    npm)          [[ -f "$dir/package.json" ]]   && proj_file="$dir/package.json" ;;
    pnpm|yarn)    [[ -f "$dir/package.json" ]]   && proj_file="$dir/package.json" ;;
    cargo)        [[ -f "$dir/Cargo.toml" ]]     && proj_file="$dir/Cargo.toml" ;;
    ./*|../*)     proj_file="$dir" ;;  # local executables
  esac

  [[ -z "$proj_file" ]] && return 1

  local mtime
  mtime=$(stat -c %Y "$proj_file" 2>/dev/null || stat -f %m "$proj_file" 2>/dev/null)
  local cache_key="${dir}:${proj_file}:${mtime}"

  # Rebuild cache if stale
  if [[ "$_smart_suggest_proj_cache_key" != "$cache_key" ]]; then
    _smart_suggest_proj_cache_key="$cache_key"
    _smart_suggest_proj_cache=()
    _smart_suggest_populate_proj_cache "$verb" "$proj_file" "$dir"
  fi

  # Look up the prefix in cache
  local best=""
  local best_cmd=""
  for cmd in "${(@k)_smart_suggest_proj_cache}"; do
    [[ "$cmd" == "$prefix"* ]] || continue
    if [[ -z "$best_cmd" ]] || [[ ${#cmd} -lt ${#best_cmd} ]]; then
      best_cmd="$cmd"
    fi
  done
  [[ -n "$best_cmd" ]] && echo "$best_cmd"
}

# Populate the project context cache for the current directory.
_smart_suggest_populate_proj_cache() {
  local verb="$1" proj_file="$2" dir="$3"

  case "$verb" in
    make)
      # Extract targets from Makefile (lines like "target: ...")
      while IFS= read -r line; do
        local target="${line%%:*}"
        [[ "$target" =~ ^[a-zA-Z0-9_.-]+$ ]] || continue
        _smart_suggest_proj_cache["make $target"]=1
      done < <(grep -E '^[a-zA-Z0-9_.-]+:' "$proj_file" 2>/dev/null | head -50)
      ;;
    npm|pnpm|yarn)
      # Extract scripts from package.json (requires only grep/sed, no jq)
      local prefix_cmd="$verb run"
      [[ "$verb" == "npm" ]] && prefix_cmd="npm run"
      while IFS= read -r script; do
        [[ -n "$script" ]] && _smart_suggest_proj_cache["$prefix_cmd $script"]=1
      done < <(
        grep -A1 '"scripts"' "$proj_file" 2>/dev/null |
        grep '"[a-zA-Z0-9:_-]*"\s*:' |
        sed 's/.*"\([a-zA-Z0-9:_-]*\)".*/\1/' |
        head -50
      )
      ;;
    cargo)
      # Common cargo subcommands (static list, always available)
      for sub in build test run check clippy fmt doc clean bench publish; do
        _smart_suggest_proj_cache["cargo $sub"]=1
      done
      ;;
    ./*|../*)
      # List executables in the current directory
      for f in "$dir"/./*; do
        [[ -x "$f" && -f "$f" ]] && _smart_suggest_proj_cache["./${f##*/}"]=1
      done
      ;;
  esac
}

# ---------- Autosuggest strategy: the core of ghost-text ----------
#
# zsh-autosuggestions calls this function with the current buffer content.
# It must set `$suggestion` to the completion text to display.
#
# Priority:
#   1. Project context (Makefile targets, npm scripts, etc.)
#   2. Memory from SQLite (context-aware, scored)
#   3. Falls through to history (handled by ZSH_AUTOSUGGEST_STRATEGY array)

_zsh_autosuggest_strategy_smart_context() {
  local prefix="$1"
  local suggestion=""

  # Skip very short prefixes (1 char) to avoid noise
  [[ ${#prefix} -lt 2 ]] && return

  # Paused: user pressed the skip key — return nothing until toggled back
  [[ $_smart_suggest_paused -eq 1 ]] && return

  # 0. cd path resolution — must run before everything else.
  #    Handles: cd <partial-path>, cd ~/<partial>, pushd, z (zoxide)
  if [[ "$prefix" == (cd|pushd|z)" "* ]]; then
    suggestion=$(_smart_suggest_cd_path "$prefix" 2>/dev/null)
    if [[ -n "$suggestion" ]]; then
      typeset -g suggestion="$suggestion"
      _smart_suggest_log "autosuggest source=cd_path prefix=$prefix suggestion=$suggestion"
      return
    fi
  fi

  # 1. Project context (synchronous, cached — fast enough for keystrokes)
  suggestion=$(_smart_suggest_project_context "$prefix" 2>/dev/null)
  if [[ -n "$suggestion" ]]; then
    typeset -g suggestion="$suggestion"
    _smart_suggest_log "autosuggest source=project prefix=$prefix suggestion=$suggestion"
    return
  fi

  # 2. Memory backend (Rust/SQLite)
  suggestion=$(
    "$SMART_SUGGEST_BIN" query \
      --dir "$PWD" \
      --prefix "$prefix" \
      --limit 1 \
      --half-life "$SMART_SUGGEST_HALF_LIFE_HOURS" \
      2>/dev/null | head -1
  )
  if [[ -n "$suggestion" ]]; then
    typeset -g suggestion="$suggestion"
    _smart_suggest_log "autosuggest source=memory prefix=$prefix suggestion=$suggestion"
    return
  fi

  # 3. No suggestion — falls through to next strategy in the array
  _smart_suggest_log "autosuggest source=none prefix=$prefix"
}

# ---------- cd path resolver ----------
#
# Given a prefix like "cd dev/cleanyourtv", tries to find a real path:
#   1. Exact relative or absolute match (fast)
#   2. Case-insensitive match in the same parent directory
#   3. Search common root dirs (~/Dev, ~/Projects, ~/src, ~) one level deep
#   4. Returns nothing if no match — never suggests a non-existent path

_smart_suggest_cd_path() {
  local full_prefix="$1"
  local verb="${full_prefix%% *}"          # "cd"
  local raw="${full_prefix#"$verb "}"      # everything after "cd "

  # Expand ~ manually so glob tests work
  local expanded="${raw/#\~/$HOME}"

  # 1. Exact path exists → suggest as-is (already valid, just complete it)
  if [[ -d "$expanded" ]]; then
    echo "$full_prefix"
    return
  fi

  # 2. Direct glob in current dir or with given prefix path
  #    e.g. "cd dev/clean*" relative to $PWD
  local parent="${expanded:h}"   # dirname
  local base="${expanded:t}"     # basename

  # Resolve parent: if relative, prepend $PWD
  local abs_parent
  if [[ "$parent" == /* ]]; then
    abs_parent="$parent"
  elif [[ "$parent" == "." || -z "$parent" ]]; then
    abs_parent="$PWD"
  else
    abs_parent="$PWD/$parent"
  fi

  if [[ -d "$abs_parent" ]]; then
    # Case-insensitive glob match for the base name
    local match
    match=$(
      setopt nullglob nocaseglob 2>/dev/null
      local -a hits=("$abs_parent"/${~base}*(N/) "$abs_parent"/${~base}*(N))
      # Also try prefix match: base*
      [[ ${#hits[@]} -eq 0 ]] && hits=("$abs_parent"/${base}*(N/) "$abs_parent"/${base}*(N))
      [[ ${#hits[@]} -eq 0 ]] && {
        # Case-insensitive prefix: lower the base and glob
        hits=("${abs_parent}"/${base[1]}*(N/))
      }
      [[ ${#hits[@]} -gt 0 ]] && echo "${hits[1]}"
    )
    if [[ -n "$match" ]]; then
      # Reconstruct suggestion: keep original verb, format path nicely
      local nice
      nice="${match/#$HOME/~}"
      # If the original used a relative path, try to keep it relative
      if [[ "$raw" != /* && "$raw" != "~"* ]]; then
        local rel="${match#$PWD/}"
        [[ "$rel" != "$match" ]] && nice="$rel"
      fi
      echo "$verb $nice"
      return
    fi
  fi

  # 3. Search common root directories one level deep
  #    Useful when user types "cd dev/cleanyourtv" from ~ and the real path
  #    is ~/Dev/cleanyourtv (different case) or ~/projects/cleanyourtv
  local search_roots=("$HOME/Dev" "$HOME/dev" "$HOME/Projects" "$HOME/projects"
                      "$HOME/src" "$HOME/code" "$HOME/workspace" "$HOME")

  # Extract just the final directory name the user seems to want
  local target_name="${expanded:t}"
  [[ -z "$target_name" ]] && return

  for root in $search_roots; do
    [[ -d "$root" ]] || continue
    local found
    found=$(
      # Case-insensitive match for target_name anywhere under root (1 level)
      setopt nullglob nocaseglob 2>/dev/null
      local -a hits=("$root"/${target_name}(N/) "$root"/${target_name}*(N/))
      [[ ${#hits[@]} -gt 0 ]] && echo "${hits[1]}"
    )
    if [[ -n "$found" ]]; then
      local nice="${found/#$HOME/~}"
      echo "$verb $nice"
      return
    fi
  done
}

# List directory entries for the fzf menu when the command is cd/pushd/z.
# Shows: subdirs of $PWD, recent cd targets from memory, and common roots.
_smart_suggest_cd_menu_entries() {
  local full_prefix="$1"
  local verb="${full_prefix%% *}"
  local raw="${full_prefix#"$verb"}"
  raw="${raw# }"  # strip leading space

  # Subdirs of current directory (always shown)
  setopt nullglob 2>/dev/null
  local -a local_dirs=("$PWD"/*(N/))
  for d in $local_dirs; do
    local nice="${d/#$HOME/~}"
    echo "$verb $nice"
  done

  # Subdirs of parent (useful for sibling navigation: cd ../<tab>)
  if [[ "$raw" == "../"* || "$raw" == ".." ]]; then
    local parent="${PWD:h}"
    local -a sibling_dirs=("$parent"/*(N/))
    for d in $sibling_dirs; do
      local nice="${d/#$HOME/~}"
      echo "$verb $nice"
    done
  fi

  # Recently visited directories from memory (cd commands that succeeded)
  "$SMART_SUGGEST_BIN" query \
    --dir "$PWD" \
    --prefix "$verb " \
    --limit 20 \
    --half-life "$SMART_SUGGEST_HALF_LIFE_HOURS" \
    2>/dev/null

  # Common project roots
  local search_roots=("$HOME/Dev" "$HOME/dev" "$HOME/Projects" "$HOME/projects"
                      "$HOME/src" "$HOME/code" "$HOME/workspace")
  for root in $search_roots; do
    [[ -d "$root" ]] || continue
    local -a root_dirs=("$root"/*(N/))
    for d in $root_dirs; do
      local nice="${d/#$HOME/~}"
      echo "$verb $nice"
    done
  done
}

# Register strategy (if zsh-autosuggestions is loaded)
# Add to .zshrc: ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
if (( ${+ZSH_AUTOSUGGEST_STRATEGY} )); then
  # Prepend smart_context if not already present
  if [[ ! " ${ZSH_AUTOSUGGEST_STRATEGY[@]} " =~ " smart_context " ]]; then
    ZSH_AUTOSUGGEST_STRATEGY=(smart_context $ZSH_AUTOSUGGEST_STRATEGY)
  fi
fi

# ---------- System command indexer ----------
#
# Scans every binary in $PATH, extracts subcommands and flags via:
#   1. Zsh completion specs (_git, _docker, _kubectl, etc.) — richest source
#   2. `cmd --help` / `cmd help` output parsing — portable fallback
#   3. Registers the binary itself as kind=binary for any unindexed tools
#
# Runs in background (triggered weekly from precmd).
# User can also run manually: smart-suggest index-path

_smart_suggest_index_path() {
  local bin ts
  ts=$(date +%s)
  local deep_count=0

  # Priority tools: always deep-index these (subcommands + flags)
  local -a priority_tools=(
    git docker docker-compose kubectl helm cargo npm pnpm yarn
    python3 python pip pip3 node npx make gradle mvn go
    aws gcloud az terraform ansible ssh curl jq gh
  )

  # Index priority tools first (via --help parsing)
  for bin in $priority_tools; do
    command -v "$bin" >/dev/null 2>&1 || continue
    _smart_suggest_index_binary "$bin" "$ts"
    deep_count=$(( deep_count + 1 ))
  done

  # Register all other $PATH binaries as kind=binary (no subcommand extraction)
  # This gives them at least presence in the index for prefix matching
  local -a path_bins
  path_bins=(${(f)"$(whence -pm '*' 2>/dev/null | awk '{print $1}' | sort -u)"})

  for bin in $path_bins; do
    bin="${bin##*/}"  # basename
    # Skip already deep-indexed, skip internal/private names
    [[ "$bin" == _* || "$bin" == "." || -z "$bin" ]] && continue
    "$SMART_SUGGEST_BIN" index \
      --binary "$bin" \
      --completion "$bin" \
      --kind "binary" \
      --ts "$ts" \
      2>/dev/null

    # Deep-index up to SMART_SUGGEST_INDEX_DEEP additional tools
    if [[ $deep_count -lt $SMART_SUGGEST_INDEX_DEEP ]]; then
      if ! (( ${priority_tools[(I)$bin]} )); then
        _smart_suggest_index_binary "$bin" "$ts"
        deep_count=$(( deep_count + 1 ))
      fi
    fi
  done

  _smart_suggest_log "index_path complete: $deep_count tools deep-indexed"
}

# Deep-index one binary: extract subcommands and flags from --help output.
_smart_suggest_index_binary() {
  local bin="$1" ts="$2"
  local help_out subcmd desc

  # Try to get help output (timeout 3s to avoid hanging tools)
  help_out=$(timeout 3 "$bin" --help 2>&1 || timeout 3 "$bin" help 2>&1 || true)
  [[ -z "$help_out" ]] && return

  # Register the binary itself
  "$SMART_SUGGEST_BIN" index \
    --binary "$bin" --completion "$bin" --kind "binary" --ts "$ts" \
    2>/dev/null

  # Extract subcommands: lines with 2-6 leading spaces, a bare word, then spaces+description
  # Handles: "  run        Run a command"  "  build   Build the project"
  while IFS= read -r line; do
    # Match: optional leading spaces, a word (subcommand), spaces, description
    if [[ "$line" =~ ^[[:space:]]{1,6}([a-z][a-zA-Z0-9_:-]*)([[:space:]]{2,}.*)? ]]; then
      subcmd="${match[1]}"
      desc="${match[2]## }"  # strip leading spaces from description
      # Filter out common non-subcommand words
      case "$subcmd" in
        usage|options|flags|commands|available|global|version|help|examples|see|the|a|an|this|for|of|to)
          continue ;;
      esac
      [[ ${#subcmd} -lt 2 || ${#subcmd} -gt 30 ]] && continue

      "$SMART_SUGGEST_BIN" index \
        --binary "$bin" \
        --completion "$bin $subcmd" \
        --kind "subcommand" \
        $([ -n "$desc" ] && echo "--desc ${desc:0:60}") \
        --ts "$ts" \
        2>/dev/null

      # One level deeper for well-known multi-level CLIs
      case "$bin" in
        git|docker|kubectl|cargo|npm|gh)
          local sub_help
          sub_help=$(timeout 2 "$bin" "$subcmd" --help 2>&1 || true)
          # Extract flags from subcommand help
          while IFS= read -r flag_line; do
            if [[ "$flag_line" =~ (--[a-z][a-zA-Z0-9_-]+) ]]; then
              local flag="${match[1]}"
              "$SMART_SUGGEST_BIN" index \
                --binary "$bin" \
                --completion "$bin $subcmd $flag" \
                --kind "flag" \
                --ts "$ts" \
                2>/dev/null
            fi
          done <<< "$sub_help"
          ;;
      esac
    fi
  done <<< "$help_out"
}

# User-facing command to manually trigger indexing
_smart_suggest_reindex() {
  echo "Indexing system commands (background)..."
  local now_epoch=$(date +%s)
  mkdir -p "$SMART_SUGGEST_DATA_DIR"
  echo "$now_epoch" > "${SMART_SUGGEST_DATA_DIR}/.last_index"
  _smart_suggest_index_path &!
  echo "Done. Run 'smart-suggest index-stats' in a few seconds to check progress."
}

# ---------- Fig-style interactive menu (fzf-powered) ----------
#
# Pressing SMART_SUGGEST_MENU_KEY (default Ctrl+F) opens a full interactive
# menu showing:
#   - Commands from memory (scored, most relevant first)
#   - Completions from the current project (Makefile, package.json)
#   - All available commands on $PATH (loaded lazily)
#
# The selected item replaces the current line buffer.

_smart_suggest_fzf_menu() {
  # Require fzf
  if ! command -v fzf >/dev/null 2>&1; then
    zle -M "smart-context-suggest: install fzf for the interactive menu"
    return 1
  fi

  local prefix="$LBUFFER"

  # Collect candidates from multiple sources
  local candidates_file
  candidates_file=$(mktemp /tmp/smart-suggest-XXXXXX)

  {
    # Source 1: Memory (scored, with annotations)
    "$SMART_SUGGEST_BIN" query \
      --dir "$PWD" \
      --prefix "$prefix" \
      --limit "$SMART_SUGGEST_MENU_LIMIT" \
      --scores \
      --half-life "$SMART_SUGGEST_HALF_LIFE_HOURS" \
      2>/dev/null |
    while IFS=$'\t' read -r cmd score; do
      printf '%-60s  \033[32m%.4f\033[0m  \033[90m[memory]\033[0m\n' "$cmd" "$score"
    done

    # Source 2: Directory completions for cd/pushd/z
    if [[ "$prefix" == (cd|pushd|z)" "* || "$prefix" == (cd|pushd|z) ]]; then
      _smart_suggest_cd_menu_entries "$prefix" |
      while IFS= read -r entry; do
        printf '%-60s         \033[35m[dir]\033[0m\n' "$entry"
      done
    fi

    # Source 3: Project context targets
    _smart_suggest_list_project_targets "$PWD" "$prefix" |
    while IFS= read -r cmd; do
      printf '%-60s         \033[33m[project]\033[0m\n' "$cmd"
    done

    # Source 3: System command index (all installed tools + subcommands)
    if [[ ${#prefix} -ge 1 ]]; then
      "$SMART_SUGGEST_BIN" query-cmd \
        --prefix "$prefix" \
        --limit 40 \
        2>/dev/null |
      while IFS=$'\t' read -r completion desc; do
        if [[ -n "$desc" ]]; then
          printf '%-55s  \033[90m%-20s\033[0m  \033[38;5;39m[cmd]\033[0m\n' "$completion" "${desc:0:20}"
        else
          printf '%-55s                        \033[38;5;39m[cmd]\033[0m\n' "$completion"
        fi
      done
    fi

    # Source 4: PATH commands matching prefix (fallback for unindexed binaries)
    if [[ ${#prefix} -ge 2 ]]; then
      _smart_suggest_path_commands "$prefix" |
    while IFS= read -r cmd; do
        printf '%-60s         \033[36m[path]\033[0m\n' "$cmd"
      done
    fi

    # Source 5: Shell history (unique, filtered by prefix)
    if [[ -n "$prefix" ]]; then
      fc -ln 1 2>/dev/null |
        grep "^${prefix}" |
        sort -u |
        head -20 |
      while IFS= read -r cmd; do
          printf '%-60s         \033[90m[history]\033[0m\n' "$cmd"
        done
    fi

  } > "$candidates_file"

  # Deduplicate while preserving order (first occurrence wins)
  local deduped_file
  deduped_file=$(mktemp /tmp/smart-suggest-dedup-XXXXXX)
  awk '!seen[$1]++' "$candidates_file" > "$deduped_file"

  # Run fzf
  local selected
  selected=$(
    fzf \
      --ansi \
      --height=40% \
      --min-height=10 \
      --layout=reverse \
      --border=rounded \
      --prompt="❯ $prefix" \
      --header="smart-context-suggest  [Enter: accept]  [Esc: cancel]" \
      --query="$prefix" \
      --delimiter=$'\t' \
      --with-nth=1 \
      --preview-window=hidden \
      < "$deduped_file"
  )

  rm -f "$candidates_file" "$deduped_file"

  if [[ -n "$selected" ]]; then
    # Extract just the command (first column, trim trailing spaces)
    local cmd
    cmd=$(echo "$selected" | awk '{print $1}')
    # Handle multi-word commands (everything before the score column)
    cmd=$(echo "$selected" | sed 's/[[:space:]]*[0-9][.][0-9]*[[:space:]].*$//' | sed 's/[[:space:]]*\[.*\][[:space:]]*$//' | xargs)

    LBUFFER="$cmd"
    RBUFFER=""
    zle redisplay
    _smart_suggest_log "fzf-menu selected=$cmd"
  fi
}

# List all project targets for the fzf menu (no caching needed here)
_smart_suggest_list_project_targets() {
  local dir="$1" prefix="$2"

  # Makefile targets
  if [[ -f "$dir/Makefile" ]]; then
    grep -E '^[a-zA-Z0-9_.-]+:' "$dir/Makefile" 2>/dev/null |
    sed 's/:.*//' |
    while IFS= read -r t; do
      local cmd="make $t"
      [[ "$cmd" == "$prefix"* || -z "$prefix" ]] && echo "$cmd"
    done
  fi

  # npm/pnpm/yarn scripts
  if [[ -f "$dir/package.json" ]]; then
    grep '"[a-zA-Z0-9:_-]*"\s*:' "$dir/package.json" 2>/dev/null |
    sed 's/.*"\([a-zA-Z0-9:_-]*\)".*/\1/' |
    while IFS= read -r s; do
      for pfx in "npm run" "pnpm" "yarn"; do
        local cmd="$pfx $s"
        [[ "$cmd" == "$prefix"* || -z "$prefix" ]] && echo "$cmd"
      done
    done
  fi

  # cargo targets
  if [[ -f "$dir/Cargo.toml" ]]; then
    for sub in build test run check clippy fmt doc clean bench; do
      local cmd="cargo $sub"
      [[ "$cmd" == "$prefix"* || -z "$prefix" ]] && echo "$cmd"
    done
  fi
}

# List PATH commands matching a prefix (fast: uses whence -pm)
_smart_suggest_path_commands() {
  local prefix="$1"
  # List only real executables on $PATH — exclude:
  #   - shell functions (names starting with _ or containing -)
  #   - aliases and builtins
  # `whence -p` searches only $PATH (ignores functions/aliases/builtins)
  whence -pm "${prefix}*" 2>/dev/null |
    awk '{print $1}' |
    grep -v '^_' |          # drop internal zsh completion functions (_git, _docker…)
    grep -v '^\.' |         # drop dot-prefixed hidden helpers
    sort -u |
    head -30
}

# Register the fzf widget and bind it
zle -N _smart_suggest_fzf_menu
bindkey "$SMART_SUGGEST_MENU_KEY" _smart_suggest_fzf_menu

# ---------- Toggle widget: pause / resume suggestions ----------
#
# Default: Ctrl+\ toggles ghost text on/off.
# Override: SMART_SUGGEST_TOGGLE_KEY="^]" (or any bindkey sequence)
: ${SMART_SUGGEST_TOGGLE_KEY:="^\\"}

_smart_suggest_toggle() {
  if [[ $_smart_suggest_paused -eq 0 ]]; then
    _smart_suggest_paused=1
    zle -R "suggestions paused (${SMART_SUGGEST_TOGGLE_KEY} to resume)"
    # Also disable zsh-autosuggestions entirely while paused
    (( ${+functions[_zsh_autosuggest_disable]} )) && _zsh_autosuggest_disable
  else
    _smart_suggest_paused=0
    zle -R "suggestions resumed"
    (( ${+functions[_zsh_autosuggest_enable]} )) && _zsh_autosuggest_enable
  fi
}

zle -N _smart_suggest_toggle
bindkey "$SMART_SUGGEST_TOGGLE_KEY" _smart_suggest_toggle

# ---------- Command spec reader (Fig-inspired) ----------
#
# `smart-suggest completions <cmd>` reads completion specs for a command.
# This populates the fzf menu with subcommands, flags, and arguments
# by querying the shell's completion system.

_smart_suggest_read_completions() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return

  # Try zsh completion system first
  local -a specs
  # Temporarily capture what _complete would suggest
  local IFS=$'\n'
  specs=($(
    zsh -c "
      autoload -Uz compinit && compinit -C 2>/dev/null
      # Simulate completing after the command
      BUFFER='$cmd '
      CURSOR=\${#BUFFER}
      zle -l 2>/dev/null | head -1
      # Use _arguments spec if available
      whence -v _$cmd 2>/dev/null
    " 2>/dev/null
  ))

  # Fallback: use --help parsing
  local help_output
  help_output=$("$cmd" --help 2>&1 | head -80)

  # Extract flags (lines starting with whitespace then -)
  echo "$help_output" |
    grep -oE '(--?[a-zA-Z][a-zA-Z0-9_-]*)' |
    sort -u

  # Extract subcommands (lines with a word then spaces then description)
  echo "$help_output" |
    grep -E '^\s{2,6}[a-z][a-zA-Z0-9_-]+\s' |
    awk '{print $1}' |
    grep -v '^-' |
    sort -u
}

# ---------- smart-suggest wrapper (user-facing CLI) ----------
#
# Delegates to the Rust binary for data operations,
# adds shell-specific commands like `completions`.

smart-suggest() {
  case "$1" in
    completions)
      shift
      _smart_suggest_read_completions "$@"
      ;;
    index-path)
      _smart_suggest_reindex
      ;;
    index-stats)
      "$SMART_SUGGEST_BIN" index-stats
      ;;
    debug)
      if [[ "$2" == "on" ]]; then
        SMART_SUGGEST_DEBUG=1
        "$SMART_SUGGEST_BIN" debug on
      elif [[ "$2" == "off" ]]; then
        SMART_SUGGEST_DEBUG=0
        "$SMART_SUGGEST_BIN" debug off
      else
        "$SMART_SUGGEST_BIN" debug
      fi
      ;;
    help|--help|-h)
      echo "smart-suggest — context-aware shell suggestions"
      echo ""
      echo "Commands:"
      echo "  list [--dir PATH]     List learned commands for a directory"
      echo "  stats                 Show global statistics"
      echo "  query --dir D --prefix P [--limit N] [--scores]"
      echo "                        Query suggestions (debug/scripting)"
      echo "  decay [--force]       Run memory decay manually"
      echo "  clear [--dir P|--all] Delete learned entries"
      echo "  export                Export memory as JSON"
      echo "  debug on|off          Toggle debug logging"
      echo "  completions <cmd>     Show completion spec for a command"
      echo "  index-path            Rebuild system command index (background)"
      echo "  index-stats           Show command index statistics"
      echo ""
      echo "Key bindings:"
      echo "  ${SMART_SUGGEST_MENU_KEY}  Open Fig-style interactive menu"
      echo "  →  or End             Accept ghost-text suggestion"
      echo ""
      echo "Config (set in .zshrc before loading OMZ):"
      echo "  SMART_SUGGEST_MENU_KEY=${SMART_SUGGEST_MENU_KEY}"
      echo "  SMART_SUGGEST_HALF_LIFE_HOURS=${SMART_SUGGEST_HALF_LIFE_HOURS}"
      echo "  SMART_SUGGEST_STALE_DAYS=${SMART_SUGGEST_STALE_DAYS}"
      echo "  SMART_SUGGEST_DEBUG=${SMART_SUGGEST_DEBUG}"
      ;;
    *)
      # Pass everything else to the Rust binary
      "$SMART_SUGGEST_BIN" "$@"
      ;;
  esac
}

# ---------- Completion spec for the smart-suggest command itself ----------

_smart_suggest_completions() {
  local -a subcmds
  subcmds=(
    'list:List learned commands for a directory'
    'stats:Show global statistics'
    'query:Query suggestions'
    'decay:Run memory decay'
    'clear:Delete learned entries'
    'export:Export memory as JSON'
    'debug:Toggle debug logging'
    'completions:Show completion specs for a command'
    'help:Show help'
  )
  _describe 'subcommand' subcmds
}

compdef _smart_suggest_completions smart-suggest

# ==========================================================================
# MODULE: Terminal UX
# ==========================================================================
# Two widgets that improve daily terminal interaction:
#   1. Smart clear (Ctrl+L) — clears screen with a styled separator
#   2. Mouse click-to-cursor — click anywhere on the line to move the cursor

# ---------- 1. Smart clear screen ----------
#
# Replaces the default Ctrl+L with a version that:
#   - Clears the terminal (including scrollback if supported)
#   - Prints a compact separator showing: time · pwd · git branch
#   - Preserves the current command line buffer
#
# Set SMART_SUGGEST_CLEAR_KEY="" to disable (keep default Ctrl+L behaviour).
: ${SMART_SUGGEST_CLEAR_KEY:="^L"}
# Set to 0 to use a plain clear without the separator bar
: ${SMART_SUGGEST_CLEAR_SEPARATOR:=1}

_smart_suggest_clear() {
  # Clear the terminal. Send \e[3J to also wipe scrollback on supporting terminals
  # (works on iTerm2, kitty, WezTerm; degrades gracefully on others).
  echoti clear 2>/dev/null || echo -ne "\033[H\033[2J"
  echo -ne "\033[3J" 2>/dev/null   # wipe scrollback (ignored if unsupported)

  if [[ $SMART_SUGGEST_CLEAR_SEPARATOR -eq 1 ]]; then
    # ── separator bar ──────────────────────────────────────────────────────
    local time_str branch_str dir_str term_width
    term_width=${COLUMNS:-80}

    # Current time
    time_str=$(date '+%H:%M')

    # Git branch (fast: reads .git/HEAD directly, no git subprocess)
    branch_str=""
    local git_head
    git_head=$(_smart_suggest_git_head)
    [[ -n "$git_head" ]] && branch_str=" \033[35m⎇ ${git_head}\033[0m"

    # Shortened directory: replace $HOME with ~, keep last 2 segments if long
    dir_str="${PWD/#$HOME/~}"
    if [[ ${#dir_str} -gt 40 ]]; then
      dir_str="…/${dir_str:h:t}/${dir_str:t}"
    fi

    # Print the bar:  ── HH:MM  ~/dir  ⎇ branch ──────────────
    local left=" \033[90m──\033[0m \033[1m${time_str}\033[0m  \033[36m${dir_str}\033[0m${branch_str} "
    local left_plain="── ${time_str}  ${dir_str}"
    [[ -n "$git_head" ]] && left_plain+=" ⎇ ${git_head} "
    local pad=$(( term_width - ${#left_plain} - 1 ))
    [[ $pad -lt 0 ]] && pad=0
    local line="\033[90m$(printf '─%.0s' {1..$pad})\033[0m"

    echo -e "${left}${line}"
  fi

  # Redraw the prompt and restore the buffer
  zle reset-prompt
}

# Read git branch without spawning a git process
_smart_suggest_git_head() {
  local git_dir
  # Walk up to find .git
  git_dir=$(
    local d="$PWD"
    while [[ "$d" != "/" ]]; do
      [[ -f "$d/.git/HEAD" ]] && echo "$d/.git/HEAD" && return
      [[ -f "$d/.git" ]] && return  # submodule worktree — skip
      d="${d:h}"
    done
  )
  [[ -z "$git_dir" ]] && return
  local head
  head=$(< "$git_dir" 2>/dev/null)
  case "$head" in
    ref:\ refs/heads/*)  echo "${head#ref: refs/heads/}" ;;
    *)                   echo "${head:0:7}" ;;   # detached HEAD: show short SHA
  esac
}

zle -N _smart_suggest_clear
[[ -n "$SMART_SUGGEST_CLEAR_KEY" ]] && bindkey "$SMART_SUGGEST_CLEAR_KEY" _smart_suggest_clear

# ---------- 2. Mouse click-to-cursor ----------
#
# Enables xterm mouse reporting so that a left-click in the terminal moves the
# ZLE cursor to the clicked column on the current input line.
#
# How it works:
#   - Sends \e[?1000h (X10 mouse protocol) to ask the terminal to report clicks
#   - A zle widget reads the response byte sequence and moves CURSOR to the
#     clicked column (clamped to the buffer length)
#   - Mouse reporting is restored when ZLE exits so programs started from the
#     shell see a clean state
#
# This works on: iTerm2, kitty, WezTerm, xterm, most VTE terminals.
# It does NOT work on: macOS Terminal.app (no mouse support), dumb terminals.
#
# Set SMART_SUGGEST_MOUSE:=0 to disable entirely.
: ${SMART_SUGGEST_MOUSE:=1}

if [[ $SMART_SUGGEST_MOUSE -eq 1 ]]; then

  # Enable mouse on ZLE init, disable on ZLE finish
  # zle-line-init / zle-line-finish fire around each readline session
  _smart_suggest_mouse_enable() {
    # X10 basic click reporting: \e[?1000h
    # SGR extended mode (supports cols > 223): \e[?1006h
    printf '\e[?1000h\e[?1006h' > /dev/tty
  }

  _smart_suggest_mouse_disable() {
    printf '\e[?1006l\e[?1000l' > /dev/tty
  }

  # The click handler widget.
  # Terminal sends: \e[<btn;col;rowM  (SGR press) or \e[<btn;col;rowm (release)
  # We only care about left-button press (btn=0) → move cursor to col-1.
  _smart_suggest_mouse_click() {
    local char seq btn col row

    # Read the escape sequence character by character with a tight timeout.
    # \e[ already consumed by zle binding — read the rest.
    local raw=""
    while IFS= read -r -s -k1 -t 0.05 char 2>/dev/null; do
      raw+="$char"
      # SGR sequences end with M (press) or m (release)
      [[ "$char" == [Mm] ]] && break
    done

    # Parse \e[<btn;col;rowM
    if [[ "$raw" =~ '^<([0-9]+);([0-9]+);([0-9]+)[Mm]$' ]]; then
      btn="${match[1]}"
      col="${match[2]}"
      # Only act on left-button press (btn=0), ignore release and other buttons
      if [[ "$btn" -eq 0 && "$raw" == *M ]]; then
        # col is 1-indexed terminal column; subtract prompt width to get buffer offset
        # We approximate prompt width from $PROMPT with zsh prompt expansion
        local prompt_plain
        prompt_plain="${(%):-$PROMPT}"
        # Strip ANSI escapes from prompt to count visible chars
        local prompt_len
        prompt_len=${#${prompt_plain//$'\e['[0-9;]#[a-zA-Z]/}}
        local offset=$(( col - prompt_len - 1 ))
        [[ $offset -lt 0 ]] && offset=0
        [[ $offset -gt ${#BUFFER} ]] && offset=${#BUFFER}
        CURSOR=$offset
        zle redisplay
      fi
    fi
    # Non-click mouse events (scroll, hover): silently ignore
  }

  zle -N _smart_suggest_mouse_click

  # Bind \e[< — the start of an SGR mouse sequence — to our handler
  # (the terminal sends \e[<... for SGR mouse events)
  bindkey '\e[<' _smart_suggest_mouse_click

  # Hook into zle-line-init / zle-line-finish using add-zle-hook-widget
  # (available since Zsh 5.3; degrade gracefully on older versions)
  if (( ${+functions[add-zle-hook-widget]} )) || autoload -Uz add-zle-hook-widget 2>/dev/null; then
    add-zle-hook-widget zle-line-init    _smart_suggest_mouse_enable
    add-zle-hook-widget zle-line-finish  _smart_suggest_mouse_disable
  else
    # Fallback: define the widgets directly (overwrites any existing ones)
    zle -N zle-line-init    _smart_suggest_mouse_enable
    zle -N zle-line-finish  _smart_suggest_mouse_disable
  fi

fi  # SMART_SUGGEST_MOUSE

_smart_suggest_log "plugin loaded bin=$SMART_SUGGEST_BIN"
