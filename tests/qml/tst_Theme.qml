import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/GlassTheme.js" as GlassTheme
import "../../MacShell/BarInk.js" as BarInk

TestCase {
    id: test
    name: "Theme"; when: windowShown
    width: 650; height: 700; visible: true
    QtObject { id: barState; property bool settingsReady: false; property bool darkMode: true }
    QtObject { id: dockState; property bool settingsReady: false; property bool darkMode: true }
    Component { id: coordinator; Port.ThemeCoordinator { bar: barState; dock: dockState } }
    Component { id: preview; Port.WidgetPreview {} }
    Component { id: gallery; Port.ControlMenu { width: 400; height: 150 } }
    function init() { barState.settingsReady = false; dockState.settingsReady = false; barState.darkMode = true; dockState.darkMode = true; }
    function test_wait_for_both_settings_files_then_use_settings_theme() {
        var sync = createTemporaryObject(coordinator, test);
        barState.darkMode = false; barState.settingsReady = true;
        compare(dockState.darkMode, true); compare(sync.initialized, false);
        dockState.settingsReady = true; compare(sync.initialized, true);
        compare(barState.darkMode, true); compare(dockState.darkMode, true);
    }
    function test_loading_order_does_not_change_saved_light_theme() {
        var sync = createTemporaryObject(coordinator, test);
        dockState.darkMode = false; dockState.settingsReady = true;
        compare(barState.darkMode, true);
        barState.settingsReady = true; compare(sync.initialized, true);
        compare(barState.darkMode, false); compare(dockState.darkMode, false);
    }
    function test_both_entry_points_stay_synchronized_for_repeated_toggles() {
        var sync = createTemporaryObject(coordinator, test);
        barState.settingsReady = true; dockState.settingsReady = true;
        for (var i = 0; i < 20; i++) {
            barState.darkMode = false; compare(dockState.darkMode, false);
            dockState.darkMode = true; compare(barState.darkMode, true);
        }
        compare(sync.synchronizing, false);
    }
    function test_settings_reload_reconciles_after_both_owners_ready() {
        var sync = createTemporaryObject(coordinator, test);
        barState.settingsReady = true; dockState.settingsReady = true;
        barState.settingsReady = false; barState.darkMode = false;
        compare(dockState.darkMode, true); compare(sync.initialized, false);
        barState.settingsReady = true; compare(barState.darkMode, true); compare(sync.initialized, true);
    }
    function test_open_control_palettes_follow_live_foreground() {
        var menu = createTemporaryObject(gallery, test, {foreground: "white"});
        compare(menu.dark, true);
        menu.foreground = "#1d1d1f";
        compare(menu.dark, false); compare(String(menu.palette.window), "#fafafb");
        compare(String(menu.palette.text), "#1d1d1f"); compare(String(menu.palette.highlightedText), "#ffffff");
        verify(menu.secondary.a >= .67);
        menu.foreground = "white"; compare(menu.dark, true);
    }
    function test_transparent_bar_ink_uses_background_luminance_and_stays_stable() {
        compare(BarInk.preferLight(0, 0, 0, null), true);
        compare(BarInk.preferLight(1, 1, 1, null), false);
        compare(BarInk.preferLight(1, 0, 0, null), false);
        compare(BarInk.preferLight(0, 0, 1, null), true);
        compare(BarInk.preferLight(0, 1, 0, null), false);
        compare(BarInk.preferLight(.46, .46, .46, true), true);
        compare(BarInk.preferLight(.46, .46, .46, false), false);
        compare(BarInk.preferLight(1, 1, 1, true), false);
        compare(BarInk.preferLight(0, 0, 0, false), true);
    }
    function luminance(value) {
        function linear(v) { return v <= .04045 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); }
        return .2126 * linear(value.r) + .7152 * linear(value.g) + .0722 * linear(value.b);
    }
    function contrast(a, b) { var x = luminance(a), y = luminance(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); }
    function over(ink, backdrop) { return Qt.rgba(ink.r * ink.a + backdrop.r * (1 - ink.a), ink.g * ink.a + backdrop.g * (1 - ink.a), ink.b * ink.a + backdrop.b * (1 - ink.a), 1); }
    function test_light_glass_retains_readable_ink_over_extreme_backdrops() {
        var menu = createTemporaryObject(gallery, test, {foreground: "#1d1d1f"});
        for (var frost of [0, .42, 1]) for (var backdrop of [Qt.color("black"), Qt.color("white")]) {
            var pane = over(Qt.rgba(1, 1, 1, GlassTheme.lightTint(frost)), backdrop);
            verify(contrast(Qt.color("#1d1d1f"), pane) >= 4.5);
            verify(contrast(over(Qt.rgba(0, 0, 0, .68), pane), pane) >= 4.5);
            verify(contrast(menu.warning, pane) >= 4.5);
            verify(contrast(menu.danger, pane) >= 4.5);
        }
    }
    function test_weather_forecast_and_location_repaint_when_already_open() {
        var item = createTemporaryObject(preview, test, {widgetType: "weather", widgetSize: "large", widgetStyle: "liquid", dark: true});
        item.visual.located = true; waitForRendering(item);
        var arrow = findChild(item, "weatherLocation"); verify(arrow !== null);
        item.dark = false; waitForRendering(item);
        function darkPixels() {
            // Grab the owning item: grabImage(Canvas) can crop its texture using
            // the parent's fractional coordinates on the software backend.
            var image = grabImage(item), origin = arrow.mapToItem(item, 0, 0), count = 0;
            for (var y = Math.floor(origin.y); y < Math.ceil(origin.y + arrow.height); y++)
                for (var x = Math.floor(origin.x); x < Math.ceil(origin.x + arrow.width); x++) {
                    var p = image.pixel(x, y);
                    if (p.a > .6 && p.r < .2 && p.g < .2 && p.b < .2) count++;
                }
            return count;
        }
        tryVerify(() => darkPixels() > 2, 1000, "The location arrow retained white paint");
        var labels = 0;
        function checkInk(node) {
            if (typeof node.text === "string" && node.text && node.color !== undefined && node.visible) {
                verify(node.color.r < .2, "Forecast label retained white ink: " + node.text); labels++;
            }
            for (var child of node.children || []) checkInk(child);
        }
        checkInk(item.visual); verify(labels >= 20);
    }
    function test_existing_widget_instances_change_theme_without_recreation_data() {
        var result = [];
        for (var type of ["weather", "calendar", "clock", "player"]) for (var size of ["small", "medium", "large"])
            result.push({tag: type + "/" + size, type: type, size: size});
        return result;
    }
    function test_existing_widget_instances_change_theme_without_recreation(data) {
        var item = createTemporaryObject(preview, test, {widgetType: data.type, widgetSize: data.size, widgetStyle: "liquid", dark: true});
        waitForRendering(item); var visual = item.visual;
        compare(visual.dark, true);
        item.dark = false; compare(item.visual, visual); compare(visual.dark, false);
        waitForRendering(item);
        if (data.type === "weather" || data.type === "calendar" || data.type === "player") verify(visual.fg.r < .2);
        item.dark = true; compare(item.visual, visual); compare(visual.dark, true);
    }
    function test_explicit_widget_styles_remain_explicit() {
        var player = createTemporaryObject(preview, test, {widgetType: "player", widgetStyle: "dark", dark: false});
        compare(player.visual.dark, true); player.dark = true; compare(player.visual.dark, true);
        var weather = createTemporaryObject(preview, test, {widgetType: "weather", widgetStyle: "normal", dark: false});
        compare(weather.visual.dark, true); compare(String(weather.visual.fg), "#ffffff");
    }
}
