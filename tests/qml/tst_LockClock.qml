import QtQuick
import QtTest
import "../../MacLock/ClockDisplay.js" as Clock

TestCase {
    name: "LockClock"

    function data() {
        return {version: 2, timer: {state: "running", total: 5000, endAt: 99999999, left: 5000},
                sw: {running: true, acc: 0, startAt: 1},
                timing: {version: 1, bootId: "boot-a",
                         timer: {state: "running", deadlineBootMs: 6000, remainingCheckpointMs: 5000},
                         stopwatch: {state: "running", accumulatedMs: 2000, startedBootMs: 1000, elapsedCheckpointMs: 2000}}};
    }
    function test_running_uses_boot_clock_when_wall_time_changes() {
        var state = data();
        compare(Clock.timerRemaining(state, 10, true, "boot-a", 2500), 3500);
        compare(Clock.timerRemaining(state, 999999999, true, "boot-a", 2500), 3500);
        compare(Clock.stopwatchElapsed(state, 10, true, "boot-a", 2500), 3500);
        compare(Clock.stopwatchElapsed(state, 999999999, true, "boot-a", 2500), 3500);
        compare(Clock.timerRemaining(state, 0, true, "boot-a", 9000), 0);
    }
    function test_missing_provider_and_new_boot_never_invent_elapsed() {
        var state = data();
        compare(Clock.status(state.timing, state.timing.timer, false, ""), "unavailable");
        compare(Clock.status(state.timing, state.timing.timer, true, "boot-b"), "recovery");
        compare(Clock.timerRemaining(state, 0, true, "boot-b", 100), 5000);
        compare(Clock.stopwatchElapsed(state, 0, true, "boot-b", 100), 2000);
        state.timing.timer.state = "recovery";
        compare(Clock.status(state.timing, state.timing.timer, false, ""), "recovery");
    }
    function test_paused_and_legacy_shapes() {
        var state = data();
        state.timing.timer.state = "paused";
        compare(Clock.timerRemaining(state, 1, true, "boot-a", 10000), 5000);
        compare(Clock.status(state.timing, state.timing.timer, true, "boot-b"), "recovery");
        var old = {timer: {state: "running", endAt: 4000, left: 3000},
                   sw: {running: true, acc: 1000, startAt: 500}};
        compare(Clock.timerRemaining(old, 2000, false, "", 0), 2000);
        compare(Clock.stopwatchElapsed(old, 2000, false, "", 0), 2500);
    }
    function test_invalid_running_state_is_unavailable() {
        var state = data();
        delete state.timing.timer.deadlineBootMs;
        compare(Clock.status(state.timing, state.timing.timer, true, "boot-a"), "unavailable");
    }
    function test_alarm_time_uses_selected_clock_format() {
        compare(Clock.ringTime({hour: 0, minute: 5}, true), "00:05");
        compare(Clock.ringTime({hour: 0, minute: 5}, false), "12:05 AM");
        compare(Clock.ringTime({hour: 15, minute: 9}, false), "3:09 PM");
        compare(Clock.ringTime({time: "legacy"}, false), "legacy");
        var instant = new Date(2026, 9, 30, 14, 7, 0).getTime();
        compare(Clock.ringTime({occurredWallMs: instant, time: "old"}, true), "14:07");
        compare(Clock.ringTime({occurredWallMs: instant, time: "old"}, false), "2:07 PM");
    }
}
