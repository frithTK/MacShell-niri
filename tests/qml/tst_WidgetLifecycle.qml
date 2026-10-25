import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/WidgetVisibility.js" as Visibility

TestCase {
    id: test
    name: "WidgetLifecycle"; when: windowShown
    width: 500; height: 500; visible: true
    Component { id: registryComponent; Port.WidgetSubscriptions {} }
    Component { id: consumerComponent; Port.WidgetConsumer {} }
    Component { id: timeComponent; Port.WidgetClock {} }
    Component { id: clockComponent; Port.ClockWidget { width: 185; height: 185; managedClock: true } }
    Component {
        id: parentComponent
        Item {
            property var registry: null
            Repeater {
                model: 2
                Port.WidgetConsumer { registry: parent.registry; instanceId: "a"; widgetType: "player"; outputName: "DP-1"; active: true }
            }
        }
    }
    function row(id, type, output) { return {wid: id, wtype: type, woutput: output || "DP-1"}; }
    function view(registry, id, type, lyrics) {
        return createTemporaryObject(consumerComponent, test, {registry: registry, instanceId: id, widgetType: type, outputName: "DP-1", active: true, lyricsOpen: !!lyrics});
    }
    function test_desktop_and_mirror_share_one_source_per_instance() {
        var registry = createTemporaryObject(registryComponent, test, {instances: [row("a", "clock"), row("b", "player")]});
        var desktop = view(registry, "a", "clock"), mirror = view(registry, "a", "clock");
        var first = view(registry, "b", "player", true), second = view(registry, "b", "player", false);
        compare(registry.views.length, 4); compare(registry.consumers.length, 2);
        compare(registry.counts.time, 1); compare(registry.counts.player, 1); compare(registry.counts.lyrics, 1);
        registry.acquire(first); compare(registry.acquired, 4);
        first.active = false; compare(registry.counts.player, 1); compare(registry.counts.lyrics, 0);
        second.lyricsOpen = true; compare(registry.counts.lyrics, 1);
        registry.release(first); registry.release(first); compare(registry.released, 1);
        desktop.active = false; mirror.active = false; second.active = false;
        compare(registry.consumers.length, 0); compare(registry.clockPrecision, "off");
    }
    function test_twenty_mount_unmount_cycles_and_registry_handoff_balance() {
        var registry = createTemporaryObject(registryComponent, test, {instances: [row("a", "player")]});
        var other = createTemporaryObject(registryComponent, test, {instances: [row("a", "player")]});
        for (var index = 0; index < 20; index++) {
            var item = view(registry, "a", "player", true);
            compare(registry.counts.player, 1); item.registry = other;
            compare(registry.views.length, 0); compare(other.counts.lyrics, 1);
            item.destroy(); tryCompare(other, "views", []);
        }
        compare(registry.acquired, 20); compare(registry.released, 20);
        compare(other.acquired, 20); compare(other.released, 20);
        compare(registry.counts.player, 0); compare(other.counts.lyrics, 0);
    }
    function test_disabled_disconnected_moved_and_retyped_instances_release_demand() {
        var registry = createTemporaryObject(registryComponent, test, {instances: [row("a", "weather")]});
        var item = view(registry, "a", "weather"); compare(registry.counts.weather, 1);
        registry.enabled = false; compare(registry.counts.weather, 0);
        registry.enabled = true; registry.instances = []; compare(registry.counts.weather, 0);
        registry.instances = [row("a", "clock", "DP-2")]; compare(registry.consumers.length, 0);
        item.widgetType = "clock"; item.outputName = "DP-2"; compare(registry.counts.time, 1);
        registry.instances = [row("b", "clock", "DP-2")]; compare(registry.counts.time, 0);
        item.instanceId = "b"; compare(registry.counts.time, 1);
    }
    function test_destroying_parent_releases_all_child_consumers() {
        var registry = createTemporaryObject(registryComponent, test, {instances: [row("a", "player")]});
        for (var index = 0; index < 20; index++) {
            var container = createTemporaryObject(parentComponent, test, {registry: registry});
            compare(registry.views.length, 2); compare(registry.counts.player, 1);
            container.destroy(); tryCompare(registry, "views", []);
        }
        compare(registry.acquired, 40); compare(registry.released, 40);
    }
    function test_one_clock_uses_fastest_visible_precision_and_stops_after_last_view() {
        var registry = createTemporaryObject(registryComponent, test, {instances: [row("a", "clock"), row("b", "calendar")]});
        var source = createTemporaryObject(timeComponent, test, {precision: Qt.binding(() => registry.clockPrecision)});
        compare(source.running, false);
        var clock = view(registry, "a", "clock"), mirror = view(registry, "a", "clock");
        compare(source.interval, 33); compare(source.running, true);
        clock.secondsMode = "tick"; compare(source.interval, 33);
        mirror.active = false; compare(source.interval, 1000); compare(source.precision, "tick");
        clock.secondsMode = "hidden"; compare(source.precision, "minute");
        var calendar = view(registry, "b", "calendar"); clock.active = false;
        compare(source.precision, "date"); compare(source.interval, 30000);
        calendar.active = false; compare(source.running, false);
    }
    function test_smooth_updates_do_not_rebuild_second_minute_or_date_consumers() {
        var source = createTemporaryObject(timeComponent, test);
        source.precision = "smooth";
        var first = new Date(2026, 9, 25, 10, 20, 30, 0); source.update(first);
        var second = source.secondNow, minute = source.minuteNow, day = source.dayNow;
        for (var index = 1; index < 30; index++) source.update(new Date(2026, 9, 25, 10, 20, 30, index * 33));
        compare(source.secondNow, second); compare(source.minuteNow, minute); compare(source.dayNow, day);
        source.update(new Date(2026, 9, 25, 10, 20, 31)); verify(source.secondNow !== second);
        compare(source.minuteNow, minute); compare(source.dayNow, day);
        source.update(new Date(2026, 9, 26, 0, 0, 0)); verify(source.dayNow !== day);
    }
    function test_clock_modes_keep_geometry_and_use_shared_time_data() {
        var date = new Date(2026, 9, 25, 9, 41, 12, 500);
        var clock = createTemporaryObject(clockComponent, test, {now: date}); waitForRendering(clock);
        compare(findChild(clock, "clockTick").running, false); compare(clock.secs, 12.5);
        clock.secondsMode = "tick"; compare(clock.secs, 12);
        clock.secondsMode = "hidden"; compare(clock.secs, 0); compare(clock.width, 185); compare(clock.displayTime, "9:41");
    }
    function test_culling_requires_known_fullscreen_on_the_active_output() {
        var window = {output: "DP-1", geometryKnown: true, fullscreen: 1, workspaceActive: true, mapped: true, hidden: false};
        verify(Visibility.covered("DP-1", [window], true, false, false));
        for (var patch of [{geometryKnown: false}, {fullscreen: 0}, {workspaceActive: false}, {mapped: false}, {hidden: true}, {output: "DP-2"}])
            verify(!Visibility.covered("DP-1", [Object.assign({}, window, patch)], true, false, false));
        verify(!Visibility.covered("DP-1", [window], false, false, false));
        verify(!Visibility.covered("DP-1", [window], true, true, false));
        verify(!Visibility.covered("DP-1", [window], true, false, true));
    }
}
