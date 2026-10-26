# Referência de Comandos

Todos os comandos estão disponíveis como `smart-suggest <subcomando>`.

## Comandos de Dados

### `list` — listar comandos aprendidos
```zsh
smart-suggest list                    # diretório atual
smart-suggest list --dir ~/projetos   # diretório específico
smart-suggest list --json             # saída JSON
```

### `query` — consultar sugestões com score
```zsh
smart-suggest query --dir . --prefix "make"
smart-suggest query --dir . --prefix "git" --limit 5
smart-suggest query --dir . --prefix "npm" --scores   # mostrar scores
```

### `stats` — estatísticas globais
```zsh
smart-suggest stats
```

### `export` — exportar memória como JSON
```zsh
smart-suggest export > backup.json
```

### `clear` — deletar entradas
```zsh
smart-suggest clear --dir .        # somente diretório atual
smart-suggest clear --all          # ⚠️ deletar tudo
```

## Comandos de Manutenção

### `decay` — executar decaimento manualmente
```zsh
smart-suggest decay                      # padrão (90 dias)
smart-suggest decay --stale-days 30      # mais agressivo
smart-suggest decay --stale-days 0       # remover todas as entradas fracas agora
```

## Comandos de Debug

### `debug` — ativar/desativar log de debug
```zsh
smart-suggest debug on     # ativar
smart-suggest debug off    # desativar
smart-suggest debug        # ver status atual
```

O log em `~/.cache/smart-context-suggest/debug.log` mostra para cada sugestão:
- Qual fonte foi usada (`project`, `memory`, `cd_path`, `none`)
- O comando vencedor e seu score
- Operações em background (record, decay)

### `completions` — ver specs de autocompletar de um comando
```zsh
smart-suggest completions git
smart-suggest completions cargo
```
