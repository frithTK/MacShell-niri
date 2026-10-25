import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "BackdropTexture"
    when: windowShown
    width: 220; height: 100; visible: true
    Rectangle { anchors.fill: parent; color: "#1255ff" }
    Port.BackdropTexture {
        id: backdrop
        width: 100; height: 100
        Rectangle { anchors.fill: parent; color: "#e8357a" }
    }
    ShaderEffectSource {
        id: sampled
        x: 120; width: 100; height: 100
        sourceItem: backdrop
        live: true
    }
    function test_native_path_never_paints_the_reconstructed_desktop() {
        waitForRendering(test);
        var image = grabImage(test);
        compare(image.pixel(50, 50), Qt.rgba(18 / 255, 85 / 255, 1, 1));
    }
    function test_hidden_backdrop_remains_available_to_shader_sampling() {
        waitForRendering(sampled);
        var image = grabImage(test);
        compare(image.pixel(170, 50), Qt.rgba(232 / 255, 53 / 255, 122 / 255, 1));
    }
}
