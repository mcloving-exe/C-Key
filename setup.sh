#!/bin/sh
# C-Key: instala el plugin, el helper nativo y los binds de niri.
#
#   curl -fsSL https://raw.githubusercontent.com/mcloving-exe/C-Key/main/setup.sh | sh
#
# Opciones:
#   --dry-run    solo muestra que haria, no cambia nada
#   --uninstall  deshace la instalacion
#   --no-dms     no reinicia DMS al final
#   --no-helper  no instala el helper nativo
#   --no-niri    no toca la config de niri

set -eu

RAW="https://raw.githubusercontent.com/mcloving-exe/C-Key/main"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/C-Key"
NIRI_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/niri"
NIRI_CFG="$NIRI_DIR/config.kdl"
NIRI_FRAG="$NIRI_DIR/ckeys.kdl"
HELPER_SRC="ckeys-hold.c"
HELPER_BIN="/usr/local/bin/ckeys-hold"
UNIT="/etc/systemd/system/ckeys-hold.service"
QML_FILES="plugin.json CKeysDaemon.qml CKeysBar.qml CKeysSettings.qml"

DRY=0
UNINSTALL=0
RESTART_DMS=1
DO_HELPER=1
DO_NIRI=1
TMP=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-dms) RESTART_DMS=0 ;;
        --no-helper) DO_HELPER=0 ;;
        --no-niri) DO_NIRI=0 ;;
        *) printf 'opcion desconocida: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
run() {
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if have sudo; then
        SUDO="sudo"
    else
        SUDO=""
    fi
fi

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# --------------------------------------------------------------------- desinstalar

if [ "$UNINSTALL" -eq 1 ]; then
    say "Desinstalando C-Key"

    if [ -f "$NIRI_CFG" ]; then
        if grep -q 'ckeys.kdl' "$NIRI_CFG"; then
            cp "$NIRI_CFG" "$NIRI_CFG.bak-$(date +%Y%m%d-%H%M%S)"
            if [ "$DRY" -eq 1 ]; then
                printf '  [dry-run] saco la linea include de %s\n' "$NIRI_CFG"
            else
                grep -v 'ckeys.kdl' "$NIRI_CFG" > "$NIRI_CFG.tmp"
                mv "$NIRI_CFG.tmp" "$NIRI_CFG"
                say "  saco el include de niri (backup en $NIRI_CFG.bak-*)"
            fi
        fi
    fi
    run rm -f "$NIRI_FRAG"

    if [ -f "$UNIT" ]; then
        $SUDO systemctl disable --now ckeys-hold.service 2>/dev/null || true
        $SUDO rm -f "$UNIT" "$HELPER_BIN" 2>/dev/null || true
        $SUDO systemctl daemon-reload 2>/dev/null || true
        say "  saque el servicio y el helper"
    fi

    run rm -rf "$PLUGIN_DIR"
    say "  saque el plugin de $PLUGIN_DIR"

    if [ "$RESTART_DMS" -eq 1 ] && have systemctl; then
        systemctl --user restart dms 2>/dev/null || true
    fi
    say "Listo. Para quitar del todo el atajo, revisá $NIRI_CFG"
    exit 0
fi

# --------------------------------------------------------------------- instalar

say "Instalando C-Key"

if ! have curl; then
    say "necesito curl"
    exit 1
fi

TMP="$(mktemp -d)"

# los archivos salen del repo, o de al lado del script si se corre local
SELF_DIR=""
if [ -f "./ckeys-hold.c" ]; then
    SELF_DIR="."
elif [ -n "${BASH_SOURCE:-}" ]; then
    :
fi

get() {
    name="$1"
    dest="$2"
    if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$name" ]; then
        cp "$SELF_DIR/$name" "$dest"
    else
        curl -fsSL "$RAW/$name" -o "$dest"
    fi
}

# ---- plugin QML
say "1/4 plugin"
mkdir -p "$PLUGIN_DIR"
for f in $QML_FILES; do
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] copio %s a %s\n' "$f" "$PLUGIN_DIR"
    else
        get "$f" "$TMP/$f"
        [ -s "$TMP/$f" ] || { say "  no pude descargar $f"; exit 1; }
        cp "$TMP/$f" "$PLUGIN_DIR/$f"
        if [ "$(id -u)" -eq 0 ]; then
            chown "$(stat -c %u:%g "$PLUGIN_DIR")" "$PLUGIN_DIR/$f" 2>/dev/null || true
        fi
        say "  $f"
    fi
done

# ---- helper nativo
say "2/4 helper nativo"
if [ "$DO_HELPER" -eq 0 ]; then
    say "  saltado (--no-helper)"
else
    if ! have cc && ! have gcc; then
        say "  no hay compilador de C (instala gcc o clang)"
        exit 1
    fi
    CC_BIN=cc
    have cc || CC_BIN=gcc

    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] compilo %s e instalo en %s\n' "$HELPER_SRC" "$HELPER_BIN"
    else
        get "$HELPER_SRC" "$TMP/$HELPER_SRC"
        $CC_BIN -O2 -Wall -o "$TMP/ckeys-hold" "$TMP/$HELPER_SRC"
        $SUDO install -m 755 "$TMP/ckeys-hold" "$HELPER_BIN"
        say "  $HELPER_BIN"

        if [ "$(id -u)" -eq 0 ]; then
            UID_DMS="${SUDO_UID:-}"
            if [ -z "$UID_DMS" ]; then
                UID_DMS="$(stat -c %u "$NIRI_CFG" 2>/dev/null || stat -c %u "$PLUGIN_DIR" 2>/dev/null || id -u)"
            fi
        else
            UID_DMS="$(id -u)"
        fi

        if [ -f "$UNIT" ] && ! grep -q "CKEYS_UID=$UID_DMS" "$UNIT"; then
            say "  el servicio existia con otro usuario, lo actualizo"
        fi

        {
            printf '[Unit]\n'
            printf 'Description=C-Key: helper nativo (detecta la combinacion y usa el touchpad)\n'
            printf 'After=graphical-session.target\n\n'
            printf '[Service]\n'
            printf 'Type=simple\n'
            printf 'Environment=CKEYS_UID=%s\n' "$UID_DMS"
            printf 'ExecStart=%s\n' "$HELPER_BIN"
            printf 'Restart=on-failure\n'
            printf 'RestartSec=2\n\n'
            printf '[Install]\n'
            printf 'WantedBy=multi-user.target\n'
        } | $SUDO tee "$UNIT" >/dev/null

        $SUDO systemctl daemon-reload
        $SUDO systemctl enable ckeys-hold.service >/dev/null 2>&1 || true
        $SUDO systemctl restart ckeys-hold.service
        say "  servicio ckeys-hold activo"
    fi
fi

# ---- binds de niri
say "3/4 atajo de niri"
NEED_BIND=1
NEED_CURSOR=1
if [ "$DO_NIRI" -eq 0 ]; then
    NEED_BIND=0
    NEED_CURSOR=0
    say "  saltado (--no-niri)"
elif [ -f "$NIRI_CFG" ]; then
    grep -q 'Mod+Shift+C' "$NIRI_CFG" && NEED_BIND=0
    if grep -q 'hide-when-typing true' "$NIRI_CFG"; then
        NEED_CURSOR=0
    elif grep -q 'hide-when-typing' "$NIRI_CFG"; then
        NEED_CURSOR=0
        say "  tu config tiene hide-when-typing false: cambialo a mano, el include no lo pisa"
    fi
    if [ "$NEED_BIND" -eq 0 ]; then
        say "  el atajo Mod+Shift+C ya estaba en tu config"
    fi
else
    say "  no encontre $NIRI_CFG"
fi

if [ "$NEED_BIND" -eq 0 ] && [ "$NEED_CURSOR" -eq 0 ]; then
    say "  no hace falta tocar el config de niri"
else
    if [ -f "$NIRI_CFG" ] && ! grep -q 'ckeys.kdl' "$NIRI_CFG"; then
        if [ "$DRY" -eq 1 ]; then
            printf '  [dry-run] agrego include a %s\n' "$NIRI_CFG"
        else
            cp "$NIRI_CFG" "$NIRI_CFG.bak-$(date +%Y%m%d-%H%M%S)"
            printf '\ninclude "ckeys.kdl"\n' >> "$NIRI_CFG"
            say "  agregado el include (backup en $NIRI_CFG.bak-*)"
        fi
    fi

    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] escribo %s\n' "$NIRI_FRAG"
    else
        {
            [ "$NEED_BIND" -eq 1 ] && printf 'binds {\n    Mod+Shift+C { spawn "true"; }\n}\n'
            [ "$NEED_CURSOR" -eq 1 ] && printf '\ncursor {\n    hide-when-typing true\n}\n'
        } > "$NIRI_FRAG"
        say "  $NIRI_FRAG"
    fi
fi

# ---- verificacion
say "4/4 verifico"
if [ "$DRY" -eq 0 ] && [ -f "$NIRI_CFG" ] && have niri; then
    if niri validate >/dev/null 2>&1; then
        say "  la config de niri esta bien"
    else
        say "  niri validate fallo, restauro el backup"
        for b in "$NIRI_CFG".bak-*; do
            [ -f "$b" ] || continue
            cp "$b" "$NIRI_CFG"
            say "  restaurado $b"
            break
        done
        exit 1
    fi
fi

if [ "$RESTART_DMS" -eq 1 ] && [ "$DRY" -eq 0 ] && have systemctl; then
    if systemctl --user is-active --quiet dms 2>/dev/null; then
        systemctl --user restart dms
        sleep 5
        dms ipc call plugins enable ckeys >/dev/null 2>&1 || true
        say "  reinicie DMS y habilite el plugin"
    fi
fi

say ""
say "C-Key instalado. Probá Mod+Shift+C."
say "El atajo es Mod+Shift+C y un doble toque deja la barra fija."
