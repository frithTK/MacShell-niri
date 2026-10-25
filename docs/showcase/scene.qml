// Inserted into a temporary copy of shell.qml. All controls remain production QML.
property bool showcaseReady: macBar.settingsReady && macDock.settingsReady && macWidgets.ready && Niri.connected
    && macBar.demoUi !== null && macBar.glassState === "ready" && macDock.glassState === "ready" && macWidgets.wxReady
property double showcaseStarted: Date.now()
function showcaseHide() {
    macBar.demoUi.pop = "";
    macDock.demoSettings().hide(); clockApp.demoWindow().hide();
    if (macWidgets.editing) macWidgets.finishEditing(false);
}
IpcHandler {
    target: "showcase"
    function state(): string {
        return JSON.stringify({ready: showcaseReady, width: Quickshell.screens.length ? Quickshell.screens[0].width : 0,
            height: Quickshell.screens.length ? Quickshell.screens[0].height : 0,
            bar: macBar.glassState, dock: macDock.glassState, widgets: macWidgets.glassState,
            weather: macWidgets.wxReady, connected: Niri.connected, popup: macBar.demoUi ? macBar.demoUi.pop : "",
            region: macBar.demoUi && macBar.demoUi.pop === "spot" && macBar.demoSpot
                ? {x: macBar.demoSpot.x - 32, y: macBar.demoSpot.y - 32, width: macBar.demoSpot.width + 64, height: macBar.demoSpot.height + 64}
                : macBar.demoUi ? macBar.demoUi.glassRect : {},
            dark: macDock.darkMode, resources: macWidgets.resourceState()});
    }
    function theme(dark: bool): void {
        showcaseHide();
        var wall = Quickshell.env(dark ? "MACSHELL_SHOWCASE_DARK_WALL" : "MACSHELL_SHOWCASE_LIGHT_WALL");
        macBar.wallpaperPath = wall; macDock.wallpaperPath = wall; macDock.darkMode = dark;
    }
    function scene(name: string): void {
        showcaseHide();
        if (name === "desktop") return;
        if (name === "apps") { macBar.demoUi.openPop("spot", 0); macBar.demoUi.spSetMode("apps"); }
        else if (name === "spotlight") { macBar.demoUi.openPop("spot", 0); macBar.demoUi.spInputText("fi"); }
        else if (name === "clock") clockApp.open("world");
        else if (["widgets", "appearance", "barlayout", "activity"].indexOf(name) >= 0) {
            var settings = macDock.demoSettings(); settings.minimumHeight = 800; settings.maximumHeight = 800; settings.height = 800;
            macDock.openPrefs(name);
        }
        else if (name === "arrange") { macWidgets.editing = true; macWidgets.selectWidget("player"); }
        else macBar.demoUi.openPop(name, name === "stats" ? 950 : 1350);
    }
    function query(value: string): void { macBar.demoUi.spQuery = value; }
    function shutDown(): void { Qt.quit(); }
}
