# Configuração

Todas as configurações são variáveis de ambiente definidas no `~/.zshrc` **antes** de `source $ZSH/oh-my-zsh.sh`.

## Variáveis

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ZSH_AUTOSUGGEST_STRATEGY` | `(smart_context history)` | Ordem da cadeia de sugestão |
| `SMART_SUGGEST_MENU_KEY` | `^F` | Tecla para o menu interativo fzf |
| `SMART_SUGGEST_TOGGLE_KEY` | `^\` | Tecla para pausar/retomar ghost text |
| `SMART_SUGGEST_HALF_LIFE_HOURS` | `168` (7 dias) | Meia-vida do decaimento de recência |
| `SMART_SUGGEST_STALE_DAYS` | `90` | Dias antes de entradas fracas serem deletadas |
| `SMART_SUGGEST_MATURE_RUNS` | `2` | Mín. execuções bem-sucedidas antes de sugerir |
| `SMART_SUGGEST_MENU_LIMIT` | `50` | Máx. itens no menu fzf |
| `SMART_SUGGEST_IGNORE_SPACE` | `1` | Ignorar comandos com espaço no início |
| `SMART_SUGGEST_DEBUG` | `0` | Gravar log de debug (`1` = ativado) |
| `SMART_SUGGEST_DATA_DIR` | `~/.local/share/smart-context-suggest` | Local do banco de dados |
| `SMART_SUGGEST_BIN` | `<plugin>/bin/smart-suggest` | Caminho para o binário Rust |

## Exemplos

```zsh
# Decaimento mais agressivo (3 dias em vez de 7)
SMART_SUGGEST_HALF_LIFE_HOURS=72

# Manter entradas por mais tempo (6 meses)
SMART_SUGGEST_STALE_DAYS=180

# Mudar tecla do menu para Alt+F
SMART_SUGGEST_MENU_KEY="^[f"

# Mudar tecla de pausa para Ctrl+]
SMART_SUGGEST_TOGGLE_KEY="^]"
```

## Ajustar Pesos do Score

Edite `src/score.rs` e recompile:

```rust
pub const W_FREQ: f64    = 0.35;   // peso da frequência
pub const W_RECENCY: f64 = 0.25;   // peso da recência
pub const W_CONTEXT: f64 = 0.30;   // peso do match de prefixo
pub const W_PROJECT: f64 = 0.05;   // bônus para alvo de projeto
pub const W_SUCCESS: f64 = 0.05;   // bônus para taxa de sucesso
```

```zsh
cargo build --release && cp target/release/smart-suggest bin/
```
