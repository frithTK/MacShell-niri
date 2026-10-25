import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/WidgetCatalog.js" as Catalog

TestCase {
    id: test
    name: "WidgetGallery"; when: windowShown
    width: 720; height: 1100; visible: true
    ListModel { id: placed }
    QtObject {
        id: backend
        property bool ready: true
        readonly property bool editable: ready && !readOnly && !pending
        readonly property bool settingsEditable: editable
        property bool readOnly: false
        property bool pending: false
        property bool canRecover: false
        property int recoveries: 0
        property string error: ""
        property string notice: ""
        property bool editing: false
        property bool widgetsEnabled: true
        function setWidgetsEnabled(value) { widgetsEnabled = value; return true; }
        property bool noRoom: false
        property int rev: 0
        property int adds: 0
        property var lastAdd: []
        property string lastOutput: ""
        property string screenName: "DP-1"
        property var displayChoices: [{name: "DP-1", label: "DP-1"}]
        property var instanceRows: []
        property var undoStack: []
        property bool canUndoDelete: false
        property var unavailableWidgets: []
        property var unplacedWidgets: []
        property string tempUnit: "C"
        property string locMode: "auto"
        property string cityName: ""
        signal mutationFinished(bool success)
        function setWeather(key, value) { backend[key] = value; }
        function reloadSettings() {}
        function recoverSettings() { recoveries++; mutationFinished(true); }
        function count(type) {
            var n = 0;
            for (var i = 0; i < placed.count; i++) if (placed.get(i).type === type) n++;
            return n;
        }
        function addWidget(type, style, size, output) {
            adds++; lastAdd = [type, style, size]; lastOutput = output;
            if (noRoom) return false;
            placed.append({type: type}); rev++; return true;
        }
    }
    Component { id: galleryComponent; Port.WidgetGallery { width: 530; controller: backend; adding: true } }
    Component { id: previewComponent; Port.WidgetPreview {} }
    function init() {
        backend.displayChoices = [{name: "DP-1", label: "DP-1"}]; backend.lastOutput = "";
        placed.clear(); backend.ready = true; backend.editing = false; backend.noRoom = false;
        backend.adds = 0; backend.lastAdd = []; backend.unavailableWidgets = [];
        backend.tempUnit = "C"; backend.locMode = "auto"; backend.cityName = ""; backend.rev++;
        backend.readOnly = false; backend.pending = false; backend.canRecover = false; backend.error = ""; backend.notice = "";
        backend.recoveries = 0; backend.widgetsEnabled = true;
    }
    function test_real_previews_data() {
        var rows = [];
        for (var type of Catalog.types) for (var size of type.sizes) for (var style of type.styles) for (var dark of [false, true])
            rows.push({tag: type.type + "/" + size + "/" + style + "/" + dark, type: type.type, size: size, style: style, dark: dark});
        return rows;
    }
    function test_real_previews(data) {
        var dims = Catalog.dimensions(data.size);
        var item = createTemporaryObject(previewComponent, test, {widgetType: data.type, widgetSize: data.size, widgetStyle: data.style, dark: data.dark, width: dims[0], height: dims[1]});
        verify(item !== null); waitForRendering(item);
        verify(item.visual !== null); compare(item.visual.preview, true);
        compare(item.visual.glassOn, false); compare(item.visual.size, data.size); compare(item.visual.style, data.style);
        compare(item.visual.width, dims[0]); compare(item.visual.height, dims[1]);
        if (data.type === "clock") compare(findChild(item.visual, "clockTick").running, false);
        if (data.type === "calendar") compare(findChild(item.visual, "calendarRollover").running, false);
        if (data.type === "player") compare(item.visual.artUrl, "");
    }
    function test_browsing_is_independent_of_live_settings_and_add_is_explicit() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        mouseClick(findChild(item, "widgetType_player"));
        mouseClick(findChild(item, "widgetSize_large"));
        var style = findChild(item, "widgetStyle");
        style.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(item.selectedStyle, "dark"); compare(backend.adds, 0); compare(placed.count, 0);
        compare(backend.cityName, ""); compare(backend.tempUnit, "C");
        mouseClick(findChild(item, "widgetAdd"));
        compare(backend.lastAdd.join(), "player,dark,large"); compare(backend.adds, 1); compare(placed.count, 1); compare(item.placedCount, 1);
        compare(findChild(item, "widgetSample").visual.preview, true);
    }
    function test_no_room_is_explained_and_loading_disables_add() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        backend.ready = false; compare(findChild(item, "widgetAdd").enabled, false);
        backend.ready = true; backend.noRoom = true;
        mouseClick(findChild(item, "widgetAdd"));
        verify(item.status.indexOf("No room") >= 0); compare(placed.count, 0);
        mouseClick(findChild(item, "widgetSize_small"));
        backend.noRoom = false; mouseClick(findChild(item, "widgetAdd"));
        compare(placed.count, 1);
    }
    function test_arrange_and_shared_weather_settings_use_existing_owner() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        mouseClick(findChild(item, "widgetsEdit")); compare(backend.editing, true);
        mouseClick(findChild(item, "widgetsEdit")); compare(backend.editing, false);
        compare(findChild(item, "widgetWeatherLocation").visible, false);
        mouseClick(findChild(item, "widgetsAdvanced")); waitForRendering(item);
        var location = findChild(item, "widgetWeatherLocation");
        location.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(backend.locMode, "city");
        var city = findChild(item, "widgetWeatherCity"); waitForRendering(item);
        city.forceActiveFocus(); city.text = "Test City"; keyClick(Qt.Key_Tab);
        compare(backend.cityName, "Test City");
        var unit = findChild(item, "widgetWeatherUnit");
        unit.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(backend.tempUnit, "F"); compare(backend.adds, 0);
        compare(findChild(item, "widgetSample").visual.city, "Demo City");
    }
    function test_display_choice_is_simple_and_disconnected_selection_falls_back() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        var choice = findChild(item, "widgetOutput"); compare(choice.visible, false);
        backend.displayChoices = [{name: "DP-1", label: "DP-1"}, {name: "DP-2", label: "DP-2"}];
        waitForRendering(item); compare(choice.visible, true);
        choice.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(item.effectiveOutput, "DP-2"); mouseClick(findChild(item, "widgetAdd")); compare(backend.lastOutput, "DP-2");
        backend.displayChoices = [{name: "DP-1", label: "DP-1"}];
        compare(item.effectiveOutput, "DP-1"); mouseClick(findChild(item, "widgetAdd")); compare(backend.lastOutput, "DP-1");
    }
    function test_unknown_type_has_no_visual_fallback() {
        var item = createTemporaryObject(previewComponent, test, {widgetType: "future-widget"});
        compare(item.definition, null); compare(item.visual, null);
        compare(Catalog.legacyStyle("calendar", "dark"), "liquid");
        compare(Catalog.legacyStyle("player", "dark"), "dark");
    }
    function test_readonly_recovery_is_explicit_and_future_formats_have_no_reset() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        backend.readOnly = true; backend.notice = "Newer format";
        compare(findChild(item, "widgetAdd").enabled, false);
        compare(findChild(item, "widgetWeatherLocation").enabled, false);
        compare(findChild(item, "widgetsRestore").visible, false);
        backend.notice = "Invalid records"; backend.canRecover = true;
        waitForRendering(item); mouseClick(findChild(item, "widgetsRestore"));
        compare(backend.recoveries, 0); compare(item.confirmRecovery, true);
        waitForRendering(item); mouseClick(findChild(item, "widgetsConfirmRestore"));
        compare(backend.recoveries, 1); compare(item.confirmRecovery, false);
    }
    function test_global_visibility_keeps_editor_available_and_disables_arrange() {
        var item = createTemporaryObject(galleryComponent, test); waitForRendering(item);
        var toggle = findChild(item, "widgetsEnabled"); mouseClick(toggle);
        compare(backend.widgetsEnabled, false); compare(findChild(item, "widgetsEdit").enabled, false);
        compare(findChild(item, "widgetAdd").enabled, true);
        mouseClick(toggle); compare(backend.widgetsEnabled, true); compare(findChild(item, "widgetsEdit").enabled, true);
        backend.readOnly = true; compare(toggle.enabled, false);
    }
}
