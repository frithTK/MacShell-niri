import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/TimerWidgetData.js" as Data

TestCase {
    id: test
    name: "TimerWidget"; when: windowShown; visible: true
    width: 700; height: 700
    Component { id: card; Port.TimerWidget { style: "normal"; interactive: true; backend: clock } }
    Component { id: editor; Port.WidgetAppearanceEditor { width: 500; controller: settings } }
    QtObject {
        id: clock
        property bool ready: true
        property bool busy: false
        property string timerStatus: "normal"
        property var timing: ({timer: {state: "idle", sessionId: ""}})
        property real timerRemaining: 0
        property var calls: []
        function startTimer(ms, label, replace, soundId, options) { calls = calls.concat([["start", ms, replace]]); return true; }
        function timerAction(action) { calls = calls.concat([[action, timing.timer.sessionId]]); return true; }
    }
    QtObject {
        id: settings
        property bool settingsEditable: true
        property var calls: []
        signal mutationFinished(bool success)
        function commitWidgetAppearance(id, draft, baseline, type) { calls = [id, draft, baseline, type]; return true; }
    }
    function init() { clock.calls = []; clock.ready = true; clock.busy = false; clock.timerStatus = "normal"; clock.timing = {timer: {state: "idle", sessionId: ""}}; settings.calls = []; }
    function test_controls_share_state_and_require_confirmation() {
        var a = createTemporaryObject(card, test), b = createTemporaryObject(card, test, {x: 200});
        waitForRendering(a); mouseClick(findChild(a, "timerWidgetPreset_0"));
        compare(clock.calls[0][0], "start"); compare(clock.calls[0][1], 300000); compare(clock.calls[0][2], false);
        clock.timing = {timer: {state: "running", sessionId: "one"}}; clock.timerRemaining = 74000;
        wait(20);
        compare(findChild(b, "timerWidgetTime").text, "01:14");
        mouseClick(findChild(b, "timerWidgetToggle")); compare(clock.calls[1].join(), "pause,one");
        clock.timing = {timer: {state: "paused", sessionId: "one"}};
        wait(20);
        mouseClick(findChild(a, "timerWidgetPreset_1")); compare(clock.calls.length, 2);
        verify(findChild(a, "timerWidgetConfirmation").visible);
        mouseClick(findChild(a, "timerWidgetKeep")); compare(clock.calls.length, 2);
        mouseClick(findChild(a, "timerWidgetPreset_1")); mouseClick(findChild(a, "timerWidgetReplace"));
        compare(clock.calls[2].join(), "start,900000,true");
        mouseClick(findChild(b, "timerWidgetCancel")); compare(clock.calls[3].join(), "cancel,one");
    }
    function test_replacement_rejects_changed_session_and_unavailable_service() {
        var a = createTemporaryObject(card, test); waitForRendering(a);
        clock.timing = {timer: {state: "running", sessionId: "one"}};
        a.choose(25); clock.timing = {timer: {state: "running", sessionId: "two"}}; a.confirmReplace(); compare(clock.calls.length, 0);
        a.choose(5); clock.ready = false; a.confirmReplace(); compare(clock.calls.length, 0);
        clock.ready = true; clock.timerStatus = "recovery"; a.choose(5); compare(clock.calls.length, 0);
        compare(findChild(a, "timerWidgetStatus").text, "Restore in Clock");
        a.preview = true; clock.timerStatus = "normal"; a.choose(5); compare(clock.calls.length, 0);
    }
    function test_presets_validate_and_draft_does_not_start_timer() {
        compare(Data.validSettings({presets: [1, 60, 1440], future: true}), true);
        for (var value of [null, [], {presets: [1, 2]}, {presets: [1, 2, 0]}, {presets: [1, 2, 1.5]}]) compare(Data.validSettings(value), false);
        var record = {id: "timer-1", type: "timer", supported: true, size: "small", style: "normal", defaultStyle: "liquid", mode: "auto", savedSettings: {timer: {presets: [1, 5, 15], future: true}}};
        var e = createTemporaryObject(editor, test, {record: record}); waitForRendering(e);
        e.changeTimerPreset(1, 45); compare(e.timerPresets.join(), "1,45,15");
        e.apply(); compare(settings.calls[1].timer.presets.join(), "1,45,15"); compare(settings.calls[1].timer.future, true);
        compare(clock.calls.length, 0);
    }
}
