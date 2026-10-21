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
        defaultValue: 503
        minimum: 320
        maximum: 700
        unit: "px"
    }

    SliderSetting {
        settingKey: "barHeight"
        label: "Bar Height"
        description: "Height of the touch bar"
        defaultValue: 150
        minimum: 100
        maximum: 260
        unit: "px"
    }

    ColorSetting {
        settingKey: "barColor"
        label: "Bar Color"
        description: "Color used by the brightness and volume bars"
        defaultValue: "#f0f0f0"
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

    SelectionSetting {
        settingKey: "shortcut"
        label: "Shortcut"
        description: "Combination that shows the panel. Only two-key combinations with Mod, free in niri. The plugin writes it to the niri config itself"
        options: [
            { label: "Mod + Space", value: "Mod+Space" },
            { label: "Mod + A", value: "Mod+A" },
            { label: "Mod + B", value: "Mod+B" },
            { label: "Mod + G", value: "Mod+G" },
            { label: "Mod + N", value: "Mod+N" },
            { label: "Mod + O", value: "Mod+O" },
            { label: "Mod + S", value: "Mod+S" },
            { label: "Mod + X", value: "Mod+X" },
            { label: "Mod + Y", value: "Mod+Y" },
            { label: "Mod + 0", value: "Mod+0" }
        ]
        defaultValue: "Mod+Space"
    }

    ToggleSetting {
        settingKey: "showIcons"
        label: "Show Icons"
        description: "Show the brightness and volume icons under the bars"
        defaultValue: true
    }
}
