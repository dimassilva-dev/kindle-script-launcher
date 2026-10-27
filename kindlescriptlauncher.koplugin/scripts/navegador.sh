#!/bin/sh
# Name: Navegador
# Author: Kindle script launcher (baseado no WebBrowser da ZenLabs)
# Icon: /mnt/us/koreader/plugins/kindlescriptlauncher.koplugin/scripts/navegador.svg
# DontUseFBInk
#
# Abre o navegador nativo do Kindle (app com.lab126.browser) pelo gerenciador
# de apps (appmgrd), como o Browser.sh de github.com/xZenLabs/kindle-browser-scriptlet.
# Precisa do framework ativo: rode pela biblioteca do Kindle script launcher
# com "Iniciar o framework: sim" (o padrão). O launcher volta ao KOReader
# quando o navegador for fechado.

if ! pidof cvm >/dev/null 2>&1; then
    echo "O framework do Kindle não está ativo; o navegador precisa dele."
    exit 1
fi

lipc-set-prop com.lab126.appmgrd start app://com.lab126.browser
