import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/CalculatorEngine.js" as Engine
import "../../MacShell/Utilities.js" as Utilities

TestCase {
    id: test
    name: "Calculator"; when: windowShown
    width: 800; height: 1050; visible: true
    Component { id: stateComponent; Port.CalculatorState {} }
    Component { id: paneComponent; Port.CalculatorPane { width: 700 } }
    Component { id: spyComponent; SignalSpy { signalName: "copyRequested" } }
    function test_expressions_data() {
        return [
            {tag: "precedence", expression: "2+3*4", value: 14}, {tag: "parentheses", expression: "(2+3)*4", value: 20},
            {tag: "decimal", expression: "0.1+0.2", value: .3}, {tag: "comma", expression: "1,5+2,5", value: 4},
            {tag: "unicode", expression: "12×2−4÷2", value: 22}, {tag: "x multiply", expression: "2x3", value: 6},
            {tag: "negative power", expression: "-2^2", value: -4}, {tag: "power grouping", expression: "2^3^2", value: 512},
            {tag: "negative exponent", expression: "2^-3", value: .125}, {tag: "implicit multiplication", expression: "2(3+4)", value: 14},
            {tag: "pi", expression: "2pi", value: 2 * Math.PI}, {tag: "factorial", expression: "5!", value: 120},
            {tag: "zero factorial", expression: "0!", value: 1}, {tag: "percentage", expression: "50%", value: .5},
            {tag: "percent add", expression: "200+10%", value: 220}, {tag: "percent subtract", expression: "200-10%", value: 180},
            {tag: "percent multiply", expression: "200*10%", value: 20}, {tag: "scientific notation", expression: "1e-3*1000", value: 1},
            {tag: "sqrt", expression: "sqrt(81)", value: 9}, {tag: "log", expression: "log(1000)", value: 3},
            {tag: "ln exp", expression: "ln(exp(3))", value: 3}, {tag: "degree sine", expression: "sin(30)", value: .5},
            {tag: "degree cosine", expression: "cos(90)", value: 0}, {tag: "inverse trig", expression: "asin(0.5)", value: 30},
            {tag: "absolute", expression: "abs(-12)", value: 12}, {tag: "answer", expression: "ans*3", value: 21}
        ];
    }
    function test_expressions(data) {
        var response = Engine.evaluate(data.expression, true, 7);
        verify(response.ok, response.error); fuzzyCompare(response.value, data.value, 1e-10);
    }
    function test_invalid_expressions_data() {
        return ["1/0", "sqrt(-1)", "ln(0)", "asin(2)", "tan(90)", "1e999", "2+", "(1+2", "1 2", "5.5!", "171!", "(-1)!",
            "constructor(1)", "Math.sin(0)", "1;system()", "1**2", "1+".repeat(300), "(".repeat(70) + "1" + ")".repeat(70)]
            .map(expression => ({tag: expression.slice(0, 35), expression: expression}));
    }
    function test_invalid_expressions(data) { compare(Engine.evaluate(data.expression).ok, false); }
    function test_units_and_radians() {
        fuzzyCompare(Engine.evaluate("sin(pi/2)", false).value, 1, 1e-12);
        compare(Engine.evaluate("0.1+0.2").text, "0.3");
        compare(Engine.convert(1, "length", "mi", "m").text, "1609.344");
        compare(Engine.convert(32, "temperature", "F", "C").text, "0");
        compare(Engine.convert(100, "temperature", "C", "F").text, "212");
        compare(Engine.convert(-1, "temperature", "K", "C").ok, false);
        compare(Engine.convert(1, "data", "MiB", "B").text, "1048576");
        compare(Engine.convert(1, "data", "MB", "B").text, "1000000");
        compare(Engine.convert(1, "length", "kg", "m").ok, false);
    }
    function test_conversion_unit_changes_update_without_adding_history() {
        var state = createTemporaryObject(stateComponent, test);
        state.expression = "2"; state.mode = "convert";
        compare(state.result, "200"); compare(state.resultUnit, "cm"); compare(state.history.length, 0);
        state.to = "km"; compare(state.result, "0.002"); compare(state.resultUnit, "km"); compare(state.history.length, 0);
        state.expression = "2+"; state.preview(); compare(state.result, "—"); compare(state.resultUnit, "");
    }
    function test_state_history_recall_memory_and_result_continuation() {
        var state = createTemporaryObject(stateComponent, test);
        state.expression = "12*3"; verify(state.compute()); compare(state.result, "36"); compare(state.history.length, 1);
        state.append("+"); state.append("4"); verify(state.compute()); compare(state.result, "40");
        state.append("7"); compare(state.expression, "7"); state.memoryAction("M+"); compare(state.memory, 7);
        state.expression = "123"; state.memoryAction("MR"); compare(state.expression, "7");
        state.memoryAction("MC"); compare(state.memorySet, false);
        state.recall(state.history[1]); compare(state.expression, "12*3"); verify(state.compute());
        for (var i = 0; i < 60; i++) { state.expression = String(i); state.compute(); }
        compare(state.history.length, 50);
        var before = state.history.length; state.expression = "1/0"; compare(state.compute(), false); compare(state.history.length, before);
    }
    function test_real_buttons_keyboard_copy_modes_and_theme_data() { return [{tag: "dark", dark: true}, {tag: "light", dark: false}]; }
    function test_real_buttons_keyboard_copy_modes_and_theme(data) {
        var pane = createTemporaryObject(paneComponent, test, {foreground: data.dark ? "white" : "#1d1d1f"}); waitForRendering(pane);
        var copied = createTemporaryObject(spyComponent, test, {target: pane.controller});
        for (var key of ["1", "2", "+", "3", "="]) mouseClick(findChild(pane, "calculatorKey_" + key));
        compare(pane.controller.result, "15");
        pane.input.forceActiveFocus(); pane.input.selectAll(); keyClick(Qt.Key_8); keyClick(Qt.Key_Asterisk); keyClick(Qt.Key_9); keyClick(Qt.Key_Return);
        compare(pane.controller.result, "72");
        mouseClick(findChild(pane, "calculatorCopy")); compare(copied.count, 1); compare(copied.signalArguments[0][0], "72");
        pane.controller.mode = "convert"; pane.controller.group = "temperature"; pane.controller.from = "C"; pane.controller.to = "F";
        pane.controller.expression = "100"; pane.press("="); compare(pane.controller.result, "212");
        pane.controller.mode = "scientific"; pane.controller.clear(); pane.press("sin"); pane.press("3"); pane.press("0"); pane.press(")"); pane.press("=");
        fuzzyCompare(pane.controller.answer, .5, 1e-12);
        pane.controller.historyOpen = true; waitForRendering(pane); mouseClick(findChild(pane, "calculatorClearHistory")); compare(pane.controller.history.length, 0);
    }
    function test_utility_entries_and_window_identity_are_shared() {
        var opened = "", clock = Utilities.entry("macshell-clock.desktop", key => opened = key);
        clock.execute(); compare(opened, "clock");
        Utilities.entry("calculator", key => opened = key).execute(); compare(opened, "calculator");
        compare(Utilities.ownWindow("org.quickshell", "Calculator"), "macshell-calculator");
        compare(Utilities.ownWindow("org.quickshell", "Clock"), "macshell-clock");
        compare(Utilities.ownWindow("some.other.app", "Calculator"), "some.other.app");
        compare(Utilities.find("planned-notes"), null);
    }
}
