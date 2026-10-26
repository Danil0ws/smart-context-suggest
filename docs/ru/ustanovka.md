# Руководство по установке

## Требования

| Требование | Версия | Проверка |
|------------|--------|----------|
| Zsh | 5.1+ | `zsh --version` |
| Oh My Zsh | любая | [ohmyz.sh](https://ohmyz.sh) |
| zsh-autosuggestions | любая | Для ghost text |
| Rust / cargo | 1.70+ | Для сборки backend |
| fzf | любая | Опционально — для интерактивного меню |

---

## Шаг 1 — Установить zsh-autosuggestions

```zsh
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

---

## Шаг 2 — Установить Rust

```zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

Проверка: `cargo --version`

---

## Шаг 3 — Клонировать плагин

```zsh
git clone https://github.com/Danil0ws/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

---

## Шаг 4 — Собрать backend

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh
```

---

## Шаг 5 — Настроить ~/.zshrc

Добавьте **до** `source $ZSH/oh-my-zsh.sh`:

```zsh
plugins=(zsh-autosuggestions smart-context-suggest git)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)

source $ZSH/oh-my-zsh.sh   # ← стратегия должна быть ДО этой строки
```

---

## Шаг 6 — Перезагрузить

```zsh
exec zsh
```

---

## Шаг 7 — Проверить

```zsh
smart-suggest stats
echo $ZSH_AUTOSUGGEST_STRATEGY   # → smart_context history
```

---

## Опционально: установить fzf

```zsh
# macOS
brew install fzf

# Linux (Debian/Ubuntu)
sudo apt install fzf
```

---

## Решение проблем

**`[oh-my-zsh] plugin 'smart-context-suggest' not found`**  
Создайте символическую ссылку:
```zsh
ln -sf /путь/к/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

**`command not found: _zsh_autosuggest_strategy_smart_context`**  
`ZSH_AUTOSUGGEST_STRATEGY` определена после `source $ZSH/oh-my-zsh.sh`. Переместите её перед этой строкой.

**Ghost text не появляется**  
```zsh
smart-suggest debug on
# Проверьте ~/.cache/smart-context-suggest/debug.log
```
