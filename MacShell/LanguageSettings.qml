import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Locale" as Language

ControlMenu {
    id: root
    objectName: "languageSettings"
    required property var controller
    property var draft: ({ui: "system", session: "system", region: "system"})
    property string draftToken: ""
    property bool dirty: false
    function loadDraft() {
        if (!controller.ready) return;
        draft = Object.assign({}, controller.values); draftToken = controller.token; dirty = false;
    }
    function setValue(key, value) { var next = Object.assign({}, draft); next[key] = value; draft = next; dirty = true; }
    function chooseLanguage(value) {
        var next = Object.assign({}, draft); next.ui = value;
        var preferred = value === "ru" ? "ru_RU.UTF-8" : "en_US.UTF-8";
        function normalized(locale) { return locale.toLowerCase().replace(/[-.]/g, ""); }
        next.session = value === "system" ? "system" : (controller.locales.find(locale => normalized(locale) === normalized(preferred))
            || controller.locales.find(locale => locale.toLowerCase().startsWith(value + "_")) || preferred);
        draft = next; dirty = true;
    }
    readonly property var choices: [{value: "system", label: Language.I18n.text("language.system_default")}].concat(controller.locales.map(value => ({value: value,
        label: Qt.locale(value).nativeLanguageName + (Qt.locale(value).nativeTerritoryName ? " — " + Qt.locale(value).nativeTerritoryName : "") + " (" + value + ")"})))
        .concat((controller.missing || []).map(value => ({value: value, label: Language.I18n.text("language.locale_missing", {locale: value})})));
    function errorText(code) {
        switch (code) {
        case "locale_missing": return Language.I18n.text("language.locale_missing", {locale: controller.errorDetail});
        case "lc_all_conflict": return Language.I18n.text("language.locale_conflict", {locale: controller.errorDetail});
        case "locale_query_failed": return Language.I18n.text("language.locale_query_failed");
        case "conflict": return Language.I18n.text("language.save_conflict");
        case "unowned_or_future": case "symlink": case "invalid": return Language.I18n.text("language.protected_file");
        case "": return "";
        default: return Language.I18n.text("language.save_error");
        }
    }
    Component.onCompleted: loadDraft()
    Connections {
        target: root.controller
        function onValuesChanged() { if (!root.dirty) root.loadDraft(); }
        function onReadyChanged() { if (root.controller.ready && !root.dirty) root.loadDraft(); }
        function onFinished(success) { if (success) root.loadDraft(); }
    }
    contentItem: Column {
        spacing: 14
        Text { width: parent.width; text: Language.I18n.text("language.scope"); textFormat: Text.PlainText; color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        Text { text: Language.I18n.text("language.system_language"); color: root.foreground; font: root.font }
        ControlComboBox {
            objectName: "systemLanguage"; width: parent.width; textRole: "label"
            model: [{value: "system", label: Language.I18n.text("language.system_default")}, {value: "ru", label: "Русский"}, {value: "en", label: Language.I18n.text("language.english")}]
            currentIndex: Math.max(0, model.findIndex(item => item.value === root.draft.ui))
            enabled: root.controller.ready && !root.controller.pending
            onActivated: index => root.chooseLanguage(model[index].value)
        }
        Text { text: Language.I18n.text("language.applications"); color: root.foreground; font: root.font }
        ControlComboBox {
            objectName: "sessionLanguage"; width: parent.width; model: root.choices; textRole: "label"
            currentIndex: Math.max(0, model.findIndex(item => item.value === root.draft.session))
            enabled: root.controller.ready && !root.controller.pending
            onActivated: index => root.setValue("session", model[index].value)
        }
        Text { text: Language.I18n.text("language.region"); color: root.foreground; font: root.font }
        ControlComboBox {
            objectName: "systemRegion"; width: parent.width; model: root.choices; textRole: "label"
            currentIndex: Math.max(0, model.findIndex(item => item.value === root.draft.region))
            enabled: root.controller.ready && !root.controller.pending
            onActivated: index => root.setValue("region", model[index].value)
        }
        Text { width: parent.width; text: Language.I18n.text("language.login_explanation"); textFormat: Text.PlainText; color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        Text {
            width: parent.width; visible: root.controller.conflict !== ""
            text: Language.I18n.text("language.locale_conflict", {locale: root.controller.conflict}); textFormat: Text.PlainText
            color: root.warning; wrapMode: Text.Wrap; font: root.font
        }
        Text { objectName: "languageError"; width: parent.width; visible: text !== ""; text: root.errorText(root.controller.errorCode); textFormat: Text.PlainText; color: root.warning; wrapMode: Text.Wrap; font: root.font }
        Row {
            spacing: 10
            ControlButton { objectName: "languageApply"; text: Language.I18n.text("common.apply"); primary: true; enabled: root.dirty && root.controller.ready && !root.controller.pending; onClicked: root.controller.save(root.draft, root.draftToken) }
            ControlButton { objectName: "languageReload"; text: Language.I18n.text("language.reload"); enabled: !root.controller.pending; onClicked: { root.dirty = false; root.controller.refresh(); } }
        }
    }
}
