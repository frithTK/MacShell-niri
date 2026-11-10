import QtQuick
import QtTest
import "../../MacShell" as Port

// GPU render of DockGlassPanel live blur against a colorful backdrop.
// qmltestrunner software backend is not this test; run it in nested niri.
TestCase {
    id: test
    name: "DockGlassPanelGpu"
    when: windowShown
    visible: true
    width: 480
    height: 240

    Rectangle {
        id: picture
        objectName: "panelBackdrop"
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#2f6bff" }
            GradientStop { position: 0.5; color: "#b44cff" }
            GradientStop { position: 1.0; color: "#ff8a3d" }
        }
    }

    Port.DockGlassPanel {
        id: livePanel
        objectName: "livePanel"
        x: 40; y: 70
        width: 180
        bodyH: 32
        tailW: 24
        tailH: 9
        tailTipR: 3.6
        radius: 16
        k: 1
        dark: true
        live: true
        backdrop: picture
        Text {
            anchors.centerIn: parent
            text: "Live"
            color: "white"
        }
    }

    Port.DockGlassPanel {
        id: solidPanel
        objectName: "solidPanel"
        x: 250; y: 70
        width: 180
        bodyH: 32
        tailW: 24
        tailH: 9
        tailTipR: 3.6
        radius: 16
        k: 1
        dark: true
        live: false
        Text {
            anchors.centerIn: parent
            text: "Solid"
            color: "white"
        }
    }

    function test_live_and_solid_both_themes_data() {
        return [
            { tag: "dark", dark: true },
            { tag: "light", dark: false }
        ]
    }

    function test_live_and_solid_both_themes(data) {
        livePanel.dark = data.dark
        solidPanel.dark = data.dark
        tryCompare(livePanel, "blurActive", true, 2000)
        compare(solidPanel.blurActive, false)
        waitForRendering(livePanel)
        waitForRendering(solidPanel)
        wait(250)
        compare(livePanel.height, livePanel.bodyH + livePanel.tailH)
        compare(solidPanel.height, solidPanel.bodyH + solidPanel.tailH)
        var image = grabImage(test)
        verify(image.width > 0 && image.height > 0)
        var livePx = image.pixel(livePanel.x + 18, livePanel.y + livePanel.bodyH / 2)
        verify(livePx.a > 0.5)
        var solidPx = image.pixel(solidPanel.x + 18, solidPanel.y + solidPanel.bodyH / 2)
        if (data.dark)
            verify(solidPx.r + solidPx.g + solidPx.b < 1.6)
        else
            verify(solidPx.r + solidPx.g + solidPx.b > 1.8)
    }
}
