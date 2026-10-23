#!/usr/bin/env bash
# Instala el helper nativo de C-Key como servicio del sistema.
#
# El helper lee el teclado y el touchpad por evdev, y solo el compositor y root
# pueden abrir /dev/input, asi que el servicio va como root y el helper baja
# privilegios para el IPC.
#
# Uso:  sudo ./install.sh

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "corre este script con sudo desde tu usuario: sudo ./install.sh" >&2
    exit 1
fi

# root no sirve como usuario de la sesion: el IPC de DMS corre en /run/user/0
# y no existe. El usuario real es el que invoco sudo.
UID_DMS="${SUDO_UID:-}"
GID_DMS="${SUDO_GID:-}"

if [[ -z "$UID_DMS" || "$UID_DMS" -eq 0 || -z "$GID_DMS" || "$GID_DMS" -eq 0 ]]; then
    echo "no pude detectar tu usuario: corre 'sudo ./install.sh' desde tu sesion." >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/ckeys-hold"
DEST=/usr/local/bin/ckeys-hold
UNIT=/etc/systemd/system/ckeys-hold.service

if [[ ! -f "$BIN" || "$DIR/ckeys-hold.c" -nt "$BIN" ]]; then
    echo "compilando ckeys-hold..."
    cc -O2 -Wall -o "$BIN" "$DIR/ckeys-hold.c"
fi

echo "instalando $DEST"
install -m 755 "$BIN" "$DEST"

cat > "$UNIT" <<EOF
[Unit]
Description=C-Key: helper nativo (detecta la combinacion y usa el touchpad)
After=graphical-session.target

[Service]
Type=simple
Environment=CKEYS_UID=$UID_DMS
Environment=CKEYS_GID=$GID_DMS
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
