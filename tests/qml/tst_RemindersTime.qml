import QtQuick
import QtTest
import "../../MacShell/RemindersTime.js" as Time

TestCase {
    name: "RemindersTime"
    function test_empty_and_invalid_dates() {
        verify(Time.parse("", null).ok); compare(Time.parse("", null).value, null);
        for (var bad of ["noon", "2026-02-30 12:00", "2026-13-01 12:00", "2026-01-01 24:00", "1969-12-31 23:59"])
            verify(!Time.parse(bad, null).ok, bad);
    }
    function test_local_roundtrip_and_existing_instant() {
        var parsed = Time.parse("2030-02-28 12:34", null);
        verify(parsed.ok); compare(Time.format(parsed.value), "2030-02-28 12:34");
        var original = parsed.value + 12345;
        compare(Time.parse(Time.format(original), original).value, original);
    }
    function test_daylight_saving_gap_and_fold_when_in_new_york() {
        if (new Date(2026, 2, 8, 1, 30).getTimezoneOffset() !== 300 ||
            new Date(2026, 2, 8, 3, 30).getTimezoneOffset() !== 240) return;
        verify(!Time.parse("2026-03-08 02:30", null).ok);
        var repeated = Time.parse("2026-11-01 01:30", null);
        verify(!repeated.ok); compare(repeated.error, "ambiguous");
    }
}
