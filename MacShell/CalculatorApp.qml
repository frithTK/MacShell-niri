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
        AppTitlebar {
            id: titlebar; x: 1; width: parent.width - 2
            window: calculatorWindow; dark: root.dark; family: root.family; title: root.translations.text("calculator.title")
            titleObjectName: "calculatorTitle"
            controlObjectPrefix: "calculatorWindowControl_"
            closeLabel: root.translations.text("calculator.close"); minimizeLabel: root.translations.text("calculator.minimize"); maximizeLabel: root.translations.text("calculator.maximize")
            onCloseRequested: calculatorWindow.hide()
        }
        ScrollView {
            anchors.fill: parent; anchors.margins: 18; anchors.topMargin: titlebar.height + 14; contentWidth: availableWidth; clip: true
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
