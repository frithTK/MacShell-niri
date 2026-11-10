                function dockProbe() {
                    function shown(item) {
                        var o = 1, n = item;
                        while (n) {
                            o *= n.opacity;
                            if (n.visible === false) return 0;
                            if (n === ui) break;
                            n = n.parent;
                        }
                        return o;
                    }
                    function box(item) {
                        if (!item) return null;
                        var p = item.mapToItem(ui, 0, 0);
                        var layerY = win.modelData.height - ui.height;
                        return {
                            x: p.x, y: p.y + layerY, width: item.width, height: item.height,
                            z: item.z, visible: item.visible !== false, opacity: item.opacity, shown: shown(item)
                        };
                    }
                    var cells = {};
                    var launching = [];
                    for (var k in root.launching) launching.push(k);
                    for (var i = 0; i < row.children.length; i++) {
                        var cell = row.children[i];
                        if (!cell || !cell.key || cell.isSep) continue;
                        var b = box(cell);
                        if (!b) continue;
                        b.key = cell.key;
                        b.special = cell.modelData ? (cell.modelData.special || "") : "";
                        b.running = !!(cell.modelData && cell.modelData.running);
                        b.pinned = !!(cell.modelData && cell.modelData.pinned);
                        b.bounceShown = !!cell.bounceShown;
                        b.bounceLift = cell.bounceLift || 0;
                        b.wantBounce = !!cell.wantBounce;
                        b.tipOn = !!cell.tipOn;
                        b.hoverSettled = !!cell.hoverSettled;
                        var tip = cell.tipPanel;
                        b.tip = box(tip);
                        if (tip) {
                            b.tipLive = !!tip.live;
                            b.tipDark = !!tip.dark;
                            b.tipTailH = tip.tailH || 0;
                            b.tipTailW = tip.tailW || 0;
                            b.tipBodyH = tip.bodyH || 0;
                            b.tipK = tip.k || 0;
                            b.tipName = tip.objectName || "";
                            b.tipBlur = !!tip.blurActive;
                        } else {
                            b.tipLive = false;
                            b.tipDark = false;
                            b.tipTailH = 0;
                            b.tipTailW = 0;
                            b.tipBodyH = 0;
                            b.tipK = 0;
                            b.tipName = "";
                            b.tipBlur = false;
                        }
                        cells[cell.key] = b;
                    }
                    var menuItems = [];
                    if (menuCol) {
                        for (var m = 0; m < menuCol.children.length; m++) {
                            var it = menuCol.children[m];
                            if (!it || !it.modelData) continue;
                            var mb = box(it);
                            if (!mb) continue;
                            mb.label = it.modelData.label || "";
                            mb.kind = it.modelData.kind || "item";
                            mb.disabled = it.off === true;
                            mb.confirm = it.modelData.confirm === true;
                            mb.armed = it.armedNow === true;
                            menuItems.push(mb);
                        }
                    }
                    var prefs = null;
                    try { prefs = root.demoSettings ? root.demoSettings() : prefsWindow; } catch (err) { prefs = prefsWindow; }
                    var menuBox = box(menu);
                    if (menuBox) {
                        menuBox.live = !!menu.live;
                        menuBox.dark = !!menu.dark;
                        menuBox.frozen = !!menu.frozen;
                        menuBox.hold = !!menu.hold;
                        menuBox.tailH = menu.tailH || 0;
                        menuBox.tailW = menu.tailW || 0;
                        menuBox.tailX = menu.tailX || 0;
                        menuBox.bodyH = menu.bodyH || 0;
                        menuBox.k = menu.k || 0;
                        menuBox.blurActive = !!menu.blurActive;
                        menuBox.name = menu.objectName || "";
                    }
                    return {
                        ready: root.settingsReady && root.dockEnabled && root.trashReady,
                        dark: root.darkMode,
                        glass: root.glassState,
                        liquidActive: !!root.liquidActive,
                        dockStyle: root.dockStyle,
                        showLabels: !!root.showLabels,
                        labelK: root.labelK,
                        screenW: win.modelData.width,
                        screenH: win.modelData.height,
                        layerW: ui.width,
                        layerH: ui.height,
                        layerY: win.modelData.height - ui.height,
                        menuOpen: ui.menuOpen,
                        armed: ui.armed,
                        tucked: ui.tucked,
                        revealed: ui.revealed,
                        hideMode: root.hideMode,
                        hideDelay: root.hideDelay,
                        bounceOnLaunch: root.bounceOnLaunch,
                        prefs: !!(prefs && prefs.visible),
                        trashFull: root.trashFull,
                        trashReady: root.trashReady,
                        launching: launching,
                        dock: box(dock),
                        menu: menuBox,
                        cells: cells,
                        menuItems: menuItems
                    };
                }
