#!/usr/bin/env bash
# Instala el helper nativo de C-Key y lo deja como servicio del sistema.
#
# El helper lee el teclado y el touchpad por evdev. En Linux eso lo controla la
# politica de dispositivos del cgroup: solo el compositor (niri) y root pueden
# abrir /dev/input, porque el compositor lo toma en exclusiva con el TakeDevice
# de logind. Por eso el servicio va como root, y el propio helper baja
# privilegios para hablar con DMS por IPC.
#
# Uso:  sudo ./install.sh

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/ckeys-hold"
DEST=/usr/local/bin/ckeys-hold
UNIT=/etc/systemd/system/ckeys-hold.service

if [[ ! -f "$BIN" ]]; then
    echo "compilando ckeys-hold..."
    cc -O2 -Wall -o "$BIN" "$DIR/ckeys-hold.c"
fi

echo "instalando $DEST"
install -m 755 "$BIN" "$DEST"

# el helper necesita saber a que usuario pertenece la sesion para el IPC
UID_DMS="${CKEYS_UID:-$(id -u)}"

cat > "$UNIT" <<EOF
[Unit]
Description=C-Key: helper nativo (detecta la combinacion y usa el touchpad)
After=graphical-session.target

[Service]
Type=simple
Environment=CKEYS_UID=$UID_DMS
ExecStart=$DEST
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "habilitando el servicio"
systemctl daemon-reload
systemctl enable --now ckeys-hold.service

echo
echo "listo. el plugin QML va en ~/.config/DankMaterialShell/plugins/C-Key/"
echo "y se activa desde Ajustes -> Plugins."
