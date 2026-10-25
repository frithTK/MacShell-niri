.pragma library

function canRefract(clients, output, enabled, overview, frames) {
    if (!enabled || overview) return false;
    var visible = [];
    for (var i = 0; i < clients.length; i++) {
        var window = clients[i];
        if (window.output !== output || !window.workspaceActive) continue;
        if (!window.geometryKnown || !frames[String(window.id)]) return false;
        // IPC focus history is not a complete compositor stacking order. Let
        // the compositor resolve overlapping windows instead of guessing.
        for (var j = 0; j < visible.length; j++) {
            var other = visible[j];
            if (!window.at || !window.size || !other.at || !other.size) return false;
            if (window.at[0] < other.at[0] + other.size[0] && window.at[0] + window.size[0] > other.at[0]
                && window.at[1] < other.at[1] + other.size[1] && window.at[1] + window.size[1] > other.at[1]) return false;
        }
        visible.push(window);
    }
    return true;
}
