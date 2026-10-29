import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import "Locale" as Language

Scope {
    id: root
    property var hub: null
    property alias state: calculatorState
    property alias window: calculatorWindow
    readonly property var translations: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    CalculatorState {
        id: calculatorState
        currency: currencyRates
        onCopyRequested: text => Quickshell.execDetached(["wl-copy", text])
    }
    property alias currencies: currencyRates
    CurrencyRates {
        id: currencyRates
        enabled: calculatorWindow.visible && root.state.mode === "convert" && root.state.group === "currency"
    }
    function open(expression) {
        if (typeof expression === "string" && expression !== "") { root.state.expression = expression; root.state.compute(); }
        calculatorWindow.show(); calculatorWindow.raise(); calculatorWindow.requestActivate();
    }
    Window {
        id: calculatorWindow; title: "Calculator"; visible: false
        width: root.state.mode === "scientific" ? 940 : root.state.mode === "convert" ? 600 : 460
        height: root.state.historyOpen ? 960 : root.state.mode === "convert" ? (root.state.group === "currency" ? 940 : 840) : 740
        minimumWidth: root.state.mode === "scientific" ? 800 : 420; minimumHeight: 620
        color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
        Rectangle {
            anchors.fill: parent; radius: 12; color: root.dark ? "#1c1c1e" : "#f2f2f7"
            border.width: 1; border.color: root.dark ? "#49494f" : "#c8c8ce"
        }
        Rectangle {
            width: parent.width; height: 44; color: root.dark ? "#2a2a2c" : "#e8e8ed"
            DragHandler { target: null; onActiveChanged: if (active) calculatorWindow.startSystemMove() }
            Row {
                x: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                Repeater {
                    model: ["#ff5f57", "#febc2e", "#28c840"]
                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        width: 14; height: 14; radius: 7; color: modelData
                        Accessible.role: Accessible.Button
                        objectName: "calculatorWindowControl_" + index
                        Accessible.name: index === 0 ? root.translations.text("calculator.close")
                            : index === 1 ? root.translations.text("calculator.minimize") : root.translations.text("calculator.maximize")
                        MouseArea {
                            anchors.fill: parent
                            onClicked: if (parent.index === 0) calculatorWindow.hide(); else if (parent.index === 1) calculatorWindow.showMinimized();
                                else if (calculatorWindow.visibility === Window.Maximized) calculatorWindow.showNormal(); else calculatorWindow.showMaximized()
                        }
                    }
                }
            }
            Text { objectName: "calculatorTitle"; anchors.centerIn: parent; text: root.translations.text("calculator.title"); textFormat: Text.PlainText; color: root.dark ? "#f5f5f7" : "#1d1d1f"; font.family: root.family; font.pixelSize: 13; font.weight: Font.DemiBold }
        }
        ScrollView {
            anchors.fill: parent; anchors.margins: 18; anchors.topMargin: 58; contentWidth: availableWidth; clip: true
            Loader {
                width: parent.width; active: calculatorWindow.visible
                sourceComponent: CalculatorPane { width: parent.width; controller: root.state; foreground: root.dark ? "#f5f5f7" : "#1d1d1f"; font.family: root.family }
            }
        }
        MouseArea { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 10; height: 10; cursorShape: Qt.SizeFDiagCursor; onPressed: calculatorWindow.startSystemResize(Qt.RightEdge | Qt.BottomEdge) }
        Shortcut { sequence: "Ctrl+W"; enabled: calculatorWindow.visible && calculatorWindow.active; onActivated: calculatorWindow.hide() }
        Shortcut { sequence: "Ctrl+Q"; enabled: calculatorWindow.visible && calculatorWindow.active; onActivated: calculatorWindow.hide() }
    }
}
