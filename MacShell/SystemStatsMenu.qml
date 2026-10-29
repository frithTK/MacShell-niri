import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property color accent: t ? t.accent : "#0a84ff"
    readonly property color secondSeries: dark ? "#b5a0f4" : "#7144aa"
    signal settingsRequested()
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: Language.I18n.text("ui.t_38da1505ca83"); foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; text: root.controller.stale ? Language.I18n.text("ui.t_6968b7fa682b") : Language.I18n.text("ui.t_da07b6b6e3d4"); color: root.foreground; opacity: .6; font.pixelSize: 10; width: parent.width; wrapMode: Text.Wrap }
        Repeater {
            model: ["cpu", "memory", "network", "disk"]
            delegate: Column {
                required property string modelData
                width: root.width; spacing: 4
                readonly property var s: root.controller.sample
                Text { font.family: root.font.family;
                    width: parent.width; color: root.foreground; font.pixelSize: 12
                    text: modelData === "cpu" ? Language.I18n.text("ui.t_d2732bf8d6ba") + (s.cpu === null || s.cpu === undefined ? "—" : s.cpu + "%") + (s.temperature ? " · " + s.temperature + " °C" : "")
                        : modelData === "memory" ? Language.I18n.text("ui.t_ae9a9c377357") + root.controller.gib(s.memory && s.memory.used) + " / " + root.controller.gib(s.memory && s.memory.total) + Language.I18n.text("ui.t_dfecd15931fb")
                        : modelData === "network" ? Language.I18n.text("ui.t_1583766c8f1a") + (s.interface || Language.I18n.text("ui.t_a1c30a07c33b")) + "   ↓ " + root.controller.rate(s.network && s.network[0]) + "/s   ↑ " + root.controller.rate(s.network && s.network[1]) + "/s"
                        : Language.I18n.text("ui.t_fbd0e15263c7") + (s.device || Language.I18n.text("ui.t_0c0a1e85a3ba")) + "   R " + root.controller.rate(s.disk && s.disk[0]) + "/s   W " + root.controller.rate(s.disk && s.disk[1]) + "/s"
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                }
                Row {
                    spacing: 12; visible: modelData === "disk" || modelData === "network"
                    Text { text: modelData === "disk" ? Language.I18n.text("ui.t_9b9a8d05a7ec") : Language.I18n.text("ui.t_d6eafe823591"); color: root.accent; font.family: root.font.family; font.pixelSize: 10 }
                    Text { text: modelData === "disk" ? Language.I18n.text("ui.t_3f00927a7193") : Language.I18n.text("ui.t_865e89de78d9"); color: root.secondSeries; font.family: root.font.family; font.pixelSize: 10 }
                }
                StatsGraph {
                    objectName: "statsGraph_" + modelData.toLowerCase()
                    width: parent.width; height: 34
                    history: root.controller.history; metric: modelData.toLowerCase()
                    primaryColor: root.accent; secondaryColor: root.secondSeries
                }
            }
        }
        Text { font.family: root.font.family;
            width: parent.width; wrapMode: Text.Wrap; color: root.foreground; opacity: .6; font.pixelSize: 10
            text: Language.I18n.text("ui.t_ad4e892e2ac0") + root.controller.gib(controller.sample.memory && controller.sample.memory.swapUsed) + Language.I18n.text("ui.t_f557f485913e") + root.controller.gib(controller.sample.capacity && controller.sample.capacity.free) + Language.I18n.text("ui.t_89b448364d1b") + (controller.sample.diskLabel || "") + Language.I18n.text("ui.t_6e38a9a5d6f4")
        }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: root.foreground; opacity: .6; font.pixelSize: 10; text: Object.keys(controller.sample.cores || {}).map(k => k + " " + (controller.sample.cores[k] === null ? "—" : controller.sample.cores[k] + "%")).join("   ") }
        ControlButton { text: Language.I18n.text("ui.t_5a71188bf57d"); onClicked: root.settingsRequested() }
    }
}
