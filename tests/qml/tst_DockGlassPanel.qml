import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "DockGlassPanel"
    when: windowShown
    visible: true
    width: 420
    height: 220

    Port.DockGlassPanel {
        id: panel
        objectName: "dockGlassPanel"
        x: 40; y: 40
        width: 180
        bodyH: 28
        tailW: 24
        tailH: 9
        tailTipR: 3.6
        tailX: 90
        radius: 16
        k: 1
        live: false
        dark: true
        Text {
            objectName: "panelLabel"
            anchors.centerIn: parent
            text: "Finder"
            color: "white"
        }
    }

    function test_geometry_includes_tail_and_content() {
        compare(panel.height, 37)
        compare(panel.bodyH, 28)
        compare(panel.tailH, 9)
        compare(panel.blurActive, false)
        verify(findChild(panel, "panelLabel") !== null)
        verify(findChild(panel, "dockGlassSkin") !== null)
        verify(findChild(panel, "dockGlassShadow") !== null)
        verify(findChild(panel, "dockGlassBody") !== null)
    }

    function test_solid_fill_follows_theme() {
        panel.live = false
        panel.dark = true
        waitForRendering(panel)
        wait(40)
        var darkShot = grabImage(test)
        var darkPx = darkShot.pixel(panel.x + 16, panel.y + panel.bodyH / 2)
        verify(darkPx.r + darkPx.g + darkPx.b < 1.4)

        panel.dark = false
        waitForRendering(panel)
        wait(40)
        var lightShot = grabImage(test)
        var lightPx = lightShot.pixel(panel.x + 16, panel.y + panel.bodyH / 2)
        verify(lightPx.r + lightPx.g + lightPx.b > 2.0)
    }

    function test_frozen_hold_timer() {
        compare(panel.hold, false)
        panel.frozen = true
        tryCompare(panel, "hold", true, 400)
        panel.frozen = false
        compare(panel.hold, false)
    }
}
