                function controlCenterProbe() {
                    function named(item, name) {
                        if (!item || !name) return null;
                        if (item.objectName === name) return item;
                        var kids = item.children;
                        if (!kids) return null;
                        for (var i = 0; i < kids.length; i++) {
                            var found = named(kids[i], name);
                            if (found) return found;
                        }
                        return null;
                    }
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
                        var g = item.mapToGlobal(0, 0);
                        return {
                            x: p.x, y: p.y, width: item.width, height: item.height,
                            gx: g.x, gy: g.y, z: item.z, visible: item.visible !== false,
                            opacity: item.opacity, shown: shown(item)
                        };
                    }
                    function parentName(item) {
                        if (!item || !item.parent) return "";
                        if (item.parent === cc) return "cc";
                        if (item.parent === ui) return "ui";
                        return item.parent.objectName || "";
                    }
                    function flick(item) {
                        if (!item) return null;
                        var p = item.mapToItem(ui, 0, 0);
                        return {
                            x: p.x, y: p.y, width: item.width, height: item.height,
                            contentY: item.contentY, contentHeight: item.contentHeight,
                            interactive: item.interactive, visible: item.visible !== false
                        };
                    }
                    var siblings = [];
                    for (var i = 0; i < cc.children.length; i++) {
                        var child = cc.children[i];
                        if (child.visible === false) continue;
                        siblings.push({name: child.objectName || "", z: child.z, y: child.y, height: child.height});
                    }
                    return {
                        ready: true,
                        pop: pop,
                        anchorType: anchorType,
                        embedded: networkEmbedded,
                        dark: root.darkMode,
                        effDark: root.effDark,
                        focus: activeFocus,
                        ccOpen: cc.openT,
                        glass: root.glassState,
                        screenW: win.modelData.width,
                        screenH: win.modelData.height,
                        layerW: ui.width,
                        layerH: ui.height,
                        wifiParent: parentName(wifiPop),
                        btParent: parentName(btPop),
                        wifi: box(wifiPop),
                        bt: box(btPop),
                        cc: box(cc),
                        targets: {
                            cc: box(ccBtn),
                            barWifi: box(wifiBtn),
                            barBt: box(btBtn),
                            ccWifi: box(named(cc, "controlCenterWifiPage")),
                            ccBt: box(named(cc, "controlCenterBluetoothPage")),
                            wifiBack: box(wifiBack),
                            btBack: box(named(btPop, "bluetoothBackButton"))
                        },
                        wifiScroll: flick(named(wifiPop, "wifiPageScroll")),
                        wifiList: flick(wifiFlick),
                        btScroll: flick(named(btPop, "bluetoothPageScroll")),
                        siblings: siblings
                    };
                }
