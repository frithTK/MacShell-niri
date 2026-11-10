IpcHandler {
    target: "ccprobe"
    function state(): string {
        return JSON.stringify(macBar.demoUi ? macBar.demoUi.controlCenterProbe() : {ready: false});
    }
    function theme(dark: bool): void {
        if (macBar.demoUi) macBar.demoUi.pop = "";
        var wall = Quickshell.env(dark ? "MACSHELL_SHOWCASE_DARK_WALL" : "MACSHELL_SHOWCASE_LIGHT_WALL");
        macBar.wallpaperPath = wall; macDock.wallpaperPath = wall; macDock.darkMode = dark;
    }
    function shutDown(): void { Qt.quit(); }
}
