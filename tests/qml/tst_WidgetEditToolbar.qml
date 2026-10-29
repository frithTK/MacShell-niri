import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test; name: "WidgetEditToolbar"; when: windowShown
    width: 800; height: 400; visible: true
    Component { id: toolbarComponent; Port.WidgetEditToolbar { width: 760; height: 40 } }
    SignalSpy { id: finishSpy; signalName: "finished" }
    SignalSpy { id: moveSpy; signalName: "moveRequested" }
    SignalSpy { id: resizeSpy; signalName: "resizeRequested" }
    function test_move_to_display_uses_selected_instance_and_busy_state() {
        var editor = createTemporaryObject(toolbarComponent, test, {selectedId: "a", selectedType: "clock", selectedOutput: "DP-1",
            displayChoices: [{name: "DP-1", label: "DP-1"}, {name: "DP-2", label: "DP-2"}]});
        moveSpy.target = editor; moveSpy.clear(); editor.activate(); tryVerify(() => editor.activeFocus);
        var choice = findChild(editor, "widgetEditOutput"); compare(choice.visible, true);
        choice.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(moveSpy.count, 1); compare(moveSpy.signalArguments[0][0], "DP-2");
        editor.busy = true; compare(choice.enabled, false);
        editor.selectedId = ""; editor.selectedType = ""; compare(choice.visible, false);
        compare(editor.height, 40);
    }
    function test_focus_escape_busy_actions_and_optional_menu_in_both_themes() {
        for (var foreground of ["#f5f5f7", "#1d1d1f"]) {
            var editor = createTemporaryObject(toolbarComponent, test, {foreground: foreground, selectedId: "card", selectedType: "player"});
            finishSpy.target = editor; finishSpy.clear(); resizeSpy.target = editor; resizeSpy.clear();
            editor.activate(); tryVerify(() => editor.activeFocus);
            mouseClick(findChild(editor, "widgetEditSize_large")); compare(resizeSpy.count, 1); compare(resizeSpy.signalArguments[0][0], "large");
            editor.busy = true; compare(findChild(editor, "widgetEditSize_large").enabled, false);
            mouseClick(findChild(editor, "widgetEditMore")); wait(50);
            compare(editor.actionButton("widgetEditRemove").enabled, false);
            keyClick(Qt.Key_Escape); compare(finishSpy.count, 1);
            editor.visible = false; editor.destroy();
        }
    }
}
