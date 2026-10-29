import QtQuick
import "Locale" as Language
import QtQuick.Controls
import QtQuick.Layouts
import "CalculatorEngine.js" as Engine

ControlMenu {
    id: root
    property var controller: internalState
    CalculatorState { id: internalState }
    property alias input: expressionInput
    function displayNumber(value) { return String(value).replace(".", Language.I18n.formatLocale.decimalPoint); }
    readonly property string displayResult: displayNumber(controller.result)
    component CalculatorButton: ControlButton {
        id: button
        property int labelSize: 16
        implicitHeight: 40
        font.pixelSize: labelSize
        contentItem: Text {
            text: button.text; textFormat: Text.PlainText
            color: button.primary ? "white" : button.palette.buttonText
            opacity: button.enabled ? 1 : .45
            font: button.font; elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
    }
    readonly property color operationColor: dark ? "#ff9f0a" : "#c56d00"
    readonly property var functionKeys: ["(", ")", "π", "e", "x²", "xʸ", "√", "!", "sin", "cos", "tan", "1/x", "asin", "acos", "atan", "abs", "ln", "log", "eˣ", "Ans", "MC", "MR", "M+", "M−"]
    readonly property var basicKeys: ["AC", "±", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "−", "1", "2", "3", "+", "0", ".", "⌫", "="]
    signal focusRequested()
    function press(key) {
        if (key === "=") controller.compute();
        else if (key === "AC") controller.clear();
        else if (key === "⌫") controller.backspace();
        else if (key === "±") controller.negate();
        else if (["MC", "MR", "M+", "M−"].indexOf(key) >= 0) controller.memoryAction(key);
        else if (key === "x²") controller.append("^2");
        else if (key === "xʸ") controller.append("^");
        else if (key === "1/x") { controller.expression = "1/(" + (controller.expression || "0") + ")"; controller.evaluated = false; }
        else if (key === "√") controller.append("sqrt(");
        else if (key === "eˣ") controller.append("exp(");
        else if (key === "Ans") controller.append("ans");
        else if (["sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "abs"].indexOf(key) >= 0) controller.append(key + "(");
        else controller.append(key);
        expressionInput.forceActiveFocus(); expressionInput.cursorPosition = expressionInput.text.length;
    }
    contentItem: Column {
        spacing: 14
        RowLayout {
            width: parent.width; spacing: 8
            ControlComboBox {
                objectName: "calculatorMode"; Layout.preferredWidth: 170; implicitHeight: 42; font.pixelSize: 16
                model: [Language.I18n.text("ui.t_0e35f6e9742e"), Language.I18n.text("ui.t_3aa5abc76f0e"), Language.I18n.text("ui.t_5cd425f518c2")]; currentIndex: ["basic", "scientific", "convert"].indexOf(root.controller.mode)
                Accessible.name: Language.I18n.text("ui.t_678583304289")
                onActivated: index => { root.controller.mode = ["basic", "scientific", "convert"][index]; root.controller.error = ""; root.controller.evaluated = false; }
            }
            CalculatorButton { objectName: "calculatorAngle"; visible: root.controller.mode === "scientific"; text: root.controller.degrees ? Language.I18n.text("ui.t_ae05bdfb1183") : Language.I18n.text("ui.t_aaa6cab49ca4"); onClicked: root.controller.degrees = !root.controller.degrees }
            Item { Layout.fillWidth: true; height: 1 }
            CalculatorButton { id: historyButton; objectName: "calculatorHistory"; text: Language.I18n.text("ui.t_0e7696009337"); onClicked: root.controller.historyOpen = !root.controller.historyOpen }
        }
        TextField {
            id: expressionInput; objectName: "calculatorExpression"; width: parent.width; height: 70
            text: root.controller.expression; selectByMouse: true; maximumLength: 512
            color: root.foreground; font.family: root.font.family; font.pixelSize: 32
            horizontalAlignment: TextInput.AlignRight; placeholderText: "0"
            Accessible.name: Language.I18n.text("ui.t_4fdfec4153af")
            onTextEdited: { root.controller.evaluated = false; root.controller.expression = text; if (root.controller.mode !== "convert") root.controller.error = ""; }
            onAccepted: root.press("=")
            Keys.onEscapePressed: root.press("AC")
            background: Rectangle { radius: 10; color: root.dark ? "#2c2c30" : "#ffffff"; border.color: expressionInput.activeFocus ? root.palette.highlight : root.separator }
        }
        Row {
            width: parent.width; spacing: 8
            Text {
                objectName: "calculatorResult"; width: parent.width - copyButton.width - 8; height: 68
                text: root.displayResult + (root.controller.resultUnit ? " " + root.controller.resultUnit : "")
                color: root.foreground; font.family: root.font.family; font.pixelSize: 48; font.weight: Font.Normal
                horizontalAlignment: Text.AlignRight; verticalAlignment: Text.AlignVCenter
                fontSizeMode: Text.Fit; minimumPixelSize: 18; textFormat: Text.PlainText
                Accessible.name: Language.I18n.text("ui.t_69b87fffe7a4") + text
            }
            CalculatorButton { id: copyButton; objectName: "calculatorCopy"; text: Language.I18n.text("ui.t_e21f935f11d7"); enabled: root.controller.result !== "—" && root.controller.error === ""; anchors.verticalCenter: parent.verticalCenter; onClicked: root.controller.copyRequested(root.displayResult) }
        }
        Text { objectName: "calculatorError"; width: parent.width; visible: text !== ""; text: Language.I18n.legacy(root.controller.error); textFormat: Text.PlainText; color: root.warning; font.family: root.font.family; font.pixelSize: 15; wrapMode: Text.Wrap }
        Column {
            width: parent.width; spacing: 8; visible: root.controller.mode === "convert"
            ControlComboBox {
                objectName: "calculatorGroup"; width: parent.width; implicitHeight: 42; font.pixelSize: 16; model: root.controller.groups; textRole: "label"
                currentIndex: Math.max(0, model.findIndex(item => item.key === root.controller.group)); Accessible.name: Language.I18n.text("ui.t_f87cfaa6b853")
                onActivated: index => root.controller.changeGroup(model[index].key)
            }
            Row {
                width: parent.width; spacing: 8
                ControlComboBox {
                    objectName: "calculatorFrom"; width: (parent.width - 16 - swapButton.width) / 2; implicitHeight: 42; font.pixelSize: 16
                    model: root.controller.units.map(unit => ({key: unit[0], label: Language.I18n.legacy(unit[1])})); textRole: "label"
                    currentIndex: model.findIndex(item => item.key === root.controller.from)
                    displayText: currentIndex >= 0 ? currentText : root.controller.from
                    Accessible.name: Language.I18n.text("ui.t_2ba32c1fa725")
                    onActivated: index => { root.controller.from = model[index].key; root.controller.evaluated = false; }
                }
                CalculatorButton { id: swapButton; objectName: "calculatorSwap"; implicitWidth: 60; labelSize: 24; text: "⇄"; Accessible.name: Language.I18n.text("ui.t_5a846416c00c"); onClicked: { var from = root.controller.from; root.controller.from = root.controller.to; root.controller.to = from; root.controller.evaluated = false; } }
                ControlComboBox {
                    objectName: "calculatorTo"; width: (parent.width - 16 - swapButton.width) / 2; implicitHeight: 42; font.pixelSize: 16
                    model: root.controller.units.map(unit => ({key: unit[0], label: Language.I18n.legacy(unit[1])})); textRole: "label"
                    currentIndex: model.findIndex(item => item.key === root.controller.to)
                    displayText: currentIndex >= 0 ? currentText : root.controller.to
                    Accessible.name: Language.I18n.text("ui.t_26440f0d851c")
                    onActivated: index => { root.controller.to = model[index].key; root.controller.evaluated = false; }
                }
            }
            Column {
                width: parent.width; spacing: 4; visible: root.controller.group === "currency"
                RowLayout {
                    width: parent.width; spacing: 12
                    Text {
                        objectName: "calculatorCurrencyStatus"; Layout.fillWidth: true
                        text: "<a style='color:" + (root.dark ? "#4da3ff" : "#0066cc") + "' href='https://frankfurter.dev/'>Frankfurter</a> · "
                            + (root.controller.currency ? root.controller.currency.status : Language.I18n.text("ui.t_12ccf0382fab"))
                        textFormat: Text.RichText
                        color: root.secondary; font.family: root.font.family; font.pixelSize: 14; wrapMode: Text.Wrap
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                    CalculatorButton {
                        objectName: "calculatorCurrencyRefresh"; text: Language.I18n.text("ui.t_0e9161011702")
                        enabled: !!root.controller.currency && !root.controller.currency.loading
                        onClicked: root.controller.currency.refresh(true)
                    }
                }
                Text {
                    objectName: "calculatorCurrencyDetails"; width: parent.width; text: root.controller.currencyDetails
                    textFormat: Text.PlainText; color: root.secondary; font.family: root.font.family; font.pixelSize: 14; wrapMode: Text.Wrap
                    visible: text !== ""
                }
                Text {
                    objectName: "calculatorCurrencyError"; width: parent.width
                    text: root.controller.currency ? root.controller.currency.error || root.controller.currency.warning : ""
                    textFormat: Text.PlainText; color: root.warning; font.family: root.font.family; font.pixelSize: 14; wrapMode: Text.Wrap
                    visible: text !== ""
                }
            }
        }
        Row {
            width: parent.width; spacing: 16
            Grid {
                id: scientificGrid; visible: root.controller.mode === "scientific"; columns: 4; spacing: 8
                width: visible ? (parent.width - 16) * .48 : 0
                Repeater {
                    model: root.functionKeys
                    delegate: CalculatorButton {
                        required property string modelData
                        objectName: "calculatorFunction_" + modelData
                        width: (scientificGrid.width - 24) / 4; height: 60; labelSize: 20
                        text: modelData; onClicked: root.press(modelData)
                    }
                }
            }
            Grid {
                id: basicGrid; columns: 4; spacing: 8
                width: parent.width - (scientificGrid.visible ? scientificGrid.width + 16 : 0)
                Repeater {
                    model: root.basicKeys
                    delegate: CalculatorButton {
                        required property string modelData
                        objectName: "calculatorKey_" + modelData
                        width: (basicGrid.width - 24) / 4; height: 72; labelSize: modelData === "AC" ? 24 : 32
                        text: modelData; primary: ["÷", "×", "−", "+", "="].indexOf(modelData) >= 0
                        palette.highlight: root.operationColor
                        Accessible.name: modelData === "±" ? Language.I18n.text("ui.t_973d9d3d2f93") : modelData === "⌫" ? Language.I18n.text("ui.t_292fffe328d0") : modelData
                        onClicked: root.press(modelData)
                    }
                }
            }
        }
        Column {
            width: parent.width; visible: root.controller.historyOpen; spacing: 8
            Row {
                width: parent.width; spacing: 8
                Text { width: parent.width - clearHistory.width - 8; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_4fe784d1a4f7"); color: root.secondary; font.family: root.font.family; font.pixelSize: 15 }
                CalculatorButton { id: clearHistory; objectName: "calculatorClearHistory"; text: Language.I18n.text("ui.t_83b12c2216ef"); enabled: root.controller.history.length > 0; onClicked: root.controller.history = [] }
            }
            ScrollView {
                width: parent.width; height: Math.min(190, historyColumn.implicitHeight); contentWidth: availableWidth; clip: true
                Column {
                    id: historyColumn; width: parent.width; spacing: 4
                    Repeater {
                        model: root.controller.history
                        delegate: CalculatorButton {
                            required property var modelData
                            required property int index
                            objectName: "calculatorHistoryEntry_" + index
                            width: historyColumn.width
                            text: modelData.expression + (modelData.group === "currency" && modelData.mode === "convert" ? " " + modelData.from : "")
                                + " = " + root.displayNumber(modelData.result) + (modelData.mode === "convert" ? " " + modelData.to : "")
                                + (modelData.rateDate ? " · " + modelData.rateDate : "")
                            onClicked: root.controller.recall(modelData)
                        }
                    }
                }
            }
        }
        Text { objectName: "calculatorMemory"; visible: root.controller.memorySet; text: "M = " + root.displayNumber(Engine.format(root.controller.memory)); color: root.secondary; font.family: root.font.family; font.pixelSize: 15 }
    }
    Shortcut { sequence: "Ctrl+L"; onActivated: { expressionInput.forceActiveFocus(); expressionInput.selectAll(); } }
    Shortcut { sequence: "Ctrl+H"; onActivated: root.controller.historyOpen = !root.controller.historyOpen }
    Shortcut { sequence: "Ctrl+C"; enabled: copyButton.enabled && expressionInput.selectedText === ""; onActivated: root.controller.copyRequested(root.controller.result) }
    Component.onCompleted: Qt.callLater(() => expressionInput.forceActiveFocus())
}
