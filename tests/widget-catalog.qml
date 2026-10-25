import QtQuick
import Quickshell
import Quickshell.Io
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property string desired: ""
    property string savedToken: ""
    property string addedId: ""
    QtObject {
        id: fakeHub
        property var dock: null
        property bool widgetsWantWallpaper: false
        property var wallpaperMap: ({})
        function refreshWallpaper() {}
    }
    Port.MacWidgets { id: widgets; hub: fakeHub }
    function check(ok, reason) { if (!ok) throw new Error(reason); }
    FileView {
        id: saved
        path: widgets.configDir + "/settings.json"; printErrors: false
        onLoaded: {
            if (root.phase !== 6) return;
            try {
                var state = JSON.parse(text());
                root.check(state.version === 1 && state.values.widgets.length === 2, "versioned records saved");
                root.check(state.widgets[1].custom.keep === true, "original legacy document retained");
                var unknown = state.values.widgets.find(item => item.id === "future");
                root.check(unknown.size === "wide" && unknown.custom.keep === true, "unknown record fields retained");
                root.check(state.values.defaults.tempUnit === "F", "single owner persisted weather defaults");
                root.phase = 7; widgets.reloadSettings();
            } catch (error) { console.error(error); Qt.exit(1); }
        }
    }
    Timer {
        interval: 200; repeat: true; running: true
        onTriggered: {
            try {
                if (!widgets.ready || widgets.pending) return;
                if (root.phase === 0) {
                    root.check(!widgets.readOnly, widgets.notice);
                    root.check(widgets.model.count === 1 && widgets.model.get(0).wid === "old-clock", "legacy ID retained");
                    root.check(widgets.model.get(0).wstyle === "dark", "existing type style");
                    root.check(widgets.unavailableWidgets.length === 1, "unknown stays unavailable");
                    root.desired = JSON.stringify(widgets.preferences.values.widgets[0].position);
                    root.check(!widgets.addWidget("agenda", "liquid", "small"), "unknown cannot be added");
                    root.check(!widgets.addWidget("weather", "dark", "small"), "unsupported style cannot be added");
                    root.check(widgets.setWeather("tempUnit", "F"), "weather default edit accepted");
                    root.phase = 1;
                } else if (root.phase === 1) {
                    root.check(widgets.tempUnit === "F", widgets.error);
                    root.check(JSON.stringify(widgets.preferences.values.widgets[0].position) === root.desired, "default edit keeps desired cell");
                    root.check(widgets.setSize("old-clock", "medium"), "resize through the owner"); root.phase = 2;
                } else if (root.phase === 2) {
                    root.check(widgets.model.get(0).wsize === "medium", widgets.error);
                    root.check(widgets.moveWidget("old-clock", widgets.model.get(0).wx + 207, widgets.model.get(0).wy), "move through the owner"); root.phase = 3;
                } else if (root.phase === 3) {
                    root.check(widgets.preferences.values.widgets[0].position.column === 1, "desired cell updated by explicit drag");
                    root.check(widgets.addWidget("calendar", "normal", "small"), "add through the owner"); root.phase = 4;
                } else if (root.phase === 4) {
                    root.check(widgets.model.count === 2, widgets.error);
                    root.addedId = widgets.model.get(1).wid;
                    root.check(widgets.removeWidget(root.addedId), "delete through the owner"); root.phase = 5;
                } else if (root.phase === 5) {
                    root.check(widgets.model.count === 1 && widgets.preferences.values.widgets.length === 2, "only the selected instance removed");
                    root.savedToken = widgets.preferences.token; root.phase = 6; saved.reload();
                } else if (root.phase === 7) {
                    root.check(widgets.preferences.token === root.savedToken, "reload makes no write");
                    root.check(widgets.model.count === 1 && widgets.model.get(0).wid === "old-clock", "stable live model after reload");
                    console.log("MACSHELL_WIDGET_CATALOG_PASS"); Qt.quit();
                }
            } catch (error) { console.error(error); Qt.exit(1); }
        }
    }
}
