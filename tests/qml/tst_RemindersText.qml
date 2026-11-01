import QtQuick
import QtTest
import "../../MacShell/RemindersText.js" as Texts
import "../../MacShell/Utilities.js" as Utilities

TestCase {
    name: "RemindersText"
    function test_locales_have_matching_nonempty_keys() {
        var english = Object.keys(Texts.messages.en).sort();
        var russian = Object.keys(Texts.messages.ru).sort();
        compare(JSON.stringify(english), JSON.stringify(russian));
        for (var key of english) { verify(Texts.text("en", key).length > 0); verify(Texts.text("ru", key).length > 0); }
        compare(Texts.text("fr", "title"), "Reminders");
    }
    function test_catalog_and_window_titles_follow_language() {
        var opened = "";
        var entry = Utilities.entry("macshell-reminders.desktop", key => opened = key, null, "ru");
        compare(entry.name, "Напоминания"); entry.execute(); compare(opened, "reminders");
        compare(Utilities.displayTitle("org.quickshell", "Reminders", null, "ru"), "Напоминания");
        compare(Utilities.displayTitle("org.other", "Reminders", null, "ru"), "Reminders");
    }
}
