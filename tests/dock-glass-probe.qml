                function dockGlassProbe() {
                    function findNamed(item, name) {
                        if (!item) return null;
                        if (item.objectName === name) return item;
                        var kids = item.children || [];
                        for (var i = 0; i < kids.length; i++) {
                            var found = findNamed(kids[i], name);
                            if (found) return found;
                        }
                        return null;
                    }
                    var dg = glassLayer && glassLayer.item ? glassLayer.item : null;
                    var fx = findNamed(dg, "dockGlassEffect");
                    var screens = [];
                    var list = Quickshell.screens;
                    for (var s = 0; s < list.length; s++) {
                        screens.push({
                            name: list[s].name,
                            width: list[s].width,
                            height: list[s].height,
                            dockGlassFailed: root.dockGlassFailed,
                            glassShaderUrl: String(root.glassShaderUrl),
                            dockGlassUrl: String(root.dockGlassUrl)
                        });
                    }
                    return {
                        ready: root.settingsReady && root.dockEnabled && root.glassState === "ready" && root.liquidActive,
                        dark: root.darkMode,
                        glassState: root.glassState,
                        liquidActive: root.liquidActive,
                        dockGlassFailed: root.dockGlassFailed,
                        shaderStatus: root.dockGlassShaderStatus,
                        liveStatus: fx ? fx.status : -1,
                        fragmentShader: fx ? String(fx.fragmentShader) : "",
                        dockGlassUrl: String(root.dockGlassUrl),
                        glassShaderUrl: String(root.glassShaderUrl),
                        padPx: dg && dg.padPx !== undefined ? dg.padPx : -1,
                        layerActive: !!(glassLayer && glassLayer.active),
                        captureGlass: win.captureGlass,
                        screenCount: screens.length,
                        screens: screens
                    };
                }
