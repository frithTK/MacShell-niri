IpcHandler {
    target: "dockprobe"
    function state(): string {
        return JSON.stringify(macDock.demoUi ? macDock.demoUi.dockProbe() : {ready: false});
    }
    function theme(dark: bool): void {
        if (macBar.demoUi) macBar.demoUi.pop = "";
        if (macDock.demoUi) macDock.demoUi.menuItem = null;
        var wall = Quickshell.env(dark ? "MACSHELL_SHOWCASE_DARK_WALL" : "MACSHELL_SHOWCASE_LIGHT_WALL");
        macBar.wallpaperPath = wall; macDock.wallpaperPath = wall; macDock.darkMode = dark;
    }
    function hideMode(mode: string): void { macDock.hideMode = mode; }
    function hideDelay(ms: int): void { macDock.hideDelay = ms; }
    function prefs(on: bool): void {
        if (on) macDock.openPrefs();
        else if (macDock.demoSettings) macDock.demoSettings().visible = false;
    }
    function shutDown(): void { Qt.quit(); }
}
