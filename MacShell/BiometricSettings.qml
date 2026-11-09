import QtQuick
import Quickshell
import Quickshell.Io
import "Locale" as Language

ControlMenu {
    id: root
    objectName: "biometricSettings"
    property string status: "checking"
    property var devices: []
    property int selectedDeviceIndex: 0
    property string refreshDevicePath: ""
    readonly property string selectedFinger: fingerSelection.currentIndex >= 0 && fingerSelection.currentIndex < fingers.length ? fingers[fingerSelection.currentIndex] : ""
    property string confirmAction: ""
    property string operationCode: ""
    property int stage: 0
    property int total: 0
    property bool gotResult: false
    property bool cancelling: false
    property bool cleanupFailed: false
    property string operationAction: ""
    property var fingerPresent: null
    readonly property var selectedDevice: devices.length > selectedDeviceIndex ? devices[selectedDeviceIndex] : null
    readonly property bool selectedEnrolled: selectedDevice && selectedDevice.enrollment === "ok" && selectedDevice.fingers.indexOf(selectedFinger) >= 0
    readonly property var fingers: ["left-thumb", "left-index-finger", "left-middle-finger", "left-ring-finger", "left-little-finger", "right-thumb", "right-index-finger", "right-middle-finger", "right-ring-finger", "right-little-finger"]
    function fingerName(id) {
        switch (id) {
        case "left-thumb": return Language.I18n.text("security.finger.left_thumb");
        case "left-index-finger": return Language.I18n.text("security.finger.left_index_finger");
        case "left-middle-finger": return Language.I18n.text("security.finger.left_middle_finger");
        case "left-ring-finger": return Language.I18n.text("security.finger.left_ring_finger");
        case "left-little-finger": return Language.I18n.text("security.finger.left_little_finger");
        case "right-thumb": return Language.I18n.text("security.finger.right_thumb");
        case "right-index-finger": return Language.I18n.text("security.finger.right_index_finger");
        case "right-middle-finger": return Language.I18n.text("security.finger.right_middle_finger");
        case "right-ring-finger": return Language.I18n.text("security.finger.right_ring_finger");
        case "right-little-finger": return Language.I18n.text("security.finger.right_little_finger");
        default: return id;
        }
    }
    function refresh() {
        if (probe.running || operation.running) return;
        refreshDevicePath = selectedDevice ? selectedDevice.path : "";
        status = "checking"; devices = []; confirmAction = "";
        probe.running = true; timeout.restart();
    }
    function startOperation(action) {
        if (probe.running || operation.running || !selectedDevice || selectedDevice.enrollment !== "ok") return;
        if (action !== "enroll" && action !== "verify" && action !== "delete") return;
        confirmAction = ""; gotResult = false; cancelling = false; cleanupFailed = false; operationCode = "checking"; operationAction = action; fingerPresent = null; stage = 0; total = 0;
        operation.command = ["sh", decodeURIComponent(Qt.resolvedUrl("fingerprint-operation.sh").toString().replace(/^file:\/\//, "")), action, selectedDevice.path, selectedFinger];
        operation.running = true; operationTimeout.restart();
    }
    function message() {
        if (status === "checking") return Language.I18n.text("security.checking");
        if (status === "no_device") return Language.I18n.text("security.no_device");
        if (status === "device_error") return Language.I18n.text("security.device_error");
        return Language.I18n.text("security.service_unavailable");
    }
    function operationText(code) {
        switch (code) {
        case "checking": return Language.I18n.text("security.working");
        case "cancelling": return Language.I18n.text("security.cancelling");
        case "scan": case "enroll-stage-passed":
            return Language.I18n.text(root.selectedDevice && root.selectedDevice.scanType === "swipe" ? "security.scan_swipe"
                : root.selectedDevice && root.selectedDevice.scanType === "press" ? "security.scan_press" : "security.scan");
        case "enroll-retry-scan": case "verify-retry-scan": return Language.I18n.text("security.retry_scan");
        case "enroll-swipe-too-short": case "verify-swipe-too-short": return Language.I18n.text("security.too_short");
        case "enroll-too-fast": case "verify-too-fast": return Language.I18n.text("security.too_fast");
        case "enroll-finger-not-centered": case "verify-finger-not-centered": return Language.I18n.text("security.center");
        case "enroll-remove-and-retry": case "verify-remove-and-retry": return Language.I18n.text("security.remove_retry");
        case "enroll-completed": return Language.I18n.text("security.enrolled");
        case "verify-match": return Language.I18n.text("security.matched");
        case "verify-no-match": return Language.I18n.text("security.no_match");
        case "deleted": return Language.I18n.text("security.deleted");
        case "cancelled": return Language.I18n.text("security.cancelled");
        case "timeout": return Language.I18n.text("security.timeout");
        case "busy": return Language.I18n.text("security.busy");
        case "permission": return Language.I18n.text("security.permission");
        case "already_enrolled": return Language.I18n.text("security.already_enrolled");
        case "no_finger": return Language.I18n.text("security.no_finger");
        case "device_gone": return Language.I18n.text("security.device_gone");
        case "driver_error": return Language.I18n.text("security.driver_error");
        case "enroll-data-full": return Language.I18n.text("security.data_full");
        case "enroll-duplicate": return Language.I18n.text("security.duplicate");
        case "": return "";
        default: return Language.I18n.text("security.operation_error");
        }
    }
    Component.onCompleted: refresh()
    Process {
        id: probe
        command: [decodeURIComponent(Qt.resolvedUrl("biometric-probe.sh").toString().replace(/^file:\/\//, ""))]
        stdout: StdioCollector {
            onStreamFinished: {
                timeout.stop();
                try {
                    var result = JSON.parse(text);
                    if (["ok", "no_device", "device_error", "service_unavailable"].indexOf(result.status) < 0 || !Array.isArray(result.devices)) throw new Error("invalid status");
                    root.status = result.status; root.devices = result.devices;
                    var index = root.devices.findIndex(device => device.path === root.refreshDevicePath);
                    root.selectedDeviceIndex = index >= 0 ? index : 0;
                } catch (error) { root.status = "service_unavailable"; root.devices = []; }
            }
        }
        onExited: if (root.status === "checking") { timeout.stop(); root.status = "service_unavailable"; }
    }
    Process {
        id: operation
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    var message = JSON.parse(line);
                    if (message.type === "status" && !root.cancelling) { root.operationCode = message.code; root.stage = message.stage || 0; root.total = message.total || 0; }
                    if (message.type === "finger-presence" && !root.cancelling && !root.gotResult && (message.present === true || message.present === false || message.present === null)) root.fingerPresent = message.present;
                    if (message.type === "result") { root.operationCode = message.code; root.cleanupFailed = !!message.cleanupFailed; root.gotResult = true; }
                } catch (error) { root.operationCode = "service_error"; }
            }
        }
        onExited: {
            operationTimeout.stop();
            if (!root.gotResult) root.operationCode = "service_error";
            root.refresh();
        }
    }
    Timer { id: timeout; interval: 12000; onTriggered: { probe.running = false; root.status = "service_unavailable"; } }
    Timer { id: operationTimeout; interval: 145000; onTriggered: { operation.running = false; root.operationCode = "timeout"; root.gotResult = true; } }
    contentItem: Column {
        spacing: 14
        Text { width: parent.width; text: Language.I18n.text("security.intro"); color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        Text { text: Language.I18n.text("security.fingerprint"); color: root.foreground; font.family: root.font.family; font.pixelSize: root.font.pixelSize; font.bold: true }
        Text { width: parent.width; visible: root.status !== "ok"; text: root.message(); color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        Text { visible: root.devices.length > 1; text: Language.I18n.text("security.choose_reader"); color: root.foreground; font: root.font }
        ControlComboBox { visible: root.devices.length > 1; width: parent.width; model: root.devices; textRole: "name"; currentIndex: root.selectedDeviceIndex; enabled: !operation.running; onActivated: index => { root.selectedDeviceIndex = index; root.confirmAction = ""; } }
        Text { objectName: "biometricDeviceName"; visible: !!root.selectedDevice; width: parent.width; text: root.selectedDevice ? root.selectedDevice.name : ""; textFormat: Text.PlainText; color: root.foreground; wrapMode: Text.Wrap; font: root.font }
        Text { objectName: "biometricEnrollment"; visible: !!root.selectedDevice; width: parent.width; text: !root.selectedDevice ? "" : root.selectedDevice.enrollment === "ok" ? Language.I18n.text("security.registered", {count: root.selectedDevice.fingers.length}) : Language.I18n.text("security.unknown"); color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        Text { visible: root.status === "ok"; text: Language.I18n.text("security.choose_finger"); color: root.foreground; font: root.font }
        ControlComboBox {
            id: fingerSelection
            objectName: "fingerSelection"; visible: root.status === "ok"; width: parent.width
            model: root.fingers
            labelForIndex: index => {
                var id = root.fingers[index] || "";
                return root.fingerName(id) + (root.selectedDevice && root.selectedDevice.enrollment === "ok" && root.selectedDevice.fingers.indexOf(id) >= 0 ? " ✓" : "");
            }
            currentIndex: 6; enabled: !operation.running
            onActivated: root.confirmAction = ""
        }
        Row {
            visible: root.status === "ok" && root.confirmAction === "" && !operation.running; spacing: 8
            ControlButton { objectName: "fingerAdd"; text: Language.I18n.text("security.add"); enabled: root.selectedDevice && root.selectedDevice.enrollment === "ok" && !root.selectedEnrolled; onClicked: root.confirmAction = "enroll" }
            ControlButton { objectName: "fingerTest"; text: Language.I18n.text("security.test"); enabled: !!root.selectedEnrolled; onClicked: root.startOperation("verify") }
            ControlButton { objectName: "fingerDelete"; text: Language.I18n.text("security.delete"); enabled: !!root.selectedEnrolled; onClicked: root.confirmAction = "delete" }
        }
        Text { objectName: "fingerConfirmation"; visible: root.confirmAction !== ""; width: parent.width; text: root.confirmAction === "enroll" ? Language.I18n.text("security.confirm_enroll") : Language.I18n.text("security.confirm_delete"); color: root.warning; wrapMode: Text.Wrap; font: root.font }
        Row {
            visible: root.confirmAction !== ""; spacing: 8
            ControlButton { objectName: "fingerConfirm"; text: Language.I18n.text("security.confirm"); primary: true; onClicked: root.startOperation(root.confirmAction) }
            ControlButton { text: Language.I18n.text("common.cancel"); onClicked: root.confirmAction = "" }
        }
        Text { objectName: "fingerOperationStatus"; visible: root.operationCode !== ""; width: parent.width; text: root.operationText(root.operationCode); color: root.foreground; wrapMode: Text.Wrap; font: root.font }
        Text { visible: root.cleanupFailed; width: parent.width; text: Language.I18n.text("security.cleanup_failed"); color: root.warning; wrapMode: Text.Wrap; font: root.font }
        FingerprintScanVisual {
            objectName: "fingerprintScanVisual"; width: parent.width
            visible: operation.running && root.operationAction === "enroll" && !root.gotResult && !root.cancelling
            running: visible; dark: root.dark; family: root.font.family; fingerPresent: root.fingerPresent
            stage: root.stage; total: root.total
            statusText: Language.I18n.text(root.fingerPresent === true ? "security.finger_present" : root.fingerPresent === false ? "security.finger_wait" : "security.finger_unknown")
            progressText: Language.I18n.text("security.progress", {stage: root.stage, total: root.total})
        }
        ControlButton { objectName: "fingerCancel"; visible: operation.running; enabled: !root.cancelling; text: Language.I18n.text("common.cancel"); onClicked: { root.cancelling = true; root.operationCode = "cancelling"; operation.write("cancel\n"); } }
        Text { width: parent.width; text: Language.I18n.text("security.unlock_pending"); color: root.secondary; wrapMode: Text.Wrap; font: root.font }
        ControlButton { text: Language.I18n.text("security.refresh"); enabled: !probe.running && !operation.running; onClicked: root.refresh() }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Text { text: Language.I18n.text("security.face"); color: root.foreground; font.family: root.font.family; font.pixelSize: root.font.pixelSize; font.bold: true }
        Text { width: parent.width; text: Language.I18n.text("security.face_pending"); color: root.secondary; wrapMode: Text.Wrap; font: root.font }
    }
}
