import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "LevelOsd"
    when: windowShown
    width: 330; height: 100; visible: true
    Port.LevelOsdState { id: state }
    Port.LevelOsd { id: view; anchors.fill: parent; kind: state.kind; value: state.value; muted: state.muted }
    SignalSpy { id: shown; target: state; signalName: "shown" }

    function init() {
        state.startupTimer.stop(); state.hideTimer.stop();
        state.ready = true; state.visible = false; state.quietUntil = ({});
        state.kind = "volume"; state.value = 0; state.muted = false;
        state.duration = 1500; shown.clear();
    }
    function test_hardware_request_overrides_slider_quiet_and_startup() {
        state.ready = false;
        state.quiet("volume", 600);
        compare(state.show("volume", .45), false);
        compare(state.show("volume", .5, false, true), true);
        compare(state.visible, true);
        compare(view.percentage, 50);
        compare(shown.count, 1);
        // The asynchronous backend echo must not restart or duplicate feedback.
        compare(state.show("volume", .5), false);
        compare(shown.count, 1);
        compare(state.show("volume", .55, false, true), true);
        compare(view.percentage, 55);
    }
    function test_sliders_stay_quiet_without_blocking_other_kind() {
        state.quiet("volume", 600);
        compare(state.show("volume", .7), false);
        compare(state.visible, false);
        compare(state.show("brightness", .8), true);
        compare(state.kind, "brightness"); compare(view.percentage, 80);
    }
    function test_repeat_at_limit_restarts_timeout() {
        state.duration = 250;
        state.show("brightness", 1, false, true);
        wait(170);
        state.show("brightness", 1, false, true);
        wait(170);
        compare(state.visible, true);
        tryCompare(state, "visible", false, 600);
    }
    function test_boundary_values_and_mute_keep_actual_level() {
        state.show("volume", 1.3, false, true);
        compare(view.percentage, 130);
        compare(state.value, 1.3);
        fuzzyCompare(view.filled, 1.3 / 1.5, .0001);
        state.show("volume", 2, false, true);
        compare(view.percentage, 150);
        compare(view.filled, 1);
        state.show("volume", -.2, false, true);
        compare(view.percentage, 0);
        compare(findChild(view, "osdIcon").level, 0);
        state.show("volume", .75, true, true);
        compare(findChild(view, "osdValue").text, "Muted");
        compare(view.value, .75); compare(view.filled, 0);
        state.show("volume", .75, false, true);
        compare(findChild(view, "osdValue").text, "75%");
    }
    function test_boosted_mute_restores_actual_percentage() {
        state.show("volume", 1.4, true, true);
        compare(state.value, 1.4);
        compare(findChild(view, "osdValue").text, "Muted");
        compare(view.filled, 0);
        state.show("volume", 1.4, false, true);
        compare(findChild(view, "osdValue").text, "140%");
        compare(findChild(view, "osdIcon").level, 3);
    }
    function test_non_output_levels_keep_their_limits() {
        for (var kind of ["microphone", "brightness"]) {
            state.show(kind, 1.5, false, true);
            compare(state.value, 1);
            compare(view.percentage, 100);
            compare(view.filled, 1);
        }
        state.show("volume", 1, false, true);
        compare(view.percentage, 100);
        fuzzyCompare(view.filled, 2 / 3, .0001);
        compare(findChild(view, "osdIcon").level, 3);
    }
    function test_microphone_and_brightness_have_distinct_icons() {
        state.show("microphone", .6, true, true);
        compare(view.title, "Microphone");
        compare(findChild(view, "osdIcon").kind, "mic");
        compare(findChild(view, "osdIcon").flag, true);
        state.show("brightness", .6, false, true);
        compare(view.title, "Brightness");
        compare(findChild(view, "osdIcon").kind, "sun");
        compare(findChild(view, "osdIcon").flag, false);
    }
    function test_theme_colors_and_invalid_feedback() {
        for (var color of ["#f7f7fa", "#1d1d1f"]) {
            view.foreground = color;
            state.show("volume", .45, false, true);
            compare(findChild(view, "osdValue").color, view.foreground);
            compare(findChild(view, "osdIcon").color, view.foreground);
            verify(view.width >= view.implicitWidth);
        }
        shown.clear(); state.visible = false;
        compare(state.show("unknown", .5, false, true), false);
        compare(state.show("volume", NaN, false, true), false);
        compare(state.visible, false); compare(shown.count, 0);
    }
}
