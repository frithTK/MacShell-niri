import QtQuick
import QtTest
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property string selected: ""
    property int waits: 0
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name && item.visible && item.enabled) return item;
        for (var child of item.children || []) { var found = find(child, name); if (found) return found; }
        return null;
    }
    Port.ClockApp { id: clock }
    TestEvent { id: input }
    Timer {
        interval: 80; running: true; repeat: true
        onTriggered: {
            var client = clock.testBackend.controller;
            if (!clock.clockControlsReady) return;
            if (root.phase === 0) {
                clock.open("alarms"); clock.testClockWindow.sheet = "sounds"; root.phase = 1;
            } else if (root.phase === 1 && client.sounds.length === 0) {
                clock.testSoundImporter.importFiles(["file://" + Quickshell.env("CLOCK_SOUND_TEST_FILE")]); root.phase = 2;
            } else if (root.phase === 2 && client.sounds.length === 1) {
                var imported = client.sounds.find(sound => sound.imported === true);
                if (!imported || !client.previewSound(imported.id)) { console.error("CLOCK_SOUNDS_FAIL preview request"); Qt.exit(1); return; }
                root.selected = imported.id;
                root.phase = 3;
            } else if (root.phase === 3 && client.previewId.startsWith("user-")) {
                clock.testClockWindow.sheet = ""; root.phase = 4;
            } else if (root.phase === 4 && client.previewId === "") {
                clock.open("timers"); root.waits = 0; root.phase = 5;
            } else if (root.phase === 5) {
                if (++root.waits < 8) return;
                var choice = root.find(clock.testClockWindow.contentItem, "clockTimerSound");
                if (!choice) return;
                var index = choice.model.findIndex(item => item.key === root.selected);
                if (index < 0) { console.error("CLOCK_SOUNDS_FAIL missing timer choice"); Qt.exit(1); return; }
                input.mouseClick(choice, choice.width / 2, choice.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 51;
            } else if (root.phase === 51) {
                var timerChoice = root.find(clock.testClockWindow.contentItem, "clockTimerSound");
                if (!timerChoice || !timerChoice.popup.visible) return;
                input.keyClick(Qt.Key_End, Qt.NoModifier, 0); input.keyClick(Qt.Key_Return, Qt.NoModifier, 0); root.phase = 52;
            } else if (root.phase === 52) {
                if (clock.timerSoundId !== root.selected) return;
                var optionsButton = root.find(clock.testClockWindow.contentItem, "clockTimerSoundOptions");
                if (!optionsButton) return;
                input.mouseClick(optionsButton, optionsButton.width / 2, optionsButton.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 53;
            } else if (root.phase === 53) {
                var volume = root.find(clock.testClockWindow.contentItem, "clockSoundVolume");
                var repeat = root.find(clock.testClockWindow.contentItem, "clockSoundRepeat");
                var saveOptions = root.find(clock.testClockWindow.contentItem, "clockSoundOptionsSave");
                if (!volume || !repeat || !saveOptions) return;
                input.mouseClick(volume, volume.width / 2, volume.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                input.mouseClick(repeat, repeat.width / 2, repeat.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                input.mouseClick(saveOptions, saveOptions.width / 2, saveOptions.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                root.phase = 54;
            } else if (root.phase === 54) {
                if (!clock.timerSoundOptions) return;
                if (clock.timerSoundOptions.repeat !== false || clock.timerSoundOptions.volume < 25 || clock.timerSoundOptions.volume > 75 || !clock.startTimer(1200, "Sound test")) { console.error("CLOCK_SOUNDS_FAIL timer options"); Qt.exit(1); return; }
                root.phase = 6;
            } else if (root.phase === 6 && clock.testBackend.timing.timer.state === "running") {
                if (clock.testBackend.timing.timer.soundId !== root.selected || clock.testBackend.timing.timer.soundOptions.repeat !== false) { console.error("CLOCK_SOUNDS_FAIL timer selection"); Qt.exit(1); return; }
                root.phase = 7;
            } else if (root.phase === 7 && clock.testBackend.completion) {
                if (clock.testBackend.completion.soundId !== root.selected) { console.error("CLOCK_SOUNDS_FAIL timer event"); Qt.exit(1); return; }
                if (++root.waits < 8) return;
                clock.open("alarms"); clock.testClockWindow.editing = null; clock.testClockWindow.sheet = "alarm"; root.waits = 0; root.phase = 8;
            } else if (root.phase === 8) {
                if (++root.waits < 8) return;
                var alarmChoice = root.find(clock.testClockWindow.contentItem, "clockAlarmSound");
                var save = root.find(clock.testClockWindow.contentItem, "clockAlarmAction_save");
                if (!alarmChoice || !save) return;
                var alarmIndex = alarmChoice.model.findIndex(item => item.key === root.selected);
                if (alarmIndex < 0) { console.error("CLOCK_SOUNDS_FAIL missing alarm choice"); Qt.exit(1); return; }
                input.mouseClick(alarmChoice, alarmChoice.width / 2, alarmChoice.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 81;
            } else if (root.phase === 81) {
                var alarmSelect = root.find(clock.testClockWindow.contentItem, "clockAlarmSound");
                if (!alarmSelect || !alarmSelect.popup.visible) return;
                input.keyClick(Qt.Key_End, Qt.NoModifier, 0); input.keyClick(Qt.Key_Return, Qt.NoModifier, 0); root.phase = 82;
            } else if (root.phase === 82) {
                var alarmOptions = root.find(clock.testClockWindow.contentItem, "clockAlarmSoundOptions");
                if (!alarmOptions) return;
                input.mouseClick(alarmOptions, alarmOptions.width / 2, alarmOptions.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 83;
            } else if (root.phase === 83) {
                var fade = root.find(clock.testClockWindow.contentItem, "clockSoundFade");
                var alarmOptionsSave = root.find(clock.testClockWindow.contentItem, "clockSoundOptionsSave");
                if (!fade || !alarmOptionsSave) return;
                fade.forceActiveFocus(); input.keyClick(Qt.Key_Up, Qt.NoModifier, 0);
                input.mouseClick(alarmOptionsSave, alarmOptionsSave.width / 2, alarmOptionsSave.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                root.phase = 84;
            } else if (root.phase === 84) {
                var alarmSave = root.find(clock.testClockWindow.contentItem, "clockAlarmAction_save");
                if (!alarmSave) return;
                root.phase = 9;
                input.mouseClick(alarmSave, alarmSave.width / 2, alarmSave.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (root.phase === 9 && clock.alarms.length === 1) {
                if (clock.alarms[0].soundId !== root.selected || !clock.alarms[0].soundOptions || clock.alarms[0].soundOptions.fadeMs !== 1000) { console.error("CLOCK_SOUNDS_FAIL alarm selection"); Qt.exit(1); return; }
                clock.testClockWindow.sheet = "sounds"; root.waits = 0; root.phase = 10;
            } else if (root.phase === 10) {
                if (++root.waits < 8) return;
                var search = root.find(clock.testClockWindow.contentItem, "clockSoundSearch");
                if (!search) return;
                search.text = "sound sample";
                var remove = root.find(clock.testClockWindow.contentItem, "clockSoundDelete");
                if (!remove) return;
                input.mouseClick(remove, remove.width / 2, remove.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 11;
            } else if (root.phase === 11) {
                var confirmDelete = root.find(clock.testClockWindow.contentItem, "clockSoundConfirmDelete");
                if (!confirmDelete) return;
                input.mouseClick(confirmDelete, confirmDelete.width / 2, confirmDelete.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 12;
            } else if (root.phase === 12 && client.soundError === "Sound is in use") {
                clock.testClockWindow.sheet = ""; clock.stopRing(); root.phase = 13;
            } else if (root.phase === 13 && !clock.ringing) {
                if (!clock.deleteAlarm(clock.alarms[0].id)) { console.error("CLOCK_SOUNDS_FAIL delete alarm"); Qt.exit(1); return; }
                root.phase = 14;
            } else if (root.phase === 14 && clock.alarms.length === 0) {
                clock.testClockWindow.sheet = "sounds"; root.waits = 0; root.phase = 15;
            } else if (root.phase === 15) {
                if (++root.waits < 8) return;
                var searchAgain = root.find(clock.testClockWindow.contentItem, "clockSoundSearch");
                if (!searchAgain) return;
                searchAgain.text = "sound sample";
                var removeAgain = root.find(clock.testClockWindow.contentItem, "clockSoundDelete");
                if (!removeAgain) return;
                input.mouseClick(removeAgain, removeAgain.width / 2, removeAgain.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 16;
            } else if (root.phase === 16) {
                var confirmAgain = root.find(clock.testClockWindow.contentItem, "clockSoundConfirmDelete");
                if (!confirmAgain) return;
                input.mouseClick(confirmAgain, confirmAgain.width / 2, confirmAgain.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 17;
            } else if (root.phase === 17 && client.sounds.length === 0) {
                var visibility = root.find(clock.testClockWindow.contentItem, "clockSoundBuiltinVisibility");
                if (!visibility) return;
                input.mouseClick(visibility, visibility.width / 2, visibility.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 18;
            } else if (root.phase === 18 && client.showBuiltins && client.sounds.length === 40) {
                var show = root.find(clock.testClockWindow.contentItem, "clockSoundBuiltinVisibility");
                if (!show) return;
                input.mouseClick(show, show.width / 2, show.height / 2, Qt.LeftButton, Qt.NoModifier, 0); root.phase = 19;
            } else if (root.phase === 19 && !client.showBuiltins && client.sounds.length === 0) {
                console.log("CLOCK_SOUNDS_APP_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("CLOCK_SOUNDS_FAIL timeout " + root.phase + " " + clock.testSoundImporter.error); Qt.exit(1); } }
}
