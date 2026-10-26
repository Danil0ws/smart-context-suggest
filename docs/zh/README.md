# smart-context-suggest — 中文文档

> 受 Fig 启发的 Oh My Zsh 上下文感知自动补全插件。  
> 无 AI · 无云端 · 无追踪 · 纯算法 + SQLite。

---

## 目录

- [工作原理](#工作原理)
- [安装](anzhuang.md)
- [配置](#配置)
- [快捷键](#快捷键)

---

## 工作原理

每次执行的命令都会被静默记录在本地 SQLite 数据库中，以您所在的**目录**为索引。下次在同一目录开始输入相同命令时，它会以幽灵文字（ghost text）的形式出现——按 `→` 接受淡显的补全建议。

```
[输入]    → 策略: project_context → 记忆 (SQLite) → 历史记录
[Enter]   → preexec 钩子 → 后台记录命令 (< 2 毫秒)
[结束]    → precmd 钩子  → 后台记录成功/失败
[每天1次] → decay → 删除旧/弱条目
```

### 为什么按目录区分？

`~/projects/api` 中的 `make build` 与 `~/projects/docs` 中的 `make build` 是不同的。按目录区分避免了跨项目噪音——这与 [zoxide](https://github.com/ajeetdsouza/zoxide) 的核心理念相同。

### Fig 风格菜单

随时按 `Ctrl+F` 打开带评分的交互式选择器：

| 来源 | 颜色 | 说明 |
|------|------|------|
| memory | 绿色 | 您在此目录的历史命令，按评分排序 |
| project | 黄色 | Makefile 目标、npm 脚本、cargo 子命令 |
| dir | 洋红 | `cd` 命令的真实目录路径 |
| path | 青色 | `$PATH` 中的可执行文件 |
| history | 灰色 | Shell 历史记录 |

### 智能 `cd`

输入 `cd dev/myproject`，即使真实路径是 `~/Dev/MyProject`（大小写不同）——插件会通过以下方式找到它：
1. 精确路径测试
2. 在同一父目录中进行大小写不敏感的 glob 匹配
3. 在 `~/Dev`、`~/Projects`、`~/src`、`~` 中搜索

---

## 快捷键

| 按键 | 操作 |
|------|------|
| `→` 或 `End` | 接受幽灵文字建议 |
| `Ctrl+F` | 打开 Fig 风格交互菜单 |
| `Ctrl+\` | **暂停 / 恢复**幽灵文字 |
| `Ctrl+E` | 忽略当前建议 |

---

## 评分公式

```
score = 0.35 × log(1 + 频率)
      + 0.25 × exp(−年龄_小时 × ln2 / 半衰期_小时)
      + 0.30 × 前缀匹配分数     # 1.0 精确, 0.8 前缀, 0.3 单词
      + 0.05 × 是否项目目标     # Makefile/package.json 目标
      + 0.05 × 成功率           # 退出码为 0 的运行比例
```

**为什么用 `log(1 + freq)`？** 压缩尺度——1 次和 2 次运行之间的差异比 100 次和 101 次更重要。

**为什么指数衰减？** 模拟[艾宾浩斯遗忘曲线](https://zh.wikipedia.org/wiki/遗忘曲线)。默认半衰期：**7 天**。

---

## 配置

在 `~/.zshrc` 中 `source $ZSH/oh-my-zsh.sh` **之前**设置：

```zsh
ZSH_AUTOSUGGEST_STRATEGY=(smart_context history)
SMART_SUGGEST_MENU_KEY="^F"          # Ctrl+F 打开菜单
SMART_SUGGEST_TOGGLE_KEY="^\\"       # Ctrl+\ 暂停
SMART_SUGGEST_HALF_LIFE_HOURS=168    # 7 天
SMART_SUGGEST_STALE_DAYS=90          # 90 天后删除弱条目
```

详情见：[docs/en/configuration.md](../en/configuration.md)
