# Commands Reference

All commands are available as `smart-suggest <subcommand>`.

## Data Commands

### `list`
Show learned commands for a directory, ranked by score.

```zsh
smart-suggest list                    # current directory
smart-suggest list --dir ~/projects   # specific directory
smart-suggest list --dir . --json     # JSON output
```

### `query`
Query scored suggestions (useful for debugging and scripting).

```zsh
smart-suggest query --dir . --prefix "make"
smart-suggest query --dir . --prefix "git" --limit 5
smart-suggest query --dir . --prefix "npm" --scores    # show scores
smart-suggest query --dir . --prefix "" --json          # all entries as JSON
```

### `stats`
Show global statistics: total entries, top directories, top commands.

```zsh
smart-suggest stats
```

### `export`
Export entire memory as JSON (useful for backup or inspection).

```zsh
smart-suggest export > backup.json
smart-suggest export | python3 -m json.tool | head -50
```

### `clear`
Delete learned entries.

```zsh
smart-suggest clear --dir .        # current directory only
smart-suggest clear --dir ~/proj   # specific directory
smart-suggest clear --all          # ⚠️ delete everything
```

## Maintenance Commands

### `decay`
Run the decay pass manually (normally runs once per day automatically).

```zsh
smart-suggest decay                      # default stale threshold (90 days)
smart-suggest decay --stale-days 30      # more aggressive
smart-suggest decay --stale-days 0       # remove all weak entries immediately
```

### `record`
Manually record a command (normally called by the preexec hook).

```zsh
smart-suggest record --dir "$PWD" --cmd "make deploy" --ts "$(date +%s)"
```

### `mark-success`
Manually mark a command as successful or failed.

```zsh
smart-suggest mark-success --dir "$PWD" --cmd "make deploy" --ok 1
```

## Debug Commands

### `debug`
Toggle debug logging to `~/.cache/smart-context-suggest/debug.log`.

```zsh
smart-suggest debug on     # enable
smart-suggest debug off    # disable
smart-suggest debug        # show current status
```

The log shows, for each suggestion:
- Which source was used (`project`, `memory`, `cd_path`, `none`)
- The winning command and its score
- Background operations (record, decay)

### `completions`
Show completion specs for a command (reads `--help` and zsh completions).

```zsh
smart-suggest completions git
smart-suggest completions cargo
smart-suggest completions npm
```
