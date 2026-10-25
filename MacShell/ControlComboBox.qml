import QtQuick
import QtQuick.Controls
import QtQuick.Effects

ComboBox {
    id: root
    implicitHeight: 34
    font.pixelSize: 12
    contentItem: Text {
        leftPadding: 12; rightPadding: 32
        text: root.displayText; font: root.font; color: root.palette.buttonText
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
    }
    indicator: Text {
        x: root.width - width - 12; anchors.verticalCenter: parent.verticalCenter
        text: "⌃\n⌄"; font.pixelSize: 9; lineHeight: .8; color: root.palette.buttonText
    }
    background: Rectangle {
        radius: 8; color: root.palette.base; border.width: 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(.5, .5, .5, .16)
    }
    delegate: ItemDelegate {
        id: row
        required property int index
        width: root.popup.availableWidth; height: 32
        highlighted: root.highlightedIndex === index
        contentItem: Item {
            Text { x: 4; anchors.verticalCenter: parent.verticalCenter; text: "✓"; visible: row.index === root.currentIndex; font.pixelSize: 12; color: row.highlighted ? "white" : root.palette.text }
            Text { x: 24; width: parent.width - 28; anchors.verticalCenter: parent.verticalCenter; text: root.textAt(row.index); font: root.font; elide: Text.ElideRight; color: row.highlighted ? "white" : root.palette.text }
        }
        background: Rectangle { radius: 6; color: row.highlighted ? root.palette.highlight : "transparent" }
    }
    popup: Popup {
        y: root.height + 5
        width: root.width
        height: Math.min(contentItem.implicitHeight + topPadding + bottomPadding, 260)
        padding: 6
        margins: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 100 } }
        background: Item {
            RectangularShadow { anchors.fill: parent; radius: 11; blur: 20; offset.y: 5; color: Qt.rgba(0, 0, 0, .25) }
            Rectangle { anchors.fill: parent; radius: 11; color: root.palette.window; border.color: Qt.rgba(.5, .5, .5, .25) }
        }
        contentItem: ListView {
            implicitHeight: contentHeight
            clip: true
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            boundsBehavior: Flickable.StopAtBounds
            ScrollIndicator.vertical: ScrollIndicator { }
        }
    }
}
