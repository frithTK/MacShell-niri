import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test; name: "WidgetEditWindow"; when: windowShown
    width: 500; height: 400; visible: true
    Component { id: windowComponent; Port.WidgetEditWindow {} }
    SignalSpy { id: finishSpy; signalName: "finished" }
    SignalSpy { id: moveSpy; signalName: "moveRequested" }
    SignalSpy { id: resizeSpy; signalName: "resizeRequested" }
    function test_move_to_display_uses_selected_instance_and_busy_state() {
        var editor = createTemporaryObject(windowComponent, test, {selectedId: "a", selectedType: "clock", selectedOutput: "DP-1",
            displayChoices: [{name: "DP-1", label: "DP-1"}, {name: "DP-2", label: "DP-2"}]});
        moveSpy.target = editor; moveSpy.clear(); editor.activate(); tryVerify(() => editor.active);
        var choice = findChild(editor.contentItem, "widgetEditOutput"); compare(choice.visible, true);
        choice.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(moveSpy.count, 1); compare(moveSpy.signalArguments[0][0], "DP-2");
        editor.busy = true; compare(choice.enabled, false);
        editor.selectedId = ""; editor.selectedType = ""; compare(choice.visible, false);
        editor.displayChoices = [{name: "DP-1", label: "DP-1"}];
        tryCompare(editor, "height", 304); compare(editor.minimumHeight, 304); compare(editor.maximumHeight, 304); editor.hide();
    }
    function test_explicit_focus_escape_and_busy_actions_in_both_themes() {
        for (var foreground of ["#f5f5f7", "#1d1d1f"]) {
            var editor = createTemporaryObject(windowComponent, test, {foreground: foreground, outputName: Application.screens[0].name, selectedId: "card", selectedType: "player"});
            finishSpy.target = editor; finishSpy.clear(); resizeSpy.target = editor; resizeSpy.clear();
            editor.activate(); tryVerify(() => editor.active);
            compare(editor.screen.name, Application.screens[0].name);
            var size = findChild(editor.contentItem, "widgetEditSize_large");
            mouseClick(size); compare(resizeSpy.count, 1); compare(resizeSpy.signalArguments[0][0], "large");
            editor.busy = true; compare(size.enabled, false); compare(findChild(editor.contentItem, "widgetEditRemove").enabled, false);
            keyClick(Qt.Key_Escape); compare(finishSpy.count, 1);
            editor.hide(); editor.destroy();
        }
    }
}
