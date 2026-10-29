import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/Locale" as Language
import "../../MacShell/BatteryState.js" as Battery
import "../../MacShell/Utilities.js" as Utilities

TestCase {
    id: test
    name: "SystemLanguage"
    when: windowShown
    width: 800; height: 1500; visible: true
    property string previousLanguage: ""
    property string previousRegion: ""
    function init() {
        previousLanguage = Language.I18n.language; previousRegion = Language.I18n.region;
        Language.I18n.language = "en"; Language.I18n.region = "en_US";
    }
    function cleanup() { Language.I18n.language = previousLanguage; Language.I18n.region = previousRegion; }
    Component { id: calculatorComponent; Port.CalculatorPane { width: 700 } }
    Component { id: languageComponent; Port.LanguageSettings { width: 650 } }
    Component { id: activityComponent; Port.ActivityPreferencesEditor { width: 650 } }
    Component { id: statsComponent; Port.SystemStatsMenu { width: 350 } }
    Component { id: spyComponent; SignalSpy { signalName: "copyRequested" } }
    Component {
        id: backendComponent
        QtObject {
            property bool ready: true
            property bool pending: false
            property bool readOnly: false
            property bool canRecover: false
            property bool needsRepair: false
            property bool migrationPending: false
            property string token: "first"
            property string error: ""
            property string notice: ""
            property string conflict: ""
            property string errorCode: ""
            property string errorDetail: ""
            property var missing: []
            property var locales: ["C", "en_GB.utf8", "en_US.utf8", "ru_RU.utf8"]
            property var values: ({ui: "system", session: "system", region: "system"})
            property var fields: [
                {key: "cpuWarning", label: "CPU warning", description: "Load at which the CPU icon turns amber", type: "integer", default: 65, minimum: 0, maximum: 99, lessThan: "cpuCritical"},
                {key: "cpuCritical", label: "CPU critical", description: "Load at which the CPU icon turns red", type: "integer", default: 90, minimum: 1, maximum: 100}
            ]
            signal finished(bool success)
            function refresh() {}
            function save(values, token) {}
        }
    }
    QtObject {
        id: readings
        property var sample: ({cpu: 24, memory: {used: 8589934592, total: 17179869184}, network: [1000, 2000], disk: [3000, 4000]})
        property var history: []
        property bool stale: false
        function gib(value) { return (value / 1073741824).toFixed(1); }
        function rate(value) { return value + "B"; }
    }
    function test_system_selection_and_language_change_preserve_draft() {
        var controller = createTemporaryObject(backendComponent, test), pane = createTemporaryObject(languageComponent, test, {controller: controller});
        pane.chooseLanguage("en"); compare(pane.draft.session, "en_US.utf8");
        pane.chooseLanguage("ru"); compare(pane.draft.ui, "ru"); compare(pane.draft.session, "ru_RU.utf8");
        pane.setValue("region", "en_GB.utf8");
        Language.I18n.language = "ru";
        compare(findChild(pane, "languageApply").text, "Применить");
        compare(pane.draft.region, "en_GB.utf8"); compare(pane.draftToken, "first"); verify(pane.dirty);
        controller.values = {ui: "en", session: "en_US.utf8", region: "system"}; controller.token = "second";
        compare(pane.draft.ui, "ru"); compare(pane.draftToken, "first");
    }
    function test_activity_draft_and_input_survive_language_change() {
        var controller = createTemporaryObject(backendComponent, test, {values: {cpuWarning: 65, cpuCritical: 90}});
        var pane = createTemporaryObject(activityComponent, test, {controller: controller});
        pane.change("cpuWarning", 72);
        var input = findChild(pane, "activityThreshold_cpuWarning"); verify(input);
        Language.I18n.language = "ru";
        compare(pane.draft.cpuWarning, 72); compare(pane.baseToken, "first"); verify(pane.dirty);
        compare(findChild(pane, "activityThreshold_cpuWarning"), input);
        compare(input.Accessible.name, "Предупреждение ЦП");
        Language.I18n.language = "en";
        compare(pane.draft.cpuWarning, 72); compare(input.Accessible.name, "CPU warning");
    }
    function test_calculator_formats_copy_and_retained_input() {
        var pane = createTemporaryObject(calculatorComponent, test), copied = createTemporaryObject(spyComponent, test, {target: pane.controller});
        pane.controller.expression = "12.5/2"; pane.press("="); pane.controller.memoryAction("M+");
        var input = pane.input; input.select(1, 4);
        Language.I18n.language = "ru"; Language.I18n.region = "ru_RU";
        compare(pane.controller.result, "6.25"); compare(pane.displayResult, "6,25");
        compare(pane.controller.history.length, 1); compare(pane.controller.memory, 6.25);
        pane.controller.historyOpen = true;
        compare(findChild(pane, "calculatorMemory").text, "M = 6,25");
        verify(findChild(pane, "calculatorHistoryEntry_0").text.includes(" = 6,25"));
        compare(pane.input, input); compare(input.selectionStart, 1); compare(input.selectionEnd, 4);
        mouseClick(findChild(pane, "calculatorCopy")); compare(copied.signalArguments[0][0], "6,25");
        pane.controller.mode = "convert"; pane.controller.changeGroup("length");
        verify(pane.controller.groups.some(item => item.label === "Длина"));
        verify(findChild(pane, "calculatorFrom").model.some(item => item.label === "Метры"));
    }
    function test_graph_metrics_are_independent_of_translated_labels() {
        Language.I18n.language = "ru";
        var pane = createTemporaryObject(statsComponent, test, {controller: readings});
        for (var key of ["cpu", "memory", "network", "disk"]) {
            var graph = findChild(pane, "statsGraph_" + key); verify(graph, key); compare(graph.metric, key);
        }
    }
    function test_context_and_cldr_names() {
        Language.I18n.language = "ru";
        compare(Language.I18n.legacy("Clear"), "Очистить"); compare(Language.I18n.weatherCondition("Clear"), "Ясно");
        compare(Language.I18n.text("audio.volume"), "Громкость"); compare(Language.I18n.legacy("Volume"), "Объём");
        compare(Language.I18n.cityName("Asia/Dubai", "Abu Dhabi"), "Абу-Даби");
        compare(Language.I18n.cityName("America/Los_Angeles", "Cupertino"), "Купертино");
        compare(Language.I18n.cityName("Asia/Shanghai", "Beijing"), "Пекин");
        function tr(value) { return Language.I18n.legacy(value); }
        compare(Utilities.displayTitle("org.quickshell", "Calculator", tr), "Калькулятор");
        compare(Utilities.displayTitle("org.example.browser", "Calculator", tr), "Calculator");
        compare(Utilities.windowId("Calculator"), "macshell-calculator");
        verify(Language.I18n.currencyName("USD", "US Dollar").includes("доллар"));
        verify(/[а-яё]/i.test(Language.I18n.emojiName("🐈", "cat")));
        Language.I18n.language = "en";
        compare(Language.I18n.cityName("Asia/Dubai", "Abu Dhabi"), "Abu Dhabi");
        compare(Language.I18n.legacy("Неверный пароль"), "Incorrect password");
    }
    function test_battery_duration_is_translated_without_changing_its_value() {
        Language.I18n.language = "ru";
        function tr(key, args) { return Language.I18n.text(key, args); }
        compare(Battery.remaining(true, 2, 5400, 0, true, tr), "Осталось около 1 ч 30 мин");
        compare(Battery.remaining(true, 1, 0, 1800, false, tr), "Около 30 мин до полного заряда");
        compare(Language.I18n.plural("notifications.more", 21), "Ещё 21 уведомление");
        compare(Language.I18n.plural("devices.more", 5), "Ещё 5 устройств");
    }
}
