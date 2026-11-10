import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    name: "ControlSwitch"
    when: windowShown
    width: 300; height: 100; visible: true

    Rectangle {
        width: 300; height: 100
        Port.ControlSwitch { id: control; width: 200; height: 32; text: "Example" }
    }

    function init() {
        control.width = 200
        control.enabled = true
        control.checked = false
        control.forceActiveFocus()
    }

    function test_keyboard_and_disabled_state() {
        verify(control.activeFocus)
        keyClick(Qt.Key_Space)
        verify(control.checked)
        keyClick(Qt.Key_Space)
        verify(!control.checked)
        control.enabled = false
        mouseClick(control, control.width - 15, control.height / 2)
        verify(!control.checked)
    }

    function test_mouse_and_compact_indicator() {
        control.width = 38
        compare(control.indicator.width, 38)
        wait(20)
        mouseClick(control, 30, control.height / 2, Qt.LeftButton)
        verify(control.checked)
        control.width = 200
    }
}
