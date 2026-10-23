import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "ckeys"

    SliderSetting {
        settingKey: "barWidth"
        label: "Bar Width"
        description: "Width of the touch bar. The default matches the real touchpad width"
        defaultValue: 495
        minimum: 320
        maximum: 700
        unit: "px"
    }

    SliderSetting {
        settingKey: "barHeight"
        label: "Bar Height"
        description: "Height of the touch bar. The default matches the real touchpad height"
        defaultValue: 287
        minimum: 100
        maximum: 400
        unit: "px"
    }

    ColorSetting {
        settingKey: "barColor"
        label: "Bar Color"
        description: "Color used by the brightness and volume bars"
        defaultValue: Theme.surfaceText
    }

    ColorSetting {
        settingKey: "accentColor"
        label: "Accent Color"
        description: "Highlight color when the panel is pinned"
        defaultValue: Theme.primary
    }

    SliderSetting {
        settingKey: "panelOpacity"
        label: "Panel Opacity"
        description: "How transparent the panel is"
        defaultValue: 60
        minimum: 20
        maximum: 100
        unit: "%"
    }

    ToggleSetting {
        settingKey: "showIcons"
        label: "Show Icons"
        description: "Show the brightness and volume icons under the bars"
        defaultValue: true
    }
}
