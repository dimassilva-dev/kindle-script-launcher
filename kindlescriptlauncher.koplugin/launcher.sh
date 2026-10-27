#!/bin/sh
# Disparado em segundo plano pelo kindlescriptlauncher.koplugin.
# Uso: sh launcher.sh /tmp/kindlescriptlauncher.job
#
# O arquivo de tarefa define: SCRIPT, KO_PID, RESUME_FLAG, RETURN_FB,
# SETTLE_TIME, USE_FRAMEWORK, LOG.
#
# Congela o KOReader, inicia o framework (se USE_FRAMEWORK=1), roda o script,
# espera o app aberto por ele fechar, garante o framework parado e retoma o
# KOReader. Um processo vigia retoma o KOReader caso este launcher morra.

trap '' HUP
# stop/start lab126_gui pode mandar SIGTERM (mesmo cuidado do koreader.sh).
trap ':' TERM

JOB="$1"
[ -f "$JOB" ] || exit 1
. "$JOB"
rm -f "$JOB"

LOG="${LOG:-/tmp/kindlescriptlauncher.log}"
# O script é executado depois de um cd para a pasta dele: caminho absoluto.
case "$SCRIPT" in
    /*) ;;
    *) SCRIPT="$PWD/$SCRIPT" ;;
esac
SETTLE_TIME="${SETTLE_TIME:-15}"
USE_FRAMEWORK="${USE_FRAMEWORK:-1}"
# Criado ao final da retomada; o vigia só age se ele não existir.
DONE_FLAG=/tmp/kindlescriptlauncher.done
# Criado pelo scriptlet "Voltar ao KOReader.sh" para forçar a volta.
FORCE_FLAG=/tmp/kindlescriptlauncher.force
APP_GRACE=15
exec >"$LOG" 2>&1

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

framework_job() {
    if [ -f /etc/upstart/lab126_gui.conf ]; then
        echo lab126_gui
    elif [ -f /etc/upstart/framework.conf ]; then
        echo framework
    fi
}

framework_running() {
    job="$(framework_job)"
    if [ -n "$job" ]; then
        status "$job" 2>/dev/null | grep -q "start/"
    else
        pidof cvm >/dev/null 2>&1
    fi
}

# Roda "$@" com limite de $1 segundos; se estourar, mata o comando.
run_with_timeout() {
    rwt_secs="$1"
    shift
    "$@" &
    rwt_pid=$!
    rwt_n=0
    while kill -0 "$rwt_pid" 2>/dev/null; do
        if [ "$rwt_n" -ge "$rwt_secs" ]; then
            log "Tempo esgotado (${rwt_secs}s): $*"
            kill -KILL "$rwt_pid" 2>/dev/null
            return 124
        fi
        sleep 1
        rwt_n=$((rwt_n + 1))
    done
    wait "$rwt_pid"
}

start_framework() {
    job="$(framework_job)"
    if [ -n "$job" ]; then
        (cd / && run_with_timeout 90 start "$job")
    elif [ -x /etc/init.d/framework ]; then
        (cd / && run_with_timeout 90 /etc/init.d/framework start)
    else
        log "Não sei como iniciar o framework neste firmware."
    fi
}

# Com limite de tempo: um "stop" travado já deixou o KOReader congelado.
stop_framework() {
    job="$(framework_job)"
    if [ -n "$job" ]; then
        run_with_timeout 30 stop "$job"
    elif [ -x /etc/init.d/framework ]; then
        run_with_timeout 30 /etc/init.d/framework stop
    fi
}

framework_alive() {
    framework_running || pidof cvm >/dev/null 2>&1
}

# Para o framework e confirma que ele realmente parou (job parado e cvm
# encerrado). Se não parar após algumas tentativas, encerra o cvm à força.
# Também encerra apps mesquite que tenham sobrado (o KOReader não usa nenhum).
ensure_framework_stopped() {
    tries=0
    while framework_alive; do
        tries=$((tries + 1))
        if [ "$tries" -gt 2 ]; then
            log "Framework não parou; encerrando o cvm à força."
            killall -TERM cvm 2>/dev/null
            sleep 2
            killall -KILL cvm 2>/dev/null
            sleep 1
            break
        fi
        log "Parando o framework (tentativa $tries)..."
        stop_framework
        n=0
        while pidof cvm >/dev/null 2>&1 && [ "$n" -lt 15 ]; do
            sleep 1
            n=$((n + 1))
        done
    done
    if pidof mesquite >/dev/null 2>&1; then
        log "Encerrando apps mesquite restantes."
        killall -TERM mesquite 2>/dev/null
        sleep 1
        killall -KILL mesquite 2>/dev/null
    fi
    # Deixa o desmonte do framework terminar antes de redesenhar (como o koreader.sh).
    usleep 1250000 2>/dev/null || sleep 1
    if framework_alive; then
        log "AVISO: framework ainda ativo ($(status lab126_gui 2>/dev/null); cvm: $(pidof cvm))."
    else
        log "Framework parado ($(status lab126_gui 2>/dev/null))."
    fi
}

active_app() {
    lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null
}

is_home_app() {
    case "$1" in
        com.lab126.KPPMainApp | com.lab126.booklet.home | com.lab126.booklet.library) return 0 ;;
    esac
    return 1
}

# Mensagem centralizada na tela via FBInk (o mesmo que o koreader.sh usa).
# Copiado para /var/tmp porque /mnt/us não permite executar binários.
FBINK=/var/tmp/kindlescriptlauncher-fbink
if [ ! -x "$FBINK" ] && [ -f /mnt/us/koreader/fbink ]; then
    cp -f /mnt/us/koreader/fbink "$FBINK" && chmod 755 "$FBINK"
fi

show_message() {
    if [ -x "$FBINK" ]; then
        "$FBINK" -q -c -f -m -M -S 3 "$1"
    elif command -v eips >/dev/null 2>&1; then
        eips -c
        eips 3 20 "$1"
    fi
}

# Tela de início desenhada pelo plugin, copiada do framebuffer antes de
# pausar o KOReader. Redesenhada sempre que o framework pinta por cima
# (Home etc.) até o script rodar.
SPLASH_FB=/var/tmp/kindlescriptlauncher-splash.fb

refresh_screen() {
    if [ -x "$FBINK" ]; then
        "$FBINK" -q -f -s top=0,left=0,width=0,height=0 && return
    fi
    eips '' >/dev/null 2>&1
}

# Sem cmp não dá para saber se o framework pintou por cima; nesse caso a
# tela só é redesenhada uma vez, logo antes do script, para não piscar.
HAVE_CMP=""
command -v cmp >/dev/null 2>&1 && HAVE_CMP=1

cover_with_splash() {
    [ -s "$SPLASH_FB" ] || return
    if [ -z "$HAVE_CMP" ]; then
        [ "$1" = "force" ] || return
        cat "$SPLASH_FB" >/dev/fb0 2>/dev/null && refresh_screen
        return
    fi
    if ! cmp -s /dev/fb0 "$SPLASH_FB"; then
        cat "$SPLASH_FB" >/dev/fb0 2>/dev/null && refresh_screen
    fi
}

# Tela de retorno pré-desenhada pelo plugin (mesmo visual da tela de início).
show_return_screen() {
    if [ -n "$RETURN_FB" ] && [ -s "$RETURN_FB" ]; then
        cat "$RETURN_FB" >/dev/fb0 2>/dev/null && refresh_screen && return
    fi
    show_message "Voltando ao KOReader..."
}

# Espera $1 segundos mantendo a tela de início visível.
sleep_with_splash() {
    n=0
    while [ "$n" -lt "$1" ]; do
        cover_with_splash
        sleep 1
        n=$((n + 1))
    done
}

# Sessão deste launcher (setsid faz SID == $$). Sem setsid não dá para
# distinguir os processos do script, então o rastreamento fica desligado.
MY_SID=""
if { read -r _stat </proc/$$/stat; } 2>/dev/null; then
    set -- ${_stat##*") "}
    [ "$4" = "$$" ] && MY_SID="$$"
fi

# Verdadeiro se algum processo da nossa sessão (exceto este) estiver vivo,
# ou seja, algo que o script deixou rodando em segundo plano. Usa só
# builtins para não criar processos próprios durante a varredura.
session_busy() {
    [ -n "$MY_SID" ] || return 1
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        [ "${d#/proc/}" = "$WATCHDOG_PID" ] && continue
        { read -r _stat <"$d/stat"; } 2>/dev/null || continue
        set -- ${_stat##*") "}
        # $2 = ppid, $4 = sessão; o vigia e os filhos dele não contam.
        [ -n "$WATCHDOG_PID" ] && [ "$2" = "$WATCHDOG_PID" ] && continue
        [ "$4" = "$MY_SID" ] && return 0
    done
    return 1
}

# Verdadeiro se o script abre o app pelo gerenciador de apps do Kindle (e
# portanto retorna antes de o app fechar), como o kwordle.
script_launches_app() {
    grep -v '^#' "$SCRIPT" 2>/dev/null | grep -qE 'appmgrd[[:space:]]+start|kpm[[:space:]]+launch'
}

# Espera o que o script abriu ser fechado.
# - Processos deixados em segundo plano: espera todos terminarem.
# - Só em scripts que abrem app via appmgrd: o "app do script" é o primeiro
#   app ativo (fora da Home) diferente do que estava antes do script; ou, se
#   o Kindle mantiver o mesmo nome de antes, o app ativo cujo identificador
#   aparece no texto do script. Termina quando o app ativo deixar de ser ele.
#   Sem app identificado na janela inicial, não espera mais nada.
wait_script_apps() {
    if [ "$APP_MODE" = "1" ]; then
        grace=$APP_GRACE
    else
        grace=2
    fi
    elapsed=0
    calm=0
    app=""
    last="-"
    while :; do
        if [ -f "$FORCE_FLAG" ]; then
            rm -f "$FORCE_FLAG"
            log "Retorno forçado pelo usuário."
            return 0
        fi
        cur=""
        if [ "$APP_MODE" = "1" ]; then
            cur="$(active_app)"
            if [ "$cur" != "$last" ]; then
                log "App ativo: ${cur:-(desconhecido)}"
                last="$cur"
            fi
            if [ -z "$app" ] && [ -n "$cur" ] && ! is_home_app "$cur"; then
                if [ "$cur" != "$BASE_APP" ]; then
                    app="$cur"
                    log "App do script: $app"
                elif grep -qF -- "$cur" "$SCRIPT" 2>/dev/null; then
                    app="$cur"
                    log "App do script (citado no script): $app"
                fi
            fi
        fi
        if { [ -n "$app" ] && [ "$cur" = "$app" ]; } || session_busy; then
            calm=0
        else
            calm=$((calm + 1))
        fi
        if [ "$calm" -ge 2 ] && [ "$elapsed" -ge "$grace" ]; then
            log "App fechado."
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

ko_alive() {
    [ -n "$KO_PID" ] && kill -0 "$KO_PID" 2>/dev/null
}

RESUMED=""
resume_koreader() {
    [ -n "$RESUMED" ] && return
    RESUMED=1
    show_return_screen
    ensure_framework_stopped
    # O koreader.sh deixa o volumd pausado enquanto o KOReader roda.
    killall -STOP volumd 2>/dev/null
    # De novo: o desmonte do framework pode ter apagado a tela.
    show_return_screen
    rm -f "$SPLASH_FB" "$RETURN_FB"
    touch "$RESUME_FLAG"
    kill -CONT "$KO_PID" 2>/dev/null
    touch "$DONE_FLAG"
    log "KOReader retomado."
}

# Vigia: se este launcher morrer (ou for morto) sem retomar o KOReader, faz
# uma retomada de emergência para nunca deixar a tela congelada/branca.
start_watchdog() {
    launcher_pid=$$
    (
        trap '' HUP TERM INT
        while kill -0 "$launcher_pid" 2>/dev/null; do
            sleep 2
        done
        [ -f "$DONE_FLAG" ] && exit 0
        log "[vigia] O launcher encerrou sem retomar o KOReader; retomando."
        show_return_screen
        job="$(framework_job)"
        [ -n "$job" ] && (stop "$job" >/dev/null 2>&1 &)
        sleep 8
        killall -KILL cvm 2>/dev/null
        killall -TERM mesquite 2>/dev/null
        killall -STOP volumd 2>/dev/null
        show_return_screen
        touch "$RESUME_FLAG"
        kill -CONT "$KO_PID" 2>/dev/null
        touch "$DONE_FLAG"
        log "[vigia] KOReader retomado."
    ) </dev/null >>"$LOG" 2>&1 &
    WATCHDOG_PID=$!
}
# Garante que o KOReader nunca fique congelado, mesmo se algo der errado.
trap 'resume_koreader' EXIT

log "Script: $SCRIPT"
if ! ko_alive; then
    log "KOReader (PID $KO_PID) não encontrado; abortando."
    RESUMED=1
    exit 1
fi

# 1. Guarda a tela de início e congela o KOReader (a entrada já foi solta
#    pelo plugin).
rm -f "$DONE_FLAG"
WATCHDOG_PID=""
start_watchdog
sleep 1
cat /dev/fb0 >"$SPLASH_FB" 2>/dev/null || rm -f "$SPLASH_FB"
log "Pausando o KOReader (PID $KO_PID)..."
kill -STOP "$KO_PID"

# 2. Inicia o framework (ou não, no modo sem framework).
if [ "$USE_FRAMEWORK" = "1" ]; then
    killall -CONT volumd 2>/dev/null
    if framework_running; then
        log "Framework já está ativo."
    else
        log "Iniciando o framework..."
        start_framework
    fi
    n=0
    until pidof cvm >/dev/null 2>&1; do
        n=$((n + 1))
        if [ "$n" -ge 120 ]; then
            log "cvm não apareceu após 120 s; seguindo assim mesmo."
            break
        fi
        cover_with_splash
        sleep 1
    done
    log "Aguardando ${SETTLE_TIME}s para o framework estabilizar..."
    sleep_with_splash "$SETTLE_TIME"
    cover_with_splash force
else
    log "Modo sem framework (servidor X: $(pidof Xorg X 2>/dev/null || echo 'não encontrado'))."
fi

# 3. Executa o script e espera o que ele abriu fechar.
rm -f "$FORCE_FLAG"
APP_MODE=""
BASE_APP=""
if [ "$USE_FRAMEWORK" = "1" ] && script_launches_app; then
    APP_MODE=1
    BASE_APP="$(active_app)"
    log "Script abre app pelo appmgrd. App ativo antes: ${BASE_APP:-(desconhecido)}"
fi
# Respeita "#!/bin/bash" (ex.: gambatte); o resto roda com sh.
INTERP=sh
case "$(head -n 1 "$SCRIPT" 2>/dev/null)" in
    *bash*) command -v bash >/dev/null 2>&1 && INTERP=bash ;;
esac
log "Executando $SCRIPT ($INTERP)"
(cd "$(dirname "$SCRIPT")" && "$INTERP" "$SCRIPT")
log "Script terminou (código $?)."
wait_script_apps

# 4. Para o framework e retoma o KOReader.
resume_koreader
