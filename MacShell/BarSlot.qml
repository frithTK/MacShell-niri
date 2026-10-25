import QtQuick

Item {
    required property string blockType
    required property var plan
    readonly property var placement: plan.byType[blockType] || ({width: 0, x: 0, mode: 0})
    x: placement.x
    width: placement.width
    height: 28
    visible: width > 0
    clip: true
}
