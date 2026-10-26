# 安装指南

## 系统要求

| 要求 | 版本 | 检查方式 |
|------|------|----------|
| Zsh | 5.1+ | `zsh --version` |
| Oh My Zsh | 任意 | [ohmyz.sh](https://ohmyz.sh) |
| zsh-autosuggestions | 任意 | 幽灵文字所需 |
| Rust / cargo | 1.70+ | 编译后端所需 |
| fzf | 任意 | 可选——用于交互菜单 |

---

## 步骤 1 — 安装 zsh-autosuggestions

```zsh
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

---

## 步骤 2 — 安装 Rust

```zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

验证：`cargo --version`

---

## 步骤 3 — 克隆插件

```zsh
git clone https://github.com/Danil0ws/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

---

## 步骤 4 — 编译后端

```zsh
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
zsh install.sh
```

首次编译约需 30 秒，之后增量编译很快。

---

## 步骤 5 — 配置 ~/.zshrc

在 `source $ZSH/oh-my-zsh.sh` **之前**添加：

```zsh
plugins=(zsh-autosuggestions smart-context-suggest git)
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)

source $ZSH/oh-my-zsh.sh   # ← 策略必须在此行之前
```

---

## 步骤 6 — 重新加载

```zsh
exec zsh
```

---

## 步骤 7 — 验证

```zsh
smart-suggest stats
echo $ZSH_AUTOSUGGEST_STRATEGY   # → smart_context history
```

---

## 可选：安装 fzf

```zsh
# macOS
brew install fzf

# Linux (Debian/Ubuntu)
sudo apt install fzf
```

---

## 常见问题

**`[oh-my-zsh] plugin 'smart-context-suggest' not found`**  
创建符号链接：
```zsh
ln -sf /path/to/smart-context-suggest \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/smart-context-suggest
```

**`command not found: _zsh_autosuggest_strategy_smart_context`**  
`ZSH_AUTOSUGGEST_STRATEGY` 定义在 `source $ZSH/oh-my-zsh.sh` 之后。请将其移到该行之前。

**幽灵文字不显示**  
```zsh
smart-suggest debug on
# 检查 ~/.cache/smart-context-suggest/debug.log
```
