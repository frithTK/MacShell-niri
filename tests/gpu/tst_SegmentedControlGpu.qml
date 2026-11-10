import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    name: "SegmentedControlGpu"
    when: windowShown
    visible: true; width: 600; height: 180
    property bool light: false
    property var theme: light
        ? ({ctrl:"#dddddd", ctrlSel:"#ffffff", text:"#111111", dark:false, fam:"sans-serif"})
        : ({ctrl:"#444444", ctrlSel:"#888888", text:"#ffffff", dark:true, fam:"sans-serif"})
    Port.SegmentedControl {
        id: control; x: 15; y: 15; t: theme
        model: ["One", "Два", "Three"]
        onPicked: index => current = index
    }
    function test_render_and_shader_failure_data() {
        return [ {tag:"dark", light:false, segmentWidth:72},
                 {tag:"light-wide", light:true, segmentWidth:120} ]
    }
    function test_render_and_shader_failure(data) {
        light = data.light; control.segWidth = data.segmentWidth; control.current = 0
        let lens = findChild(control, "segmentGlassLens")
        verify(lens !== null)
        lens.failed = false
        lens.shaderUrl = Qt.resolvedUrl("../../MacShell/liquidglass.frag.qsb")
        mousePress(control, 10, 13)
        mouseMove(control, 2 + control.segWidth * 1.5, 13, 50)
        compare(control.dragIndex, 1)
        tryVerify(function() { return lens.active && lens.children.length > 0 }, 2000)
        wait(500)
        verify(!lens.failed)
        let image = grabImage(control)
        verify(image.width > 0 && image.height > 0)
        lens.shaderUrl = "file:///nonexistent/macshell-shader.qsb"
        tryVerify(function() { return lens.failed }, 3000)
        mouseRelease(control, 2 + control.segWidth * 1.5, 13)
        compare(control.current, 1)
    }
}
