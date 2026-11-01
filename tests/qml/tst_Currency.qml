import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/CurrencyData.js" as Currency

TestCase {
    id: test; name: "Currency"; when: windowShown
    width: 800; height: 1100; visible: true
    function sample(ruble) {
        return {version: 1, provider: "frankfurter-v2", fetchedAt: Date.UTC(2026, 9, 26, 12),
            rates: {USD: 1, RUB: ruble || 80, EUR: .8}, dates: {USD: "2026-10-26", RUB: "2026-10-26", EUR: "2026-10-23"},
            names: {USD: "US Dollar", RUB: "Russian Ruble", EUR: "Euro"}};
    }
    Component {
        id: providerComponent
        QtObject {
            property var snapshot: test.sample(80)
            property bool loading: false
            property string error: ""
            property string warning: ""
            property int refreshes: 0
            readonly property string status: error ? "Update failed · using saved rates" : "Daily reference rates"
            function refresh(force) { if (force) refreshes++; }
        }
    }
    Component { id: stateComponent; Port.CalculatorState {} }
    Component { id: paneComponent; Port.CalculatorPane { width: 600 } }
    function state(provider) {
        var object = createTemporaryObject(stateComponent, test, {currency: provider});
        object.mode = "convert"; object.changeGroup("currency"); return object;
    }
    function test_cross_rates_inverse_identity_and_invalid_values() {
        compare(Currency.convert(100, sample(), "USD", "RUB").text, "8000");
        compare(Currency.convert(80, sample(), "RUB", "USD").text, "1");
        compare(Currency.convert(1.25, sample(), "EUR", "RUB").text, "125");
        compare(Currency.convert(-3, sample(), "EUR", "EUR").text, "-3");
        compare(Currency.convert(0, sample(), "USD", "RUB").text, "0");
        compare(Currency.convert(1, {}, "USD", "RUB").ok, false);
        compare(Currency.convert(1, sample(), "USD", "XXX").ok, false);
        compare(Currency.convert(Infinity, sample(), "USD", "RUB").ok, false);
        var invalid = sample(); invalid.rates.RUB = true;
        compare(Currency.convert(1, invalid, "USD", "RUB").ok, false);
    }
    function test_dates_describe_actual_pair_observations() {
        compare(Currency.rateDate(sample(), "USD", "RUB"), "2026-10-26");
        compare(Currency.rateDate(sample(), "EUR", "USD"), "2026-10-23");
        compare(Currency.rateDate(sample(), "EUR", "RUB"), "2026-10-23 – 2026-10-26");
        compare(Currency.rateDate({}, "EUR", "RUB"), "");
        var units = Currency.units(sample());
        compare(units[0][0], "USD"); compare(units[1][0], "RUB"); compare(units[2][0], "EUR");
        verify(units[1][1].indexOf("RUB") === 0); verify(Currency.units({}).length > 2);
    }
    function test_inputs_pairs_and_rate_updates_recalculate_without_history_writes() {
        var provider = createTemporaryObject(providerComponent, test), object = state(provider);
        compare(object.from, "USD"); compare(object.to, "RUB");
        object.expression = "100"; compare(object.result, "8000"); compare(object.history.length, 0);
        object.from = "EUR"; compare(object.result, "10000");
        verify(object.currencyDetails.indexOf("2026-10-23 – 2026-10-26") >= 0);
        object.from = "USD"; provider.snapshot = sample(90); compare(object.result, "9000"); compare(object.history.length, 0);
        object.expression = "2+"; compare(object.result, "—"); compare(object.resultUnit, ""); verify(object.error.length > 0);
    }
    function test_currency_history_records_observation_and_recall_uses_current_rates() {
        var provider = createTemporaryObject(providerComponent, test), object = state(provider);
        object.expression = "100"; verify(object.compute());
        var entry = object.history[0]; compare(entry.result, "8000"); compare(entry.rateDate, "2026-10-26");
        provider.snapshot = sample(90); compare(object.result, "9000"); compare(object.history[0].result, "8000");
        object.changeGroup("length"); object.recall(entry);
        compare(object.group, "currency"); compare(object.result, "9000"); compare(object.history.length, 1);
    }
    function test_unavailable_rates_never_create_a_zero_quote_or_history_entry() {
        var provider = createTemporaryObject(providerComponent, test, {snapshot: {}}), object = state(provider);
        object.expression = "100"; compare(object.result, "—"); compare(object.resultUnit, "");
        compare(object.compute(), false); compare(object.history.length, 0);
        provider.snapshot = sample(); compare(object.result, "8000"); compare(object.error, "");
        provider.error = "Could not update exchange rates."; compare(object.result, "8000");
    }
    function test_rate_refresh_preserves_the_amount_when_expression_uses_previous_answer() {
        var provider = createTemporaryObject(providerComponent, test);
        var object = createTemporaryObject(stateComponent, test, {currency: provider});
        object.expression = "7"; verify(object.compute()); compare(object.answer, 7);
        object.mode = "convert"; object.changeGroup("currency"); object.expression = "ans*2";
        verify(object.compute()); compare(object.result, "1120");
        provider.snapshot = sample(90); compare(object.result, "1260"); compare(object.conversionInput, 14);
        object.to = "EUR"; compare(object.result, "11.2"); compare(object.conversionInput, 14);
    }
    function test_currency_controls_keyboard_refresh_swap_and_saved_status_data() { return [{tag: "dark", foreground: "white"}, {tag: "light", foreground: "#1d1d1f"}]; }
    function test_currency_controls_keyboard_refresh_swap_and_saved_status(data) {
        var provider = createTemporaryObject(providerComponent, test);
        var pane = createTemporaryObject(paneComponent, test, {foreground: data.foreground});
        pane.controller.currency = provider; pane.controller.mode = "convert";
        waitForRendering(pane); wait(20);
        var group = findChild(pane, "calculatorGroup");
        group.forceActiveFocus(); tryVerify(() => group.activeFocus);
        keyClick(Qt.Key_Space); tryCompare(group.popup, "visible", true); wait(150); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        tryCompare(group.popup, "visible", false); wait(150); waitForRendering(pane);
        compare(pane.controller.group, "currency");
        pane.input.forceActiveFocus(); keyClick(Qt.Key_1); keyClick(Qt.Key_0); keyClick(Qt.Key_0);
        compare(pane.controller.result, "8000");
        mouseClick(findChild(pane, "calculatorCurrencyRefresh")); compare(provider.refreshes, 1);
        provider.loading = true; compare(findChild(pane, "calculatorCurrencyRefresh").enabled, false); provider.loading = false;
        mouseClick(findChild(pane, "calculatorSwap")); compare(pane.controller.from, "RUB"); compare(pane.controller.to, "USD"); compare(pane.controller.result, "1.25");
        provider.error = "Offline for test";
        verify(findChild(pane, "calculatorCurrencyStatus").text.indexOf("saved rates") >= 0);
        compare(findChild(pane, "calculatorCurrencyError").visible, true);
        var missing = sample(); delete missing.rates.RUB;
        provider.snapshot = missing;
        compare(findChild(pane, "calculatorFrom").currentIndex, -1);
        compare(findChild(pane, "calculatorFrom").displayText, "RUB");
        compare(pane.controller.result, "—"); compare(findChild(pane, "calculatorResult").enabled, false);
    }
}
