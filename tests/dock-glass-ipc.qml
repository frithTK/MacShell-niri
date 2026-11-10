IpcHandler {
    target: "dockglass"
    function state(): string {
        return JSON.stringify(macDock.demoUi ? macDock.demoUi.dockGlassProbe() : {ready: false});
    }
    function theme(dark: bool): void {
        var wall = Quickshell.env(dark ? "MACSHELL_SHOWCASE_DARK_WALL" : "MACSHELL_SHOWCASE_LIGHT_WALL");
        macBar.wallpaperPath = wall; macDock.wallpaperPath = wall; macDock.darkMode = dark;
    }
    function shutDown(): void { Qt.quit(); }
}
