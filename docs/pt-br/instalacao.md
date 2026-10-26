# Guia de Instalação

## Requisitos

| Requisito | Versão | Verificar |
|-----------|--------|-----------|
| Zsh | 5.1+ | `zsh --version` |
| Oh My Zsh | qualquer | [ohmyz.sh](https://ohmyz.sh) |
| zsh-autosuggestions | qualquer | Para o ghost text |
| Rust / cargo | 1.70+ | Para compilar o backend |
| fzf | qualquer | Opcional — para o menu interativo |

---

## Passo 1 — Instalar zsh-autosuggestions (se ainda não tiver)

```zsh
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

---

## Passo 2 — Instalar Rust (se ainda não tiver)

```zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

Verifique: `cargo --version`

---

## Passo 3 — Clonar o plugin

```zsh
git clone https://github.com/Danil0ws/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

---

## Passo 4 — Compilar o backend

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh
```

Compila o backend Rust (~30 s na primeira vez) e copia o binário para `bin/smart-suggest`.

---

## Passo 5 — Configurar o ~/.zshrc

Adicione estas linhas **antes** de `source $ZSH/oh-my-zsh.sh`:

```zsh
# 1. Adicionar o plugin à lista
plugins=(zsh-autosuggestions smart-context-suggest git)

# 2. Definir a estratégia de sugestão (deve vir ANTES da linha source)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
```

**Verifique a ordem** — seu `.zshrc` deve ficar assim:

```zsh
# ... (p10k instant prompt, se usar, fica no topo)

plugins=(zsh-autosuggestions smart-context-suggest git)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)

source $ZSH/oh-my-zsh.sh   # ← a estratégia DEVE estar antes desta linha

# ... resto da sua configuração
```

---

## Passo 6 — Recarregar

```zsh
exec zsh
```

---

## Passo 7 — Verificar

```zsh
# Verificar que o binário funciona
smart-suggest stats

# Verificar que a estratégia está registrada
echo $ZSH_AUTOSUGGEST_STRATEGY
# → smart_context history

# Testar uma sugestão: digite um comando que você já usou antes
# O ghost text deve aparecer — pressione → para aceitar
```

---

## Opcional: Instalar fzf (para o menu Ctrl+F)

```zsh
# macOS
brew install fzf

# Linux (Debian/Ubuntu)
sudo apt install fzf

# Qualquer plataforma via git
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install
```

---

## Atualizar

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
git pull
zsh install.sh
exec zsh
```

---

## Desinstalar

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh --uninstall

# Remover do plugins=() no ~/.zshrc
# Remover a linha ZSH_AUTOSUGGEST_STRATEGY
exec zsh
```

---

## Solução de Problemas

### `[oh-my-zsh] plugin 'smart-context-suggest' not found`

O nome do diretório do plugin deve ser exatamente igual ao nome em `plugins=(...)`. Verifique:

```zsh
ls ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/
# deve mostrar: smart-context-suggest
```

Se clonou em outro caminho, crie um symlink:

```zsh
ln -sf /caminho/para/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

### `command not found: _zsh_autosuggest_strategy_smart_context`

`ZSH_AUTOSUGGEST_STRATEGY` está definido **depois** de `source $ZSH/oh-my-zsh.sh`. Mova para antes.

### Aviso do Powerlevel10k (instant prompt)

Todos os hooks em background já redirecionam para `/dev/null`. Se ainda aparecer o aviso, verifique se há algo mais no seu `.zshrc` imprimindo no stdout entre o preâmbulo do p10k e a linha `source`.

### Ghost text não aparece

1. Confirme que `zsh-autosuggestions` está na lista `plugins=()`
2. Confirme que `ZSH_AUTOSUGGEST_STRATEGY` inclui `smart_context`
3. Na primeira utilização, a memória está vazia — o ghost text vem do histórico
4. Execute `smart-suggest debug on` e verifique `~/.cache/smart-context-suggest/debug.log`
