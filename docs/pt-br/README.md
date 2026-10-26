# smart-context-suggest — Documentação em Português

> Autocomplete contextual para Oh My Zsh, inspirado no Fig. Aprende seus comandos por diretório.  
> Sem IA · Sem nuvem · Sem rastreamento · Algoritmos puros + SQLite.

---

## Índice

- [Como funciona](#como-funciona)
- [Instalação](instalacao.md)
- [Configuração](configuracao.md)
- [Teclas de atalho](#teclas-de-atalho)
- [Comandos](comandos.md)
- [Fórmula de score](#fórmula-de-score)

---

## Como funciona

Cada comando que você executa é silenciosamente gravado em um banco SQLite local, indexado pelo **diretório** em que você estava. Na próxima vez que você começar a digitar o mesmo comando no mesmo diretório, ele aparece como ghost text — uma sugestão esmaecida que você aceita com `→`.

```
[você digita]  → estratégia: project_context → memória (SQLite) → histórico
[Enter]        → hook preexec → grava comando (background, < 2 ms)
[comando termina] → hook precmd → grava sucesso/falha (background)
[1×/dia]       → decay → remove entradas fracas/antigas
```

### Por que por diretório?

`make build` em `~/projetos/api` não tem nada a ver com `make build` em `~/projetos/docs`. Manter o escopo por diretório evita ruído entre projetos — o mesmo princípio do [zoxide](https://github.com/ajeetdsouza/zoxide).

### Menu estilo Fig

Pressione `Ctrl+F` a qualquer momento para abrir um seletor interativo com score mostrando:

| Fonte | Cor | Descrição |
|-------|-----|-----------|
| memory | verde | Seus comandos anteriores aqui, ordenados por score |
| project | amarelo | Alvos do Makefile, scripts do npm, subcomandos do cargo |
| dir | magenta | Caminhos reais de diretório para comandos `cd` |
| path | ciano | Executáveis no `$PATH` |
| history | cinza | Histórico do shell |

### `cd` inteligente

Digitar `cd dev/minhacorp` quando o caminho real é `~/Dev/MinhaCorp` (case diferente, prefixo diferente) — o plugin encontra via:
1. Teste de caminho exato
2. Glob case-insensitive no mesmo diretório pai
3. Busca em `~/Dev`, `~/Projects`, `~/src`, `~`

---

## Teclas de atalho

| Tecla | Ação |
|-------|------|
| `→` ou `End` | Aceitar sugestão ghost text |
| `Ctrl+F` | Abrir menu interativo estilo Fig |
| `Ctrl+\` | **Pausar / retomar** ghost text |
| `Ctrl+E` | Descartar sugestão atual |

---

## Fórmula de Score

```
score = 0.35 × log(1 + frequência)
      + 0.25 × exp(−idade_horas × ln2 / meia_vida_horas)
      + 0.30 × score_match_prefixo     # 1.0 exato, 0.8 começa com, 0.3 palavra
      + 0.05 × é_projeto               # alvo de Makefile/package.json
      + 0.05 × taxa_sucesso            # fração de execuções que saíram com código 0
```

**Por que `log(1 + freq)`?** Comprime a escala — a diferença entre 1 e 2 execuções importa mais que entre 100 e 101. Um comando dominante não suprime todos os outros.

**Por que decaimento exponencial?** Modela a [curva do esquecimento de Ebbinghaus](https://pt.wikipedia.org/wiki/Curva_do_esquecimento). Um comando usado há 8 dias é naturalmente desenfatizado em relação a um usado hoje. Meia-vida padrão: **7 dias**.

---

## Arquitetura

```
raiz do plugin/
├── smart-context-suggest.plugin.zsh   # Zsh: hooks, estratégia, menu fzf, widgets
├── bin/smart-suggest                  # Binário Rust (backend)
├── src/
│   ├── main.rs    Subcomandos CLI
│   ├── db.rs      Operações SQLite
│   └── score.rs   Fórmula de score + testes unitários
├── docs/
│   ├── en/        Docs em inglês
│   ├── pt-br/     Docs em português (aqui)
│   ├── ru/        Docs em russo
│   └── zh/        Docs em chinês
└── tests/
    └── integration.zsh

Dados:  ~/.local/share/smart-context-suggest/memory.db
Cache:  ~/.cache/smart-context-suggest/debug.log  (quando debug=on)
```
