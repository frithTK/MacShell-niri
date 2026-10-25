import QtQuick
import QtTest
import "../../MacShell/SettingsMigrations.js" as Migration

TestCase {
    name: "SettingsMigrations"
    function test_enables_monitoring_once_and_respects_user_disable() {
        var first = Migration.migrate({barWidgets: ["clock"]});
        compare(first.barWidgets.join(","), "monitoring,clock");
        first.barWidgets = ["clock"];
        var second = Migration.migrate(first);
        compare(second.barWidgets.join(","), "clock");
        compare(second.statsInterval, 1);
    }
    function test_old_focus_precedence_and_unsafe_awake_is_off() {
        var migrated = Migration.migrate({dnd: false, notifDnd: true, keepAwake: true, nightOn: true});
        compare(migrated.modeState.focus.mode, "off");
        compare(migrated.modeState.awake.mode, "off");
        compare(migrated.keepAwake, false);
        compare(migrated.nightOn, false);
        compare(migrated.nightDesired, true);
        compare(Migration.migrate({notifDnd: true}).modeState.focus.mode, "manual");
    }
    function test_existing_deadlines_and_devices_survive_reload() {
        var original = {modesMigrated: true, modeState: {focus: {mode: "60", utc: 12345, deadline: 99}}, recordMicrophone: "stable-name", statsMigrated: true, barWidgets: []};
        var migrated = Migration.migrate(original);
        compare(JSON.stringify(migrated.modeState), JSON.stringify(original.modeState));
        compare(migrated.recordMicrophone, "stable-name");
        compare(migrated.barWidgets.length, 0);
    }
    function test_invalid_values_are_bounded() {
        var migrated = Migration.migrate({statsInterval: 0, statsMetrics: ["cpu", "bad"], nightTemp: 10000, recordAudio: "default"});
        compare(migrated.statsInterval, 1);
        compare(migrated.statsMetrics.join(","), "cpu");
        compare(migrated.nightTemp, 6000);
        compare(migrated.recordAudio, "none");
    }
    function test_mirroring_tile_is_added_once_and_user_removal_survives_reload() {
        var first = Migration.migrate({ccAirDropMigrated: true, ccControls: ["wifi", "record", "sound"]});
        compare(first.ccControls.join(","), "wifi,record,mirroring,sound");
        verify(first.ccMirroringMigrated);
        first.ccControls = ["wifi", "sound"];
        compare(Migration.migrate(first).ccControls.join(","), "wifi,sound");
        compare(Migration.migrate({ccAirDropMigrated: true, ccControls: ["mirroring"]}).ccControls.join(","), "mirroring");
    }
    function test_airdrop_is_added_once_and_respects_removal_and_empty_layout() {
        var first = Migration.migrate({ccMirroringMigrated: true, ccControls: ["wifi", "mirroring", "sound"]});
        compare(first.ccControls.join(","), "wifi,mirroring,airdrop,sound");
        verify(first.ccAirDropMigrated);
        first.ccControls = ["wifi", "sound"];
        compare(Migration.migrate(first).ccControls.join(","), "wifi,sound");
        compare(Migration.migrate({ccMirroringMigrated: true, ccControls: []}).ccControls.length, 0);
    }
}
