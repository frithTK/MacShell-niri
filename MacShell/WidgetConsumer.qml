import QtQuick

Item {
    id: root
    property var registry: null
    property var owner: null
    property string instanceId: ""
    property string widgetType: ""
    property string outputName: ""
    property string secondsMode: "smooth"
    property bool active: false
    property bool lyricsOpen: false
    function attach() {
        if (owner && owner !== registry) owner.release(root);
        owner = registry;
        if (owner) owner.acquire(root);
    }
    onRegistryChanged: attach()
    Component.onCompleted: attach()
    Component.onDestruction: if (owner) owner.release(root)
}
