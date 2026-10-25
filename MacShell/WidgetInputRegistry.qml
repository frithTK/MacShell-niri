import QtQuick

Item {
    id: root
    property string outputName: ""
    property Item surfaceItem: null
    property bool editing: false
    property bool blocked: false
    property var targets: []
    readonly property var activeTargets: {
        if (!enabled || editing || blocked) return [];
        return targets.filter((target, index) => target && target.active && target.outputName === outputName
            && !targets.slice(index + 1).some(other => other && other.instanceId === target.instanceId && other.outputName === target.outputName));
    }
    function acquire(target) { if (targets.indexOf(target) < 0) targets = targets.concat([target]); }
    function release(target) { targets = targets.filter(item => item !== target); }
    function accepts(x, y) {
        if (!enabled || blocked) return false;
        if (editing) return surfaceItem && x >= 0 && y >= 0 && x < surfaceItem.width && y < surfaceItem.height;
        return activeTargets.some(target => {
            var r = target.rect;
            return x >= Math.floor(r.x) && y >= Math.floor(r.y) && x < Math.ceil(r.x + r.width) && y < Math.ceil(r.y + r.height);
        });
    }
}
