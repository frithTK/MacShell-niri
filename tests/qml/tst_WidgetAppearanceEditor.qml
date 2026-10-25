import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "WidgetAppearanceEditor"; when: windowShown
    width: 600; height: 950; visible: true
    QtObject {
        id: backend
        property bool settingsEditable: true
        property var call: []
        property bool accepted: true
        signal mutationFinished(bool success)
        function commitWidgetAppearance(id, draft, baseline) { call = [id, draft, baseline]; return accepted; }
    }
    Component { id: editorComponent; Port.WidgetAppearanceEditor { width: 520; controller: backend } }
    function record(type, style) { return {id: "chosen", type: type, style: style, size: "small", mode: "auto", supported: true, appearance: {}}; }
    function choose(editor, name, end) {
        var choice = findChild(editor, name); choice.forceActiveFocus(); keyClick(Qt.Key_Space);
        keyClick(end ? Qt.Key_End : Qt.Key_Home); keyClick(Qt.Key_Return); tryCompare(choice.popup, "visible", false);
    }
    function init() { backend.settingsEditable = true; backend.call = []; backend.accepted = true; }
    function test_only_effective_controls_and_preview_follow_shell_data() { return [{tag: "dark", dark: true}, {tag: "light", dark: false}]; }
    function test_only_effective_controls_and_preview_follow_shell(data) {
        var editor = createTemporaryObject(editorComponent, test, {record: record("clock", "liquid"), foreground: data.dark ? "white" : "#1d1d1f", "font.family": "sans-serif"});
        waitForRendering(editor);
        var preview = findChild(editor, "widgetAppearancePreview");
        compare(preview.visual.dark, data.dark); compare(preview.visual.fam, "sans-serif"); compare(backend.call.length, 0);
        editor.record = Object.assign({}, editor.record, {appearance: {theme: "dark", fontFamily: "monospace", textScale: 1.2}});
        editor.foreground = "#1d1d1f"; waitForRendering(editor);
        compare(preview.visual.dark, true); compare(preview.visual.fam, "monospace"); compare(preview.visual.textScale, 1.2);
        compare(findChild(editor, "widgetAppearanceDensity").visible, false); compare(findChild(editor, "widgetAppearanceTint").visible, false);
        editor.change("textScale", 1.15); compare(findChild(editor, "widgetAppearanceTextSize").displayText, "Custom (115%)");
        editor.load();
        editor.record = record("weather", "normal"); compare(findChild(editor, "widgetAppearanceTheme").visible, false);
        editor.record = record("calendar", "normal"); compare(findChild(editor, "widgetAppearanceTheme").visible, true);
    }
    function test_changes_and_resets_target_only_the_selected_instance() {
        var editor = createTemporaryObject(editorComponent, test, {record: record("player", "liquid")}); waitForRendering(editor);
        choose(editor, "widgetAppearanceTheme", true); compare(editor.local.theme, "dark");
        choose(editor, "widgetAppearanceTheme", false); compare(editor.local.theme, undefined);
        choose(editor, "widgetAppearanceFont", true); compare(editor.local.fontFamily, "monospace");
        choose(editor, "widgetAppearanceTextSize", true); compare(editor.local.textScale, 1.2);
        compare(findChild(editor, "widgetAppearanceTextSize").displayText, "Extra large");
        choose(editor, "widgetAppearanceDensity", true); compare(editor.local.density, "comfortable");
        choose(editor, "widgetAppearanceTint", true); compare(editor.local.tint, "#ae587e");
        compare(backend.call.length, 0); compare(editor.dirty, true);
        mouseClick(findChild(editor, "widgetAppearanceApply"));
        compare(backend.call[0], "chosen"); compare(backend.call[1].appearance.fontFamily, "monospace");
        compare(editor.applying, true); compare(findChild(editor, "widgetAppearanceApply").enabled, false);
        editor.record = Object.assign({}, editor.record, {savedSettings: backend.call[1]});
        backend.mutationFinished(true); compare(editor.dirty, false);
        mouseClick(findChild(editor, "widgetAppearanceReset")); compare(editor.dirty, true);
        compare(editor.local.fontFamily, undefined);
        mouseClick(findChild(editor, "widgetAppearanceCancel")); compare(editor.dirty, false);
        compare(editor.local.fontFamily, "monospace");

        backend.settingsEditable = false;
        for (var name of ["Theme", "Font", "TextSize", "Density", "Tint", "Reset", "Apply"]) compare(findChild(editor, "widgetAppearance" + name).enabled, false);
    }
    function test_failed_apply_keeps_draft_and_does_not_adopt_external_changes() {
        var editor = createTemporaryObject(editorComponent, test, {record: record("player", "liquid")}); waitForRendering(editor);
        choose(editor, "widgetAppearanceFont", true);
        var before = JSON.stringify(editor.draft);
        editor.record = Object.assign({}, editor.record, {savedSettings: {style: "light", appearance: {tint: "#377cc8"}}});
        compare(JSON.stringify(editor.draft), before);
        backend.accepted = false; mouseClick(findChild(editor, "widgetAppearanceApply"));
        compare(editor.dirty, true); compare(editor.applying, false); verify(editor.error !== "");
        backend.accepted = true; mouseClick(findChild(editor, "widgetAppearanceApply"));
        backend.mutationFinished(false); compare(JSON.stringify(editor.draft), before); verify(editor.error !== "");
        mouseClick(findChild(editor, "widgetAppearanceCancel")); compare(editor.dirty, false); compare(editor.local.tint, "#377cc8");
    }
    function test_future_record_has_no_preview_or_interpreted_appearance() {
        var editor = createTemporaryObject(editorComponent, test, {record: {id: "future", type: "clock", supported: false,
            savedSettings: {appearance: {fontFamily: false, textScale: 5, theme: "unknown"}}}});
        waitForRendering(editor);
        compare(findChild(editor, "widgetAppearancePreview").visual, null);
        compare(editor.editable, false); compare(editor.dirty, false); compare(Object.keys(editor.local).length, 0);
    }
    function test_clock_seconds_are_local_draft_and_hidden_for_other_types() {
        var editor = createTemporaryObject(editorComponent, test, {record: record("clock", "liquid")}); waitForRendering(editor);
        choose(editor, "widgetAppearanceSeconds", true);
        compare(editor.local.secondsMode, "hidden"); compare(backend.call.length, 0);
        compare(findChild(editor, "widgetAppearancePreview").visual.secondsMode, "hidden");
        mouseClick(findChild(editor, "widgetAppearanceApply"));
        compare(backend.call[1].appearance.secondsMode, "hidden");
        backend.mutationFinished(false); editor.record = record("player", "liquid");
        compare(findChild(editor, "widgetAppearanceSeconds").visible, false);
    }
}
