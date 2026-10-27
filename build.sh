#!/bin/sh
# Empacota o plugin em dist/kindlescriptlauncher.koplugin-<versão>.zip,
# pronto para extrair em /mnt/us/koreader/plugins/ no Kindle.
# Uso: ./build.sh [versão]   (padrão: tag do git ou "dev")
set -eu
cd "$(dirname "$0")"

PLUGIN=kindlescriptlauncher.koplugin
VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
VERSION="${VERSION#v}"
OUT="dist/$PLUGIN-$VERSION.zip"

echo "Verificando a sintaxe..."
LUAC="$(command -v luac5.1 || command -v luac || true)"
if [ -n "$LUAC" ]; then
    for f in "$PLUGIN"/*.lua; do
        "$LUAC" -p "$f"
    done
else
    echo "  (luac não encontrado; pulando os .lua)"
fi
for f in "$PLUGIN"/*.sh "$PLUGIN"/scripts/*.sh; do
    sh -n "$f"
done

echo "Empacotando $OUT..."
mkdir -p dist
rm -f "$OUT"
zip -qr -X "$OUT" "$PLUGIN" -x '*.DS_Store'
echo "Pronto: $OUT"
