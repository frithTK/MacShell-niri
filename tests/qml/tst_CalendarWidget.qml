import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "CalendarWidget"; when: windowShown
    width: 800; height: 500; visible: true
    Component { id: cardComponent; Port.CalendarWidget { style: "normal"; preview: true } }
    function test_today_circle_is_even_and_shares_the_day_box_data() {
        return [{tag: "small", size: "small"}, {tag: "medium", size: "medium"}, {tag: "large", size: "large"}];
    }
    function test_today_circle_is_even_and_shares_the_day_box(data) {
        var item = createTemporaryObject(cardComponent, test, {size: data.size, now: new Date(2026, 9, 23, 9, 41)});
        verify(item !== null); waitForRendering(item);
        var grid = findChild(item, "calendarGrid");
        verify(grid !== null);
        compare(grid.x, Math.round(grid.x));
        compare(grid.y, Math.round(grid.y));
        compare(grid.width, Math.round(grid.width));
        compare(grid.wdH, Math.round(grid.wdH));
        compare(grid.rowH, Math.round(grid.rowH));
        verify(grid.circ % 2 === 0);
        var today = findChild(item, "calendarToday");
        verify(today !== null);
        compare(today.width, grid.circ);
        compare(today.height, grid.circ);
        compare(today.parent.width, grid.circ);
        compare(today.parent.height, grid.circ);
        compare(findChild(item, "calendarRollover").running, false);
    }
}
