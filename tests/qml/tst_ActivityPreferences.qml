import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/PreferenceFields.js" as Fields

TestCase {
    id: test
    name: "ActivityPreferences"
    when: windowShown
    width: 800; height: 1700; visible: true
    QtObject {
        id: backend
        property bool ready: true
        property bool pending: false
        property bool readOnly: false
        property bool canRecover: false
        property bool needsRepair: false
        property bool migrationPending: false
        property string notice: ""
        property string error: ""
        property string token: "initial"
        property int revision: 0
        property int saves: 0
        property int recoveries: 0
        property var values: ({})
        property var submitted: null
        property var fields: [
            {key: "cpuWarning", label: "CPU warning", description: "CPU amber threshold", keywords: "processor процессор порог", type: "integer", default: 65, minimum: 0, maximum: 99, lessThan: "cpuCritical", advanced: true},
            {key: "cpuCritical", label: "CPU critical", description: "CPU red threshold", keywords: "processor красный порог", type: "integer", default: 90, minimum: 1, maximum: 100, advanced: true},
            {key: "palette", label: "Icon colors", description: "Load or monochrome colors", keywords: "палитра цвет", type: "choice", default: "system", choices: [{value: "system", label: "Load colors"}, {value: "monochrome", label: "Monochrome"}]},
            {key: "speedUnit", label: "Speed units", description: "Network and disk rate units", keywords: "скорость сеть диск", type: "choice", default: "decimal", choices: [{value: "decimal", label: "Decimal"}, {value: "binary", label: "Binary"}]},
            {key: "order", label: "Metric order", description: "Resource icon order", keywords: "порядок показатели", type: "order", default: ["cpu", "memory", "network", "disk"], choices: [{value: "cpu", label: "CPU"}, {value: "memory", label: "Memory"}, {value: "network", label: "Network"}, {value: "disk", label: "Disk"}]}
        ]
        signal finished(bool success)
        function refresh() { }
        function save(next, expected) {
            saves++;
            submitted = Fields.clone(next);
            if (expected !== token) { error = "Changed elsewhere"; finished(false); return; }
            values = Fields.clone(next); revision++; token = "saved" + revision;
            needsRepair = false; migrationPending = false;
            finished(true);
        }
        function recover(expected) {
            recoveries++; readOnly = false; canRecover = false;
            values = Fields.defaults(fields); token = "recovered"; finished(true);
        }
    }
    Component { id: editorComponent; Port.ActivityPreferencesEditor { controller: backend; width: 580 } }
    function init() {
        backend.values = Fields.defaults(backend.fields);
        backend.token = "initial"; backend.revision = 0;
        backend.ready = true; backend.readOnly = false; backend.canRecover = false;
        backend.pending = false; backend.error = ""; backend.notice = "";
        backend.needsRepair = false; backend.migrationPending = false;
        backend.saves = 0; backend.recoveries = 0; backend.submitted = null;
    }
    function test_cancel_reset_and_preview_have_no_side_effects() {
        var item = createTemporaryObject(editorComponent, test);
        verify(item !== null);
        var preview = findChild(item, "activityAppearancePreview");
        item.change("palette", "monochrome");
        compare(preview.appearance.palette, "monochrome");
        compare(backend.values.palette, "system"); compare(backend.saves, 0);
        item.change("cpuWarning", 20);
        item.resetField(backend.fields[0]);
        compare(item.draft.cpuWarning, 65);
        waitForRendering(item);
        mouseClick(findChild(item, "activityCancel"));
        compare(item.dirty, false); compare(item.draft.palette, "system");
        compare(backend.saves, 0);
        item.change("speedUnit", "binary");
        item.resetAll(); compare(item.dirty, false); compare(backend.saves, 0);
    }
    function test_validation_and_apply() {
        var item = createTemporaryObject(editorComponent, test);
        item.advanced = true;
        item.change("cpuWarning", 95);
        compare(findChild(item, "activityApply").enabled, false);
        verify(item.issues.cpuWarning.length > 0);
        item.change("cpuCritical", 99);
        compare(findChild(item, "activityApply").enabled, true);
        waitForRendering(item);
        mouseClick(findChild(item, "activityApply"));
        compare(backend.saves, 1); compare(backend.submitted.cpuWarning, 95);
        compare(item.dirty, false); compare(item.baseToken, backend.token);
    }
    function test_external_revision_preserves_draft_until_reload() {
        var item = createTemporaryObject(editorComponent, test);
        item.change("palette", "monochrome");
        backend.values = Object.assign({}, backend.values, {cpuWarning: 40});
        backend.token = "external";
        compare(item.conflict, true); compare(item.draft.cpuWarning, 65);
        compare(item.draft.palette, "monochrome");
        compare(findChild(item, "activityApply").enabled, false);
        waitForRendering(item);
        mouseClick(findChild(item, "activityReload"));
        compare(item.conflict, false); compare(item.draft.cpuWarning, 40);
        compare(item.draft.palette, "system"); compare(backend.saves, 0);
    }
    function test_apply_repairs_or_migrates_without_an_unrelated_edit() {
        var item = createTemporaryObject(editorComponent, test);
        compare(item.dirty, false);
        compare(findChild(item, "activityApply").enabled, false);
        for (var flag of ["needsRepair", "migrationPending"]) {
            backend[flag] = true;
            compare(findChild(item, "activityApply").enabled, true);
            waitForRendering(item);
            mouseClick(findChild(item, "activityApply"));
            compare(backend[flag], false);
            compare(findChild(item, "activityApply").enabled, false);
        }
        compare(backend.saves, 2);
    }
    function test_order_buttons_and_focus_search_result() {
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item);
        mouseClick(findChild(item, "activityOrderUp_memory"));
        compare(item.draft.order.join(","), "memory,cpu,network,disk");
        compare(backend.values.order.join(","), "cpu,memory,network,disk");
        item.focusKey = "cpuCritical";
        tryCompare(item, "advanced", true);
        tryCompare(item, "highlightedKey", "cpuCritical");
        verify(findChild(item, "activitySetting_cpuCritical") !== null);
        compare(Fields.search(backend.fields, "процессор порог").length, 1);
        compare(Fields.search(backend.fields, "скорость")[0].key, "speedUnit");
        compare(Fields.search(backend.fields, "").length, 0);
    }
    function test_readonly_and_explicit_recovery_in_both_themes() {
        for (var foreground of ["white", "#1d1d1f"]) {
            var previousRecoveries = backend.recoveries;
            backend.readOnly = true; backend.canRecover = true;
            var item = createTemporaryObject(editorComponent, test, {foreground: foreground});
            verify(item !== null);
            compare(findChild(item, "activityApply").enabled, false);
            waitForRendering(item);
            mouseClick(findChild(item, "activityRecovery"));
            compare(backend.recoveries, previousRecoveries); compare(item.confirmRecovery, true);
            waitForRendering(item);
            mouseClick(findChild(item, "activityConfirmRecovery"));
            compare(backend.recoveries, foreground === "white" ? 1 : 2);
            compare(item.confirmRecovery, false);
            item.destroy(); wait(1);
        }
    }
}
