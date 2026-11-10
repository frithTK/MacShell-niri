.pragma library

function stubIds() {
    return ["file", "edit", "view", "window", "help"];
}

function isMenuId(id) {
    var name = String(id || "");
    if (name === "apple" || name === "app")
        return true;
    if (stubIds().indexOf(name) >= 0)
        return true;
    return name.indexOf("appmenu:") === 0;
}

function menuKey(id) {
    var name = String(id || "");
    if (name.indexOf("appmenu:") === 0)
        return name.slice(8);
    return "";
}

function titles(appName, exported, menus, labels) {
    var out = [
        { id: "apple", label: "" },
        { id: "app", label: appName || "", bold: true }
    ];
    if (exported && menus && menus.length) {
        for (var i = 0; i < menus.length; i++) {
            var menu = menus[i] || {};
            out.push({
                id: "appmenu:" + String(menu.id !== undefined ? menu.id : i),
                label: String(menu.label || ""),
                exported: true
            });
        }
        return out;
    }
    out.push({ id: "file", label: labels.file });
    out.push({ id: "edit", label: labels.edit });
    out.push({ id: "view", label: labels.view });
    out.push({ id: "window", label: labels.window });
    out.push({ id: "help", label: labels.help });
    return out;
}

function popupType(name) {
    if (name === "apple")
        return "appleMenu";
    if (isMenuId(name))
        return "appMenus";
    return "";
}

function findMenu(menus, key) {
    if (!menus)
        return null;
    for (var i = 0; i < menus.length; i++) {
        if (String(menus[i].id) === String(key))
            return menus[i];
    }
    return null;
}

function ids(rows) {
    var out = [];
    for (var i = 0; i < rows.length; i++)
        out.push(rows[i].id);
    return out;
}
