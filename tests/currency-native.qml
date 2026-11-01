property string currencyCaptured: ""
property int currencyFrames: 0
Connections { target: calculatorApp.window; function onFrameSwapped() { currencyFrames++; } }
Item {
    parent: calculatorApp.window.contentItem
    TestEvent { id: currencyEvents }
}
function currencyFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = currencyFind(child, name); if (found) return found; }
    return null;
}
function currencyButton(name) {
    var button = currencyFind(calculatorApp.window.contentItem, name);
    if (button && button.visible && button.enabled)
        currencyEvents.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
IpcHandler {
    target: "currencyProbe"
    function state(): string {
        var rates = calculatorApp.currencies, state = calculatorApp.state;
        var copy = currencyFind(calculatorApp.window.contentItem, "calculatorResult");
        return JSON.stringify({ready: macBar.settingsReady && macDock.settingsReady && macWidgets.ready,
            visible: calculatorApp.window.visible, frames: currencyFrames, width: calculatorApp.window.width, height: calculatorApp.window.height,
            enabled: rates.enabled, loading: rates.loading, available: rates.available,
            pid: rates.processId, epoch: rates.epoch, status: rates.status, error: rates.error, result: state.result, unit: state.resultUnit,
            group: state.group, mode: state.mode, from: state.from, to: state.to, date: state.currencyDate,
            details: state.currencyDetails, snapshot: rates.snapshot, history: state.history.length,
            copyEnabled: copy ? copy.enabled : false, captured: currencyCaptured});
    }
    function open(): void { calculatorApp.open(); }
    function hide(): void { calculatorApp.window.hide(); }
    function mode(name: string): void { calculatorApp.state.mode = name; }
    function group(name: string): void { calculatorApp.state.changeGroup(name); }
    function pair(from: string, to: string): void { calculatorApp.state.from = from; calculatorApp.state.to = to; }
    function amount(value: string): void { calculatorApp.state.expression = value; }
    function enterAmount(): void {
        var input = currencyFind(calculatorApp.window.contentItem, "calculatorExpression");
        if (!input) return;
        input.forceActiveFocus(); input.selectAll();
        currencyEvents.keyClick(Qt.Key_1, Qt.NoModifier, 0);
        currencyEvents.keyClick(Qt.Key_0, Qt.NoModifier, 0);
        currencyEvents.keyClick(Qt.Key_0, Qt.NoModifier, 0);
    }
    function refresh(): void { currencyButton("calculatorCurrencyRefresh"); }
    function swap(): void { currencyButton("calculatorSwap"); }
    function compute(): void { currencyButton("calculatorKey_="); }
    function resetMemory(): void { if (!calculatorApp.window.visible) calculatorApp.currencies.snapshot = ({}); }
    function stale(): void {
        calculatorApp.currencies.accept(JSON.stringify({epoch: calculatorApp.currencies.epoch - 1, type: "result", success: true,
            snapshot: {rates: {USD: 1, RUB: 999}, dates: {}, names: {}}}));
    }
    function theme(dark: bool): void { macDock.darkMode = dark; macBar.darkMode = dark; }
    function capture(path: string): void {
        calculatorApp.window.contentItem.grabToImage(result => {
            if (result.saveToFile(path)) currencyCaptured = path;
        });
    }
    function quit(): void { Qt.quit(); }
}
Timer { interval: 60000; running: true; onTriggered: { console.error("CURRENCY_NATIVE_TIMEOUT"); Qt.exit(1); } }
