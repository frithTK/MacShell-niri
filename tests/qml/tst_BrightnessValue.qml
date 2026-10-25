import QtQuick
import QtTest
import "../../MacShell/BrightnessValue.js" as Brightness

TestCase {
    name: "BrightnessValue"
    function test_machine_readable_selection_and_rounding_match_brightnessctl() {
        var device = Brightness.device("intel_backlight,backlight,17280,90%,19200\n");
        compare(device.path, "backlight/intel_backlight"); compare(device.value, .9);
        compare(Brightness.fraction(1, 3), .33); compare(Brightness.fraction(2, 3), .67);
        compare(Brightness.device("kbd:backlight,leds,0,0%,3").value, 0);
    }
    function test_missing_invalid_and_unsafe_paths_are_not_measurements() {
        for (var line of ["", "bad", "../../bad,backlight,1,50%,2", "..,backlight,1,50%,2", "name,other,1,50%,2", "name,backlight,1,0%,0"])
            compare(Brightness.device(line), null);
        for (var value of ["", "bad", "-1", "3.5", "Infinity"]) verify(isNaN(Brightness.number(value)));
        verify(isNaN(Brightness.fraction(101, 100))); verify(isNaN(Brightness.fraction(1, 0)));
    }
}
