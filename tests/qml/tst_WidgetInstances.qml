import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "WidgetInstances"; when: windowShown
    width: 600; height: 1000; visible: true
    QtObject {
        id: backend
        property bool settingsEditable: true
        property bool pending: false
        property bool canUndoDelete: true
        property var undoStack: [{}]
        property var instanceRows: []
        property var displayChoices: [{name: "DP-1", label: "DP-1"}, {name: "DP-2", label: "DP-2"}]
        property var call: []
        property bool accepted: true
        signal mutationFinished(bool success)
        function setSize(id, value) { call = ["size", id, value]; return accepted; }
        function setStyle(id, value) { call = ["style", id, value]; return accepted; }
        function setMode(id, value) { call = ["mode", id, value]; return accepted; }
        function moveWidgetToOutput(id, value) { call = ["move", id, value]; return accepted; }
        function duplicateWidget(id) { call = ["duplicate", id]; return accepted; }
        function removeWidget(id) { call = ["remove", id]; return accepted; }
        function undoDelete() { call = ["undo"]; return accepted; }
    }
    Component { id: editorComponent; Port.WidgetInstances { width: 520; controller: backend } }
    function row(id, type, connected) {
        return {id: id, type: type, label: type, supported: type !== "future", size: "small", style: "liquid", mode: "auto",
            outputName: connected ? "DP-1" : "", display: connected ? "DP-1" : "HDMI-1", placed: connected,
            reason: type === "future" ? "Unavailable. Saved settings are retained." : "Display disconnected or ambiguous", canPlace: connected};
    }
    function init() {
        backend.instanceRows = [row("a", "clock", true), row("b", "calendar", false), row("c", "future", false)];
        backend.call = []; backend.accepted = true; backend.settingsEditable = true; backend.pending = false;
        backend.undoStack = [{}]; backend.canUndoDelete = true;
    }
    function test_selection_and_actions_target_one_stable_id_data() { return [{tag: "dark", ink: "#f5f5f7"}, {tag: "light", ink: "#1d1d1f"}]; }
    function test_selection_and_actions_target_one_stable_id(data) {
        var editor = createTemporaryObject(editorComponent, test, {foreground: data.ink}); waitForRendering(editor);
        compare(editor.selected.id, "a"); compare(backend.call.length, 0);
        mouseClick(findChild(editor, "widgetInstance_b")); compare(editor.selected.id, "b");
        compare(findChild(editor, "widgetInstanceDuplicate").enabled, false);
        compare(findChild(editor, "widgetInstanceSize_small").enabled, false);
        var output = findChild(editor, "widgetInstanceOutput"); compare(output.currentIndex, 0);
        output.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(backend.call.join(), "move,b,DP-2");
        var style = findChild(editor, "widgetInstanceStyle");
        style.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(backend.call.join(), "style,b,normal");
        tryCompare(style.popup, "visible", false); waitForRendering(editor);
        mouseClick(findChild(editor, "widgetInstanceRemove")); compare(backend.call.join(), "remove,b");
        mouseClick(findChild(editor, "widgetsUndo")); compare(backend.call.join(), "undo");
        backend.instanceRows = [row("c", "future", false), row("b", "calendar", false), row("a", "clock", true)];
        compare(editor.selected.id, "b");
    }
    function test_no_room_readonly_and_unavailable_cards_keep_controls_honest() {
        var editor = createTemporaryObject(editorComponent, test); waitForRendering(editor);
        backend.accepted = false;
        mouseClick(findChild(editor, "widgetInstanceSize_large"));
        verify(editor.status.indexOf("No room") >= 0); compare(backend.call.join(), "size,a,large");
        mouseClick(findChild(editor, "widgetInstanceDuplicate")); compare(backend.call.join(), "duplicate,a");
        backend.settingsEditable = false; backend.canUndoDelete = false;
        for (var name of ["widgetInstanceSize_small", "widgetInstanceStyle", "widgetInstanceOutput", "widgetInstanceDuplicate", "widgetInstanceRemove", "widgetsUndo"])
            compare(findChild(editor, name).enabled, false, name);
        mouseClick(findChild(editor, "widgetInstance_c"));
        compare(editor.definition, null); compare(findChild(editor, "widgetInstanceStyle").visible, false);
        compare(findChild(editor, "widgetInstanceDuplicate").visible, false);
        backend.settingsEditable = true; compare(findChild(editor, "widgetInstanceRemove").enabled, true);
    }
    function test_empty_and_removed_selection_fall_back_without_writes() {
        var editor = createTemporaryObject(editorComponent, test); waitForRendering(editor);
        mouseClick(findChild(editor, "widgetInstance_b"));
        backend.instanceRows = [row("a", "clock", true)]; compare(editor.selected.id, "a");
        backend.instanceRows = []; compare(editor.selected, null); compare(backend.call.length, 0);
    }
}
