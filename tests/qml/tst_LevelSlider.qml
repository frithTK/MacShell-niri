import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "LevelSlider"
    when: windowShown
    width: 330; height: 100; visible: true
    Port.LevelSlider {
        id: slider
        x: 10; y: 10; width: 300
        t: ({fg: "white", fg2: "gray", track: "#444444"})
        onMoved: v => value = v
    }
    SignalSpy { id: moved; target: slider; signalName: "moved" }

    function init() {
        slider.maximumValue = 1;
        slider.value = 0;
        moved.clear();
    }
    function test_output_clicks_and_drag_reach_150_percent() {
        slider.maximumValue = 1.5;
        mouseClick(slider, slider.trackX + slider.trackW * 2 / 3, 14);
        fuzzyCompare(slider.value, 1, .01);
        mousePress(slider, slider.trackX + slider.trackW * 2 / 3, 14);
        mouseMove(slider, slider.trackX + slider.trackW, 14);
        mouseRelease(slider, slider.trackX + slider.trackW, 14);
        compare(slider.value, 1.5);
        compare(slider.position, 1);
        verify(moved.count > 0);
        mouseClick(slider, slider.width - 1, 14);
        compare(slider.value, 1.5);
        mouseClick(slider, 1, 14);
        compare(slider.value, 0);
    }
    function test_unity_marker_and_external_boosted_values() {
        slider.maximumValue = 1.5;
        slider.value = 1.25;
        fuzzyCompare(slider.position, 1.25 / 1.5, .0001);
        var mark = findChild(slider, "unityMark");
        compare(mark.visible, true);
        fuzzyCompare(mark.x + mark.width / 2, slider.trackX + slider.trackW * 2 / 3, .0001);
        slider.value = 2;
        compare(slider.position, 1);
        slider.value = -.1;
        compare(slider.position, 0);
    }
    function test_default_range_stays_at_100_percent() {
        mouseClick(slider, slider.width - 1, 14);
        compare(slider.value, 1);
        compare(slider.position, 1);
        compare(findChild(slider, "unityMark").visible, false);
    }
}
