import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Daemon de C-Key: la barra va en una ventana propia de la capa overlay,
// anclada abajo al centro, del ancho del touchpad.
Item {
    id: daemon

    property var pluginService: null
    property string pluginId: "ckeys"

    property bool isVisible: false
    property bool isPinned: false
    property double lastToggle: 0

    // Por defecto el tamano real del touchpad (100 x 58 mm), para que el
    // mapeo dedo -> tecla sea 1:1.
    property int barWidth: 495
    property int barHeight: 287
    property color barColor: "#f0f0f0"
    property color accentColor: Theme.primary
    property real panelOpacity: 0.6
    property bool showIcons: true

    function loadSettings() {
        if (!pluginService)
            return
        barWidth = Math.round(pluginService.loadPluginData(pluginId, "barWidth", 495))
        barHeight = Math.round(pluginService.loadPluginData(pluginId, "barHeight", 287))
        barColor = pluginService.loadPluginData(pluginId, "barColor", "#f0f0f0")
        accentColor = pluginService.loadPluginData(pluginId, "accentColor", Theme.primary)
        panelOpacity = pluginService.loadPluginData(pluginId, "panelOpacity", 60) / 100
        showIcons = pluginService.loadPluginData(pluginId, "showIcons", true)
    }

    Connections {
        target: pluginService
        enabled: pluginService !== null
        function onPluginDataChanged(changedId) {
            if (changedId === daemon.pluginId)
                daemon.loadSettings();
        }
    }

    // ckeys-hold corre aparte y como root (ver el README).
    readonly property string helperPidfile: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/ckeys-hold.pid"

    FileView {
        id: helperCheck
        path: daemon.helperPidfile
        blockLoading: false
        watchChanges: true
        onLoadedChanged: {
            if (helperCheck.text.trim() === "")
                daemon.warnHelper()
        }
    }

    function warnHelper() {
        ToastService.showError("C-Key",
            "El helper ckeys-hold no esta corriendo. Instalalo con sudo (ver el README) " +
            "para que el touchpad funcione.")
    }

    PanelWindow {
        id: win

        readonly property var targetScreen: CompositorService.getFocusedScreen()

        screen: targetScreen
        visible: daemon.isVisible
        color: "transparent"

        WlrLayershell.namespace: "ckeys"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            bottom: true
            left: true
        }

        // Las ventanas solo se anclan a bordes, el centrado va por margenes.
        WlrLayershell.margins {
            left: Math.max(0, Math.round((win.targetScreen?.width ?? 1920) / 2 - daemon.barWidth / 2))
            bottom: 0
        }

        implicitWidth: daemon.barWidth
        implicitHeight: daemon.barHeight

        CKeysBar {
            id: touchBar
            anchors.fill: parent
            barColor: daemon.barColor
            accentColor: daemon.accentColor
            panelOpacity: daemon.panelOpacity
            showIcons: daemon.showIcons
            pinned: daemon.isPinned
        }
    }

    IpcHandler {
        target: "ckeys"

        function toggle(): string {
            const now = Date.now()
            const doubleTap = (now - daemon.lastToggle) < 600
            daemon.lastToggle = now

            if (doubleTap) {
                daemon.isPinned = true
                daemon.isVisible = true
                return "C-Keys pinned"
            }

            if (daemon.isPinned) {
                daemon.isPinned = false
                daemon.isVisible = false
            } else {
                daemon.isVisible = !daemon.isVisible
            }
            return daemon.isVisible ? "C-Keys visible" : "C-Keys hidden"
        }

        function show(): string {
            daemon.isVisible = true
            return "C-Keys visible"
        }

        function hide(): string {
            daemon.isVisible = false
            daemon.isPinned = false
            return "C-Keys hidden"
        }

        function pin(): string {
            daemon.isPinned = true
            daemon.isVisible = true
            return "C-Keys pinned"
        }

        function unpin(): string {
            daemon.isPinned = false
            daemon.isVisible = false
            return "C-Keys unpinned"
        }

        function status(): string {
            return JSON.stringify({ visible: daemon.isVisible, pinned: daemon.isPinned })
        }

        function key(k: string): string {
            if (!k)
                return "ERROR: no key";
            Quickshell.execDetached(["wtype", "--", k]);
            return "typed " + k;
        }

        function touch(x: string, y: string): string {
            const nx = parseFloat(x);
            const ny = parseFloat(y);
            if (isNaN(nx) || isNaN(ny))
                return "ERROR: bad coordinates";
            return touchBar.handleTouch(nx, ny);
        }

        function release(): string {
            touchBar.endTouch();
            return "released";
        }

        // "x y ancho alto" de la pantalla, para que el helper sepa si es la
        // que cubre xwayland-satellite, donde puede mover el cursor exacto.
        function center(): string {
            const scr = win.targetScreen;
            if (!scr)
                return "unknown";
            return Math.round(scr.width / 2) + " " + Math.round(scr.height / 2) +
                   " " + Math.round(scr.width) + " " + Math.round(scr.height);
        }
    }
}
