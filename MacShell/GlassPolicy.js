.pragma library

function wallpaperLayer(backdrop) {
    return backdrop || null;
}

function canRefract(clients, output, enabled, overview, frames) {
    if (!enabled || overview) return false;
    var visible = [];
    for (var i = 0; i < clients.length; i++) {
        var window = clients[i];
        if (window.output !== output || !window.workspaceActive) continue;
        if (window.geometryKnown && window.hidden) continue;
        if (!window.geometryKnown || !frames[String(window.id)]) return false;
        // niri draws floating windows above the scrolling layout and raises
        // the focused floating window. Any other overlap has no known order in
        // IPC, so let the compositor resolve it instead of guessing.
        for (var j = 0; j < visible.length; j++) {
            var other = visible[j];
            if (!window.at || !window.size || !other.at || !other.size) return false;
            if (window.at[0] < other.at[0] + other.size[0] && window.at[0] + window.size[0] > other.at[0]
                && window.at[1] < other.at[1] + other.size[1] && window.at[1] + window.size[1] > other.at[1]) {
                if (!!window.floating !== !!other.floating) continue;
                if (window.floating && (window.focusHistoryID === 0 || other.focusHistoryID === 0)) continue;
                return false;
            }
        }
        visible.push(window);
    }
    return true;
}
