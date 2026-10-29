// Injected into the production ShellRoot; no real notification bus or user data.
property int notificationPhase: 0
property int notificationWaits: 0
property var notificationSample: null
TestEvent { id: notificationEvents }
Component {
    id: notificationFactory
    QtObject {
        id: sample
        property bool tracked: false
        property string appName: "MacShell regression fixture"
        property string summary: "Owned notification"
        property string body: "Click lifetime regression"
        property string appIcon: ""
        property string image: ""
        property int urgency: 1
        property int expireTimeout: 60
        property int behavior: 0
        property int invocations: 0
        property var actions: behavior === 2 ? [] : [action]
        property QtObject action: QtObject {
            property string identifier: "default"
            function invoke() {
                sample.invocations++;
                if (sample.behavior === 1) sample.closed();
                if (sample.behavior === 3) throw new Error("owned action failure");
            }
        }
        signal closed()
        function dismiss() { closed(); }
    }
}
function notificationFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) {
        var match = notificationFind(child, name);
        if (match) return match;
    }
    return null;
}
function notificationCheck(value, reason) {
    if (!value) throw new Error("NOTIFICATIONS_NATIVE_FAIL: " + reason);
}
Timer {
    interval: 350; repeat: true; running: true
    onTriggered: {
        try {
            if (!macBar.settingsReady || !macBar.testUi) {
                if (++notificationWaits > 35) throw new Error("startup timeout");
                return;
            }
            var scenario = Math.floor(notificationPhase / 5), step = notificationPhase % 5;
            if (scenario === 4) {
                notificationCheck(macBar.testHistory.count === 4, "history retained");
                console.log("MACSHELL_NOTIFICATIONS_NATIVE_PASS: default, synchronous close, no action, failed action");
                Qt.quit(); return;
            }
            if (step === 0) {
                notificationSample = notificationFactory.createObject(null, {behavior: scenario});
                macBar.notifReceive(notificationSample);
                notificationCheck(notificationSample.tracked && macBar.testToasts.count === 1, "received own card");
            } else if (step === 3) {
                var target = notificationFind(macBar.testUi, "notificationActivate_" + macBar.notifSeq);
                notificationCheck(target && target.visible && target.width > 0 && target.height > 0, "clickable card");
                notificationEvents.mouseClick(target, target.width / 2, target.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (step === 4) {
                notificationCheck(macBar.testToasts.count === 0, "click removed card");
                notificationCheck(notificationSample.invocations === (scenario === 2 ? 0 : 1), "default action invoked once");
                notificationCheck(macBar.testHistory.count === scenario + 1, "click preserved history");
            }
            notificationPhase++;
        } catch (error) { console.error("NOTIFICATIONS_NATIVE_FAIL", error); Qt.exit(1); }
    }
}
