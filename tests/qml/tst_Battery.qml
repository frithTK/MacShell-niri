import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/BatteryState.js" as State

TestCase {
    id: test
    name: "Battery"
    when: windowShown
    width: 450; height: 650; visible: true
    QtObject {
        id: battery
        property bool present: true
        property int percentage: 72
        property bool charging: false
        property bool full: false
        property bool onBattery: true
        property string remaining: "About 3 h remaining"
        property string source: "Power Source: Battery"
        property string rateLabel: ""
    }
    QtObject {
        id: power
        property string profile: "balanced"
        property var profiles: ["power-saver", "balanced", "performance"]
        property bool available: true
        property bool busy: false
        property bool gameHold: false
        property string inhibited: ""
        property string degraded: ""
        property string error: ""
        property string requested: ""
        function label(v) { return ({"power-saver": "Low Power", balanced: "Balanced", performance: "Performance"})[v]; }
        function supported(v) { return available && profiles.indexOf(v) >= 0 && (v !== "performance" || !inhibited); }
        function select(v) { requested = v; }
    }
    Component { id: menu; Port.BatteryMenu {} }
    function init() {
        power.profile = "balanced"; power.profiles = ["power-saver", "balanced", "performance"];
        power.available = true; power.busy = false; power.inhibited = ""; power.requested = "";
        battery.rateLabel = "";
    }
    function test_duration_boundaries() {
        compare(State.duration(0), ""); compare(State.duration(-1), ""); compare(State.duration(NaN), "");
        compare(State.duration(1), "1 min"); compare(State.duration(3599), "1 h");
        compare(State.duration(3601), "1 h 1 min");
        compare(State.duration(36 * 3600 + 1), "");
    }
    function test_trusted_time_rejects_upower_noise() {
        compare(State.trustedTime(167 * 24 * 3600), 0);
        compare(State.trustedTime(5400), 5400);
        compare(State.watts(0.011), -1);
        compare(State.watts(8.4), 8.4);
        compare(State.formatWatts(0.011), "");
        compare(State.formatWatts(8.41), "8.4 W");
        compare(State.formatEnergy(45.09, 53.04), "45.1 / 53.0 Wh");
        compare(State.formatEnergy(-1, -1), "");
        verify(State.remaining(true, 2, 167 * 24 * 3600, 0, true).indexOf("Calculating") >= 0);
    }
    function test_extras_skip_laptop_and_line_power() {
        var laptop = {isLaptopBattery: true, isPresent: true, ready: true, type: 2, percentage: 1, model: "BAT1"};
        var ac = {isLaptopBattery: false, isPresent: true, ready: true, type: 1, percentage: 0, nativePath: "ACAD"};
        var mouse = {isLaptopBattery: false, isPresent: true, ready: true, type: 6, percentage: 0.42, model: "Magic Mouse", nativePath: "/org/mouse"};
        var absent = {isLaptopBattery: false, isPresent: false, ready: true, type: 2, percentage: 0.5, model: "gone"};
        var extras = State.extras([laptop, ac, mouse, absent]);
        compare(extras.length, 1);
        compare(extras[0].name, "Magic Mouse");
        compare(extras[0].percentage, 42);
    }
    function test_health_uses_one_present_internal_battery() {
        var internal = {isLaptopBattery: true, isPresent: true, ready: true, healthSupported: true, healthPercentage: 85.8961};
        var peripheral = {isLaptopBattery: false, isPresent: true, ready: true, healthSupported: true, healthPercentage: 40};
        compare(State.healthPercentage([peripheral, internal]), 86);
        compare(State.healthPercentage([]), -1);
        compare(State.healthPercentage([internal, internal]), -1);
        internal.healthSupported = false; compare(State.healthPercentage([internal]), -1);
        internal.healthSupported = true; internal.healthPercentage = NaN; compare(State.healthPercentage([internal]), -1);
        internal.healthPercentage = 0; compare(State.healthPercentage([internal]), -1);
        internal.healthPercentage = 101; compare(State.healthPercentage([internal]), -1);
        internal.healthPercentage = 85; internal.ready = false; compare(State.healthPercentage([internal]), -1);
    }
    function test_battery_states_and_unknown_estimates() {
        compare(State.remaining(true, 2, 5400, 0, true), "About 1 h 30 min remaining");
        compare(State.remaining(true, 1, 0, 1800, false), "About 30 min until full");
        compare(State.remaining(true, 4, 0, 0, false), "Fully Charged");
        verify(State.remaining(true, 2, 0, 0, true).indexOf("Calculating") >= 0);
        compare(State.remaining(true, 3, 0, 0, false), "Power Adapter · Not Charging");
        compare(State.remaining(false, 0, 0, 0, false), "No battery");
    }
    function test_profile_selection_waits_for_system_confirmation() {
        var item = createTemporaryObject(menu, test, {battery: battery, power: power, width: 350});
        var performance = findChild(item, "power_performance");
        tryVerify(() => item.implicitHeight > 200);
        waitForRendering(item);
        mouseClick(performance);
        compare(power.requested, "performance"); compare(power.profile, "balanced");
        compare(performance.selected, false);
        power.profile = "performance"; compare(performance.selected, true);
        power.busy = true; compare(performance.enabled, false);
        compare(findChild(item, "batteryRate").visible, false);
        battery.rateLabel = "8.4 W";
        compare(findChild(item, "batteryRate").visible, true);
        compare(findChild(item, "batteryRate").text, "8.4 W");
        battery.rateLabel = "";
    }
    function test_missing_and_inhibited_profiles_in_both_themes() {
        for (var foreground of ["white", "#1d1d1f"]) {
            var item = createTemporaryObject(menu, test, {battery: battery, power: power, width: 350, foreground: foreground});
            tryVerify(() => item.implicitHeight > 200 && item.implicitHeight < 600);
            compare(findChild(item, "batteryRemaining").text, battery.remaining);
            power.inhibited = "lap-detected"; compare(findChild(item, "power_performance").enabled, false);
            power.inhibited = ""; power.profiles = ["power-saver", "balanced"];
            compare(findChild(item, "power_performance").enabled, false);
            item.destroy(); wait(1);
        }
    }
}
