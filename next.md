Prompt — "Memory Agent" para Contagem de Comandos e Subcomandos (sem UI)
Este prompt é a fase 0 do plugin smart-context-suggest: construir apenas o agente de coleta — um processo que descobre, conta e armazena o uso de comandos e subcomandos. Sem dropdown, sem ghost text, sem widgets ZLE. Só o backend alimentando o banco de dados para você validar os dados antes de investir em qualquer interface.

A vantagem dessa abordagem é que, quando você finalmente for construir o Fig-like, os dados já estarão prontos, limpos e validados. Você olha o banco e sabe exatamente o que o autocomplete teria sugerido.

🎯 Missão
Construir um agente de memória chamado smart-memory-agent que:

Descobre todos os comandos executáveis disponíveis no sistema ($PATH) e todos os comandos com conclusão registrada no Zsh (_comps).

Descobre subcomandos de cada comando, em camadas (specs do Zsh → specs do Fig → --help em sandbox).

Registra toda execução de comando no Zsh, capturando o verbo e o subcomando (ex.: git + checkout).

Conta frequência por (diretório, comando, subcomando) com timestamps.

Expõe tudo via CLI para inspeção — nada de UI ainda.

O agente roda como parte dos hooks Zsh (coleta passiva) e como CLI manual (descoberta ativa). Não há daemon persistente, não há socket, não há interface visual.

🏗️ Arquitetura Simplificada
text
$ZSH_CUSTOM/plugins/smart-memory-agent/
├── smart-memory-agent.plugin.zsh    # Hooks preexec/precmd (coleta passiva)
├── bin/smart-agent                  # CLI Rust (descoberta + inspeção)
├── src/
│   ├── main.rs
│   ├── db.rs
│   ├── discover.rs                  # Scan de $PATH, _comps, --help
│   └── parse.rs                     # Extração de verbo + subcomando
├── Cargo.toml
└── README.md
Banco único: ~/.local/share/smart-memory-agent/memory.db (SQLite, modo WAL).

🗄️ Schema do Banco
Tabela 1 — Catálogo de comandos descobertos
sql
CREATE TABLE commands (
    command     TEXT PRIMARY KEY,        -- ex.: "git"
    path        TEXT,                    -- caminho absoluto do binário
    has_spec    INTEGER DEFAULT 0,       -- 1 se tem completion nativa
    spec_source TEXT,                    -- "zsh_comp" | "fig_spec" | "help_scan" | NULL
    discovered_at INTEGER NOT NULL
);
Tabela 2 — Subcomandos descobertos
sql
CREATE TABLE subcommands (
    command    TEXT NOT NULL,            -- ex.: "git"
    subcommand TEXT NOT NULL,            -- ex.: "checkout"
    source     TEXT NOT NULL,            -- "zsh_comp" | "fig_spec" | "help_scan"
    confidence INTEGER DEFAULT 100,      -- 100 = spec oficial, 50 = help_scan
    PRIMARY KEY (command, subcommand)
);
Tabela 3 — Contagem de uso (o coração do agente)
sql
CREATE TABLE usage (
    directory  TEXT NOT NULL,
    command    TEXT NOT NULL,            -- "git"
    subcommand TEXT NOT NULL DEFAULT '', -- "checkout" (vazio se não houver)
    frequency  INTEGER NOT NULL DEFAULT 1,
    first_seen INTEGER NOT NULL,
    last_used  INTEGER NOT NULL,
    success_count INTEGER DEFAULT 0,
    fail_count    INTEGER DEFAULT 0,
    PRIMARY KEY (directory, command, subcommand)
);
Tabela 4 — Log bruto (para auditoria e debugging)
sql
CREATE TABLE raw_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp  INTEGER NOT NULL,
    directory  TEXT NOT NULL,
    full_command TEXT NOT NULL,          -- linha completa digitada
    exit_code  INTEGER,                  -- preenchido no precmd
    parsed_ok  INTEGER DEFAULT 0         -- 1 se parsing extraiu verbo/subcomando
);
O raw_log é o que permite você validar o parsing depois: se git checkout -b feat virou (git, checkout), você vê isso aqui.

🔍 Descoberta em Camadas (sem UI)
Camada 1 — $PATH (quais comandos existem)
Varre todos os diretórios em $PATH, lista executáveis, deduplica, e popula commands. Rápido, sem executar nada.

rust
// pseudo-código
for dir in env::var("PATH").split(':') {
    for entry in fs::read_dir(dir) {
        if is_executable(entry) { insert_command(entry.file_name()) }
    }
}
Camada 2 — _comps do Zsh (quais têm completion nativa)
O Zsh mantém um array associativo _comps mapeando comando → função de conclusão. O agente exporta esse array para um JSON temporário e o Rust lê:

zsh
# No plugin.zsh, ao carregar:
_smart_agent_export_comps() {
    local tmp=$(mktemp)
    for cmd func in ${(kv)_comps}; do
        print -r -- "$cmd\t$func" >> "$tmp"
    done
    "$SMART_AGENT_BIN" import-comps --file "$tmp" &
    rm -f "$tmp"
}
Isso atualiza commands.has_spec = 1 e commands.spec_source = 'zsh_comp'.

Camada 3 — $fpath (arquivos de spec)
Varre $fpath, lê as linhas #compdef de cada arquivo em _*, e extrai o nome do comando. Mesmo resultado da Camada 2, mas sem depender do Zsh estar rodando.

Camada 4 — --help em sandbox (subcomandos de comandos sem spec)
Para comandos que têm has_spec = 0, o agente roda comando --help em background, com:

Timeout de 500 ms.

Sandbox: env -i (ambiente limpo), PATH restrito, sem rede (se unshare disponível), working dir em /tmp.

Parse: extrai linhas que começam com espaço + palavra + descrição, tipicamente na seção "Commands:" ou "Available commands:".

rust
fn scan_help(command: &str) -> Vec<String> {
    let output = Command::new("timeout")
        .args(["0.5", command, "--help"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .output();
    // parse linhas tipo "  checkout  Switch branches"
}
Popula subcommands com source = 'help_scan' e confidence = 50.

Camada 5 — Cache de resultados
Tudo é cacheado. Rodar smart-agent discover de novo só reprocessa comandos novos ou cujo binário mudou (compara mtime).

📝 Registro de Uso (o "agent" passivo)
Hook preexec — captura comando + diretório
zsh
_smart_agent_preexec() {
    local cmd="$1"
    # Chama o binário em background para não travar
    "$SMART_AGENT_BIN" record \
        --dir "$PWD" \
        --cmd "$cmd" \
        --ts "$(date +%s)" \
        >/dev/null 2>&1 &!
}
add-zsh-hook preexec _smart_agent_preexec
Hook precmd — captura exit code
zsh
_smart_agent_precmd() {
    local exit_code=$?
    "$SMART_AGENT_BIN" mark-exit \
        --code "$exit_code" \
        >/dev/null 2>&1 &!
}
add-zsh-hook precmd _smart_agent_precmd
Parsing do verbo + subcomando (no Rust)
O record recebe a linha bruta e faz parsing:

Verbo = primeira palavra (ignorando sudo, env, nohup, variáveis VAR=x).

Subcomando = segunda palavra se e somente se ela não começar com - e o verbo estiver na tabela commands com has_spec = 1. Caso contrário, subcommand = ''.

Exemplos:

Linha digitada	Verbo	Subcomando
git checkout -b feat	git	checkout
docker compose up	docker	compose
ls -la	ls	''
npm install	npm	install
make build	make	build
./script.sh arg	./script.sh	''
O parsing não tenta adivinhar flags ou argumentos — só verbo e subcomando. Isso mantém a lógica simples e auditável.

💻 CLI do Agente (apenas inspeção)
O binário smart-agent expõe subcomandos para você ver o que o agente aprendeu:

Comando	O que faz
smart-agent discover [--force]	Roda todas as camadas de descoberta
smart-agent discover --only path	Só $PATH
smart-agent discover --only comps	Só _comps/$fpath
smart-agent discover --only help	Só --help em sandbox
smart-agent record --dir D --cmd C --ts T	Registra manualmente (usado pelos hooks)
smart-agent mark-exit --code N	Atualiza exit code do último registro
smart-agent list-commands [--filter F]	Lista comandos descobertos
smart-agent list-subcommands <cmd>	Lista subcomandos de um comando
smart-agent top [--dir D] [--limit N]	Top comandos por frequência
smart-agent top-sub [--dir D] [--limit N]	Top pares (comando, subcomando)
smart-agent show <dir>	Mostra toda a memória de um diretório
smart-agent raw-tail [--n 20]	Últimas N linhas do raw_log (para validar parsing)
smart-agent stats	Totais: comandos descobertos, subcomandos, entradas de uso
smart-agent export --format json	Exporta tudo em JSON
smart-agent clear --dir D | --all	Limpa dados
Exemplo de saída esperada (após 1 semana de uso):

text
$ smart-agent top --dir ~/projetos/api --limit 5
FREQ  COMMAND    SUBCOMMAND   LAST_USED
 42   git        status       2026-10-25 14:22
 31   cargo      test         2026-10-25 14:20
 18   git        commit       2026-10-25 14:19
 12   docker     compose      2026-10-24 18:05
  7   make       build        2026-10-24 17:30
text
$ smart-agent list-subcommands git
SUBCOMMAND   SOURCE      CONFIDENCE
add          zsh_comp    100
branch       zsh_comp    100
checkout     zsh_comp    100
clone        zsh_comp    100
commit       zsh_comp    100
...
✅ Critérios de Aceite (fase 0)
□ smart-agent discover popula commands com ≥100 comandos do $PATH.
□ smart-agent discover --only comps marca has_spec = 1 para comandos com conclusão nativa.
□ smart-agent list-subcommands git retorna ≥10 subcomandos (se git tem completion no sistema).
□ smart-agent discover --only help --command foo nunca trava (timeout de 500 ms respeitado).
□ Após 10 execuções de git status no mesmo diretório, smart-agent top mostra git status com freq=10.
□ smart-agent raw-tail mostra as linhas brutas para você conferir o parsing.
□ smart-agent show <dir> mostra a memória completa do diretório (comando, subcomando, freq, último uso, sucessos/falhas).
□ Nenhum widget ZLE, nenhum dropdown, nenhuma ghost text é instalado.
□ O precmd/preexec adicionam < 2 ms de latência perceptível (tudo em &!).
🚫 Restrições (fase 0)
Zero UI. Sem zle, sem zsh-autosuggestions, sem fzf-tab, sem dropdown.

Zero IA. Só parsing determinístico e contagem.

Zero daemon. O agente é invocado pontualmente pelos hooks e pela CLI.

Nunca executar comando do usuário. O --help em sandbox é a única execução, e sempre com timeout e ambiente limpo.

Idempotente. Rodar discover duas vezes não duplica registros.

📖 Material Educacional no README
Por que separar coleta de UI — você valida os dados antes de investir na renderização; bugs de parsing aparecem no raw-tail, não como sugestões erradas.

Como o parsing verbo/subcomando funciona — tabela de exemplos, regras, e por que não tentamos parsear flags.

Por que --help em sandbox — risco de comandos maliciosos ou que travam; o timeout + env -i protegem o agente.

A diferença entre commands, subcommands e usage — catálogo estático vs. contagem dinâmica.

Como validar o agente manualmente — fluxo: rodar comandos, raw-tail, top, show, comparar.

🗺️ Roadmap (o que vem depois)
Este prompt cobre só a fase 0. Quando os dados estiverem validados, as próximas fases (que já estão no prompt anterior) são:

Fase 1: estratégia de autosuggest (ghost text) consultando usage.

Fase 2: fórmula de score com decaimento e recência.

Fase 3: menu dropdown estilo Fig.

Fase 4: enriquecimento com specs do Fig/inshellisense.

A fase 0 é a fundação. Se os dados de usage estiverem errados, tudo depois fica errado — por isso vale a pena construir e validar esta camada isoladamente, sem a distração da UI.

