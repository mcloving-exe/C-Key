import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// La barra en si: la mete el daemon dentro de su PanelWindow.
Item {
    id: bar

    property color barColor: "#f0f0f0"
    property color accentColor: Theme.primary
    property real panelOpacity: 0.6
    property bool showIcons: true
    property bool pinned: false

    property real touchX: -1
    property real touchY: -1
    property bool touchActive: false
    property string activeKey: ""

    // Las teclas van un 20% mas oscuras que el panel.
    readonly property real keyOpacity: panelOpacity * 0.8

    readonly property real brightness: DisplayService.brightnessLevel / 100
    readonly property real volume: AudioService.sink?.audio?.volume ?? 0

    Rectangle {
        id: frame
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainer, bar.panelOpacity)
        border.color: bar.pinned ? bar.accentColor : Theme.outlineVariant
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            ColumnLayout {
                Layout.preferredWidth: 30
                Layout.minimumWidth: 30
                Layout.maximumWidth: 30
                Layout.fillHeight: true
                spacing: Theme.spacingXS

                Rectangle {
                    id: brightnessTrack
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 12
                    color: Theme.withAlpha(Theme.surfaceContainerLow, bar.keyOpacity)

                    Rectangle {
                        width: parent.width
                        height: parent.height * bar.brightness
                        anchors.bottom: parent.bottom
                        radius: 12
                        color: bar.barColor
                    }

                    MouseArea {
                        anchors.fill: parent

                        function setLevel(mouse) {
                            let pct = Math.max(0, Math.min(100, Math.round((1 - mouse.y / parent.height) * 100)))
                            DisplayService.setBrightness(pct, "", true)
                        }

                        onPressed: (mouse) => setLevel(mouse)
                        onPositionChanged: (mouse) => { if (pressed) setLevel(mouse) }
                    }
                }

                DankIcon {
                    visible: bar.showIcons
                    Layout.alignment: Qt.AlignHCenter
                    name: "light_mode"
                    size: 18
                    color: Theme.surfaceVariantText
                }
            }

            ColumnLayout {
                Layout.preferredWidth: 30
                Layout.minimumWidth: 30
                Layout.maximumWidth: 30
                Layout.fillHeight: true
                spacing: Theme.spacingXS

                Rectangle {
                    id: volumeTrack
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 12
                    color: Theme.withAlpha(Theme.surfaceContainerLow, bar.keyOpacity)

                    Rectangle {
                        width: parent.width
                        height: parent.height * bar.volume
                        anchors.bottom: parent.bottom
                        radius: 12
                        color: bar.barColor
                    }

                    MouseArea {
                        anchors.fill: parent

                        function setVol(mouse) {
                            let pct = Math.max(0, Math.min(100, Math.round((1 - mouse.y / parent.height) * 100)))
                            AudioService.setVolume(pct)
                        }

                        onPressed: (mouse) => setVol(mouse)
                        onPositionChanged: (mouse) => { if (pressed) setVol(mouse) }
                    }
                }

                DankIcon {
                    visible: bar.showIcons
                    Layout.alignment: Qt.AlignHCenter
                    name: "volume_up"
                    size: 18
                    color: Theme.surfaceVariantText
                }
            }

            GridLayout {
                id: numpad
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: 4
                rowSpacing: Theme.spacingXXS
                columnSpacing: Theme.spacingXXS

                Repeater {
                    id: numpadRepeater
                    model: ["7", "8", "9", "/", "4", "5", "6", "*", "1", "2", "3", "-", "0", ".", "=", "+"]

                    delegate: Rectangle {
                        id: keyRect
                        property string keyChar: modelData

                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 28
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 7
                        color: {
                            if (bar.activeKey === keyChar)
                                return Theme.primary
                            if (keyMouse.containsMouse)
                                return Theme.withAlpha(Theme.surfaceContainerLow, Math.min(1, bar.keyOpacity + 0.15))
                            return Theme.withAlpha(Theme.surfaceContainerLow, bar.keyOpacity)
                        }

                        Text {
                            anchors.centerIn: parent
                            text: keyRect.keyChar
                            color: bar.activeKey === keyRect.keyChar ? Theme.onPrimary : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeLarge
                            font.family: "monospace"
                        }

                        MouseArea {
                            id: keyMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => bar.sendKey(keyRect.keyChar)
                        }
                    }
                }
            }
        }
    }

    function sendKey(k) {
        if (!k)
            return
        Quickshell.execDetached(["wtype", "--", k])
    }

    function handleTouch(nx, ny) {
        return bar.hitTest(nx, ny);
    }

    // Devuelve que toco: la tecla, la barra, o "nada".
    function hitTest(nx, ny) {
        let px = nx * width;
        let py = ny * height;

        let first = !bar.touchActive;
        bar.touchActive = true;
        bar.touchX = nx;
        bar.touchY = ny;

        if (first) {
            for (let i = 0; i < numpadRepeater.count; i++) {
                let it = numpadRepeater.itemAt(i);
                if (!it)
                    continue;
                let p = it.mapToItem(bar, 0, 0);
                if (px >= p.x && px < p.x + it.width && py >= p.y && py < p.y + it.height) {
                    bar.activeKey = it.keyChar;
                    bar.sendKey(it.keyChar);
                    return "tecla " + it.keyChar;
                }
            }
            bar.activeKey = "";
        }

        if (bar.inside(brightnessTrack, px, py)) {
            bar.setBrightnessAt(py);
            return "brillo";
        }
        if (bar.inside(volumeTrack, px, py)) {
            bar.setVolumeAt(py);
            return "volumen";
        }
        return "nada";
    }

    function endTouch() {
        bar.touchActive = false;
        bar.activeKey = "";
    }

    function inside(item, px, py) {
        let p = item.mapToItem(bar, 0, 0);
        return px >= p.x && px < p.x + item.width && py >= p.y && py < p.y + item.height;
    }

    function setBrightnessAt(py) {
        let p = brightnessTrack.mapToItem(bar, 0, 0);
        let pct = Math.max(0, Math.min(100, Math.round((1 - (py - p.y) / brightnessTrack.height) * 100)));
        DisplayService.setBrightness(pct, "", true);
    }

    function setVolumeAt(py) {
        let p = volumeTrack.mapToItem(bar, 0, 0);
        let pct = Math.max(0, Math.min(100, Math.round((1 - (py - p.y) / volumeTrack.height) * 100)));
        AudioService.setVolume(pct);
    }
}
