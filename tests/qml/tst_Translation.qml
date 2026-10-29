import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/Locale/TranslationCatalog.js" as Catalog
import "../../MacShell/Locale/TranslationEngine.js" as Engine

TestCase {
    id: test
    name: "Translation"
    when: windowShown
    Component { id: serviceComponent; Port.TranslationService { language: "en"; region: "en_US" } }
    Component {
        id: labelComponent
        Text { required property var i18n; text: i18n.text("language.title"); textFormat: Text.PlainText }
    }
    function service(values) { return createTemporaryObject(serviceComponent, test, values || {}); }
    function test_system_language_data() {
        return [
            {tag: "Russian regional", selection: "ru-RU", languages: [], expected: "ru"},
            {tag: "POSIX Russian", selection: "ru_RU.UTF-8", languages: [], expected: "ru"},
            {tag: "English regional", selection: "en_GB", languages: [], expected: "en"},
            {tag: "unknown explicit", selection: "de_DE", languages: ["ru_RU"], expected: "en"},
            {tag: "system priority", selection: "system", languages: ["en-GB", "ru-RU"], expected: "en"},
            {tag: "first supported", selection: "system", languages: ["fr-FR", "ru-RU", "en-US"], expected: "ru"},
            {tag: "C", selection: "system", languages: ["C"], expected: "en"},
            {tag: "POSIX", selection: "system", languages: ["POSIX"], expected: "en"},
            {tag: "empty", selection: "system", languages: [], expected: "en"}
        ];
    }
    function test_system_language(data) {
        var i18n = service({language: data.selection, systemLanguages: data.languages});
        compare(i18n.activeLanguage, data.expected);
    }
    function test_reactive_language_and_independent_region() {
        var i18n = service(), label = createTemporaryObject(labelComponent, test, {i18n: i18n});
        compare(label.text, "Language & Region");
        compare(i18n.formatNumber(1234.5, 2), "1,234.50");
        i18n.language = "ru";
        compare(label.text, "Язык и регион");
        compare(i18n.formatNumber(1234.5, 2), "1,234.50");
        i18n.region = "ru_RU";
        verify(i18n.formatNumber(1234.5, 2).endsWith("234,50"));
        i18n.language = "en";
        compare(label.text, "Language & Region");
        verify(i18n.formatNumber(1234.5, 2).endsWith("234,50"));
        i18n.language = "system"; i18n.systemLanguages = ["ru_RU"];
        compare(label.text, "Язык и регион");
        i18n.region = "system"; i18n.systemRegion = "en_GB";
        compare(i18n.formatNumber(12.5, 2), "12.50");
    }
    function test_russian_plural_data() {
        return [
            {tag: "zero", count: 0, expected: "0 таймеров"},
            {tag: "one", count: 1, expected: "1 таймер"},
            {tag: "two", count: 2, expected: "2 таймера"},
            {tag: "five", count: 5, expected: "5 таймеров"},
            {tag: "eleven", count: 11, expected: "11 таймеров"},
            {tag: "twelve", count: 12, expected: "12 таймеров"},
            {tag: "twenty one", count: 21, expected: "21 таймер"},
            {tag: "twenty two", count: 22, expected: "22 таймера"},
            {tag: "hundred eleven", count: 111, expected: "111 таймеров"},
            {tag: "fraction", count: 1.5, expected: "1.5 таймера"},
            {tag: "negative", count: -1, expected: "-1 таймер"}
        ];
    }
    function test_russian_plural(data) {
        compare(service({language: "ru"}).plural("clock.timers_count", data.count), data.expected);
    }
    function test_fallback_and_message_kinds() {
        compare(Engine.text({en: {"sample.title": "Title"}, ru: {}}, "ru", "sample.title"), "Title");
        var onlyEnglish = {en: {"sample.count": {one: "{count} item", other: "{count} items"}}, ru: {}};
        compare(Engine.plural(onlyEnglish, "ru", "sample.count", 21, "21"), "21 items");
        compare(service().text("missing.id"), "⟦missing.id⟧");
        compare(service().text("clock.timers_count"), "⟦clock.timers_count⟧");
        compare(service().plural("common.apply", 1), "⟦common.apply⟧");
        compare(service().text("toString"), "⟦toString⟧");
        compare(service().plural("clock.timers_count", NaN), "⟦clock.timers_count⟧");
        compare(service().plural("clock.timers_count", 1), "1 timer");
        compare(service().plural("clock.timers_count", 2), "2 timers");
    }
    function test_parameters_are_single_pass_and_own_properties() {
        var i18n = service({language: "ru"});
        compare(i18n.text("language.app_restart", {app: "{locale} <b>$&</b>"}), "Перезапустите {locale} <b>$&</b>, чтобы применить выбранный язык.");
        compare(i18n.text("language.app_restart", Object.create({app: "inherited"})), "Перезапустите {app}, чтобы применить выбранный язык.");
        compare(i18n.plural("clock.timers_count", 2, {count: "999"}), "2 таймера");
    }
    function test_date_time_and_invalid_numbers() {
        var i18n = service({language: "ru"}), date = new Date(2026, 9, 26, 14, 5, 0);
        compare(i18n.formatDate(date, "d MMMM yyyy"), "26 October 2026");
        compare(i18n.formatTime(date, "HH:mm"), "14:05");
        i18n.region = "ru_RU";
        compare(i18n.formatDate(date, "d MMMM yyyy"), "26 октября 2026");
        compare(i18n.formatNumber(12.5, 2), "12,50");
        compare(i18n.formatNumber(Infinity), "—");
        compare(i18n.formatNumber("12.5"), "—");
        compare(i18n.formatNumber(1, -1), "—");
        compare(i18n.formatNumber(1, 1.5), "—");
        compare(i18n.formatDate(new Date(NaN)), "—");
        compare(i18n.formatDate("not a date"), "—");
    }
}
