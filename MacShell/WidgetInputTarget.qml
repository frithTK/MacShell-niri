import QtQuick

MappedRect {
    id: root
    property string instanceId: ""
    property string outputName: ""
    property bool interactive: false
    property var nativeRegion: null
    property var registry: null
    property var owner: null
    readonly property bool active: !!sourceItem && sourceItem.enabled && interactive && effectiveOpacity > .001 && rect.width > 0 && rect.height > 0
    function attach() {
        if (owner && owner !== registry) owner.release(root);
        owner = registry;
        if (owner) owner.acquire(root);
    }
    onRegistryChanged: attach()
    Component.onCompleted: attach()
    Component.onDestruction: if (owner) owner.release(root)
}
