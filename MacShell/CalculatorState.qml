import QtQuick
import "Locale" as Language
import "CalculatorEngine.js" as Engine
import "CurrencyData.js" as Currency

QtObject {
    id: root
    property string expression: ""
    property string result: "0"
    property string resultUnit: ""
    property real answer: 0
    property real memory: 0
    property bool memorySet: false
    property string error: ""
    property string mode: "basic"
    property bool degrees: true
    property bool historyOpen: false
    property var history: []
    property string group: "length"
    property string from: "m"
    property string to: "cm"
    property bool evaluated: false
    property bool hasConversionInput: false
    property real conversionInput: 0
    property var currency: null
    readonly property var currencySnapshot: currency ? currency.snapshot : ({})
    readonly property var groups: Engine.groups.map(item => Object.assign({}, item, {label: Language.I18n.legacy(item.label)})).concat([{key: "currency", label: Language.I18n.text("ui.t_3ac1a9ec4fa7")}])
    readonly property var units: group === "currency" ? Currency.units(currencySnapshot).map(unit => {
        var common = Currency.common.find(item => item[0] === unit[0]);
        return [unit[0], unit[0] + " · " + Language.I18n.currencyName(unit[0], currencySnapshot.names && currencySnapshot.names[unit[0]] || (common ? common[1] : unit[0]))];
    })
        : (Engine.groups.find(item => item.key === group) || Engine.groups[0]).units
    readonly property string currencyDate: Currency.rateDate(currencySnapshot, from, to)
    readonly property string currencyDetails: {
        var response = Currency.convert(1, currencySnapshot, from, to);
        if (!response.ok) return "";
        var checked = currencySnapshot.fetchedAt ? Language.I18n.formatDateTime(new Date(currencySnapshot.fetchedAt), "yyyy-MM-dd HH:mm") : "—";
        return Language.I18n.text("currency.details", {from: from, to: to, rate: response.text.replace(".", Language.I18n.formatLocale.decimalPoint), date: currencyDate, checked: checked});
    }
    signal copyRequested(string text)
    function append(value) {
        if (expression.length + value.length > 512) return;
        if (evaluated) { expression = /^[+*/^%!-]|^[×÷−]$/.test(value) ? result : ""; evaluated = false; }
        expression += value; error = "";
    }
    onFromChanged: if (mode === "convert") preview()
    onToChanged: if (mode === "convert") preview()
    onGroupChanged: if (mode === "convert") preview()
    onExpressionChanged: { hasConversionInput = false; if (mode === "convert") preview(); }
    onCurrencySnapshotChanged: if (mode === "convert" && group === "currency") preview()
    onModeChanged: { hasConversionInput = false; if (mode === "convert") preview(); else resultUnit = ""; }
    function clear() { expression = ""; result = "0"; resultUnit = ""; error = ""; evaluated = false; }
    function backspace() { expression = expression.slice(0, -1); error = ""; evaluated = false; }
    function negate() { expression = expression ? "-(" + expression + ")" : "-"; evaluated = false; error = ""; }
    function convertValue(value) { return group === "currency" ? Currency.convert(value, currencySnapshot, from, to) : Engine.convert(value, group, from, to); }
    function compute() {
        var response = Engine.evaluate(expression, degrees, answer);
        if (response.ok && mode === "convert") {
            conversionInput = response.value; hasConversionInput = true;
            response = convertValue(response.value);
        }
        if (!response.ok) { error = response.error; return false; }
        answer = response.value; result = response.text; resultUnit = mode === "convert" ? to : ""; error = ""; evaluated = true;
        var entry = {expression: expression, result: result, mode: mode, degrees: degrees, group: group, from: from, to: to};
        if (mode === "convert" && group === "currency") entry.rateDate = currencyDate;
        if (!history.length || JSON.stringify(history[0]) !== JSON.stringify(entry)) history = [entry].concat(history).slice(0, 50);
        return true;
    }
    function preview() {
        var response = hasConversionInput ? {ok: true, value: conversionInput} : Engine.evaluate(expression, degrees, answer);
        if (response.ok) {
            conversionInput = response.value; hasConversionInput = true;
            response = convertValue(response.value);
        }
        result = response.ok ? response.text : "—"; resultUnit = response.ok ? to : "";
        error = response.ok || !expression.trim() || group === "currency" && !Object.keys(currencySnapshot.rates || {}).length ? "" : response.error;
    }
    function recall(entry) {
        hasConversionInput = false;
        mode = entry.mode; degrees = entry.degrees; group = entry.group; from = entry.from; to = entry.to;
        expression = entry.expression; result = entry.result; resultUnit = entry.mode === "convert" ? entry.to : ""; evaluated = false; error = "";
        if (entry.mode === "convert" && entry.group === "currency") preview();
    }
    function changeGroup(key) {
        group = key;
        from = key === "currency" ? "USD" : units[0][0];
        to = key === "currency" ? "RUB" : units[Math.min(1, units.length - 1)][0];
        error = ""; evaluated = false;
        if (mode === "convert") preview();
    }
    function memoryAction(action) {
        var response = evaluated ? (mode === "convert" && hasConversionInput ? convertValue(conversionInput) : {ok: true, value: answer})
            : Engine.evaluate(expression || "0", degrees, answer);
        if (action === "MC") { memory = 0; memorySet = false; return; }
        if (action === "MR") { expression = Engine.format(memory); evaluated = false; error = ""; if (mode === "convert") preview(); return; }
        if (!response.ok) { error = response.error; return; }
        var next = memory + (action === "M−" ? -1 : 1) * response.value;
        if (!isFinite(next)) { error = "Memory value is outside the supported range"; return; }
        memory = next; memorySet = true;
    }
}
