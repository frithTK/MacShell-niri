import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    name: "CapturePolicy"
    Port.CapturePolicy { id: policy }
    function init() {
        policy.connected = true;
        policy.gaming = false;
        policy.recording = false;
        policy.windowPreviews = false;
        policy.barGlass = false;
        policy.dockGlass = false;
    }
    function test_live_glass_works_with_window_previews_disabled() {
        compare(policy.enabled, false);
        policy.barGlass = true;
        compare(policy.enabled, true);
        policy.barGlass = false;
        policy.dockGlass = true;
        compare(policy.enabled, true);
    }
    function test_capture_stops_for_recording_games_and_disconnect() {
        policy.barGlass = true;
        policy.recording = true; compare(policy.enabled, false);
        policy.recording = false; compare(policy.enabled, true);
        policy.gaming = true; compare(policy.enabled, false);
        policy.gaming = false;
        policy.connected = false; compare(policy.enabled, false);
    }
    function test_previews_can_use_capture_without_glass() {
        policy.windowPreviews = true;
        compare(policy.enabled, true);
    }
}
