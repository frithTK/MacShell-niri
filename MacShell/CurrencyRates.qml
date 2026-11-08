import QtQuick
import "Locale" as Language
import Quickshell
import Quickshell.Io
import "CurrencyData.js" as Data

Scope {
    id: root
    property bool enabled: false
    property var snapshot: ({})
    property bool loading: false
    property bool saved: false
    property string error: ""
    property string warning: ""
    property int epoch: 0
    property bool stopping: false
    property bool restartWanted: false
    readonly property bool available: Object.keys(snapshot.rates || {}).length > 1
    readonly property var units: Data.units(snapshot)
    readonly property double checkedAt: snapshot.fetchedAt || 0
    readonly property int processId: request.running ? request.processId : 0
    readonly property string status: loading ? (available ? Language.I18n.text("ui.t_1a9fcf78f03b") : Language.I18n.text("ui.t_f39854cec420"))
        : error ? (available ? Language.I18n.text("ui.t_0f4ce14ca373") : Language.I18n.text("ui.t_12ccf0382fab"))
        : available ? (saved ? Language.I18n.text("ui.t_a8197c82243f") : Language.I18n.text("ui.t_c3ced8005a03")) : Language.I18n.text("ui.t_d77a2b373c2a")
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("currency-fetch.sh").toString().replace(/^file:\/\//, ""))
    function schedule(delay) { if (enabled) { refreshTimer.interval = Math.max(1000, delay); refreshTimer.restart(); } }
    function refresh(force) {
        if (!enabled) return;
        if (stopping) { restartWanted = true; return; }
        if (loading || request.running) return;
        refreshTimer.stop();
        var age = Date.now() - checkedAt;
        if (!force && available && age >= 0 && age < 3600000) { schedule(3600000 - age); return; }
        epoch++; error = ""; warning = ""; loading = true;
        request.command = ["sh", helper, String(epoch)].concat(force ? ["--refresh"] : []);
        request.running = true; watchdog.restart();
    }
    function accept(text) {
        var message;
        try { message = JSON.parse(text); } catch (error) { return; }
        if (!enabled || message.epoch !== epoch) return;
        if (message.type === "cache") { snapshot = message.snapshot; saved = true; }
        else if (message.type === "result") {
            watchdog.stop(); loading = false;
            if (message.success) {
                snapshot = message.snapshot; saved = !!message.cached; error = ""; warning = message.warning || "";
                schedule(Math.max(1000, 3600000 - (Date.now() - checkedAt)));
            } else { error = message.error || Language.I18n.text("ui.t_d1f6405fe03a"); schedule(300000); }
        }
    }
    onEnabledChanged: {
        if (enabled) Qt.callLater(() => refresh(false));
        else {
            epoch++; refreshTimer.stop(); watchdog.stop(); loading = false; restartWanted = false;
            if (request.running) stopping = true;
            request.running = false;
        }
    }
    Component.onCompleted: if (enabled) refresh(false)
    Process {
        id: request
        stdout: SplitParser { onRead: line => root.accept(line) }
        onExited: (code, status) => {
            if (root.stopping) {
                root.stopping = false;
                if (root.restartWanted && root.enabled) { root.restartWanted = false; Qt.callLater(() => root.refresh(false)); }
                return;
            }
            if (root.enabled && root.loading) {
                watchdog.stop(); root.loading = false; root.error = "Exchange rate request ended unexpectedly."; root.schedule(300000);
            }
        }
    }
    Timer { id: refreshTimer; onTriggered: root.refresh(false) }
    Timer {
        id: watchdog; interval: 25000
        onTriggered: {
            root.epoch++; root.stopping = request.running; request.running = false; root.loading = false;
            root.error = "Exchange rate request timed out."; root.schedule(300000);
        }
    }
}
