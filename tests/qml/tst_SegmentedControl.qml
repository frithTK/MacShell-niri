import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    name: "SegmentedControl"
    when: windowShown
    width: 320; height: 80; visible: true
    Port.SegmentedControl {
        id: control
        x: 5; y: 5
        t: ({ctrl:"#444444", ctrlSel:"#888888", text:"white", dark:true, fam:"sans-serif"})
        model: ["One", "Длинный текст", "Three"]
        onPicked: index => current = index
    }
    function init() { control.current = 0; control.enabled = true; control.forceActiveFocus(); }
    function test_keyboard_boundaries() {
        verify(control.activeFocus)
        keyClick(Qt.Key_Left); compare(control.current, 0)
        keyClick(Qt.Key_Right); compare(control.current, 1)
        keyClick(Qt.Key_Right); compare(control.current, 2)
        keyClick(Qt.Key_Right); compare(control.current, 2)
    }
    function test_mouse_and_disabled() {
        mouseClick(control, 2 + control.segWidth * 2.5, 13)
        compare(control.current, 2)
        control.enabled = false
        mouseClick(control, 10, 13)
        compare(control.current, 2)
    }
    function test_drag_selects_on_release() {
        mousePress(control, 10, 13)
        mouseMove(control, 2 + control.segWidth * 2.5, 13, 30)
        compare(control.current, 0)
        compare(control.dragIndex, 2)
        mouseRelease(control, 2 + control.segWidth * 2.5, 13)
        compare(control.current, 2)
        compare(control.dragIndex, -1)
    }
}
