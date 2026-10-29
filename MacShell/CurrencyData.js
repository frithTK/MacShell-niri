.pragma library
.import "CalculatorEngine.js" as Engine

var common = [["USD", "US Dollar"], ["RUB", "Russian Ruble"], ["EUR", "Euro"], ["GBP", "Pound Sterling"],
    ["CNY", "Chinese Yuan"], ["JPY", "Japanese Yen"], ["CHF", "Swiss Franc"], ["KZT", "Kazakhstani Tenge"],
    ["BYN", "Belarusian Ruble"], ["TRY", "Turkish Lira"], ["AED", "UAE Dirham"]];
function units(snapshot) {
    var codes = Object.keys(snapshot.rates || {}), names = snapshot.names || {};
    if (!codes.length) return common.map(row => [row[0], row[0] + " · " + row[1]]);
    var priority = common.map(row => row[0]);
    codes.sort((a, b) => {
        var ai = priority.indexOf(a), bi = priority.indexOf(b);
        if (ai >= 0 || bi >= 0) return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi);
        return a.localeCompare(b);
    });
    return codes.map(code => [code, code + " · " + (names[code] || code)]);
}
function convert(value, snapshot, from, to) {
    var rates = snapshot.rates || {}, a = rates[from], b = rates[to];
    if (!Object.keys(rates).length) return {ok: false, error: "Exchange rates have not loaded yet"};
    if (!(typeof a === "number" && isFinite(a) && a > 0 && typeof b === "number" && isFinite(b) && b > 0))
        return {ok: false, error: "No published rate for the selected currency"};
    var result = value / a * b;
    try { return {ok: true, value: result, text: Engine.format(result), error: ""}; }
    catch (error) { return {ok: false, error: error.message}; }
}
function rateDate(snapshot, from, to) {
    var dates = snapshot.dates || {}, a = dates[from], b = dates[to];
    // USD is the common calculation anchor; its own observation is not needed for a USD pair.
    if (from === "USD") return b || "";
    if (to === "USD") return a || "";
    if (!a || !b) return "";
    return a === b ? a : [a, b].sort().join(" – ");
}
