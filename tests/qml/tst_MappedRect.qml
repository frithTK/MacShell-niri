import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "MappedRect"
    when: windowShown
    width: 1000; height: 800; visible: true
    Item {
        id: frame
        anchors.fill: parent
        Item {
            id: panel
            x: 500; y: 100; width: 400; height: 300
            transformOrigin: Item.TopRight
            Item {
                id: tile
                x: 20; y: 60; width: 100; height: 66
                transform: Translate { id: slide }
            }
        }
        Item { id: alternate; x: 90; y: 30 }
    }
    Port.MappedRect { id: mapping; sourceItem: tile; targetItem: frame }
    function init() {
        tile.parent = panel;
        tile.x = 20; tile.y = 60; tile.width = 100; tile.height = 66;
        panel.x = 500; panel.y = 100; panel.scale = 1; panel.opacity = 1; panel.visible = true;
        slide.x = 0; slide.y = 0;
        mapping.padding = 0;
        wait(1);
    }
    function test_top_right_scale_uses_pivot_and_screen_dimensions() {
        panel.scale = 1.25;
        tryCompare(mapping, "rect", Qt.rect(425, 175, 125, 82.5));
        compare(mapping.scaleX, 1.25); compare(mapping.scaleY, 1.25);
        // Shader UVs at local (40, 20) must sample that same screen position.
        var sourceRect = Qt.rect(320, 20, 600, 500);
        var srcOffsetX = (mapping.rect.x - sourceRect.x) / mapping.scaleX - 10;
        var srcSizeX = sourceRect.width / mapping.scaleX;
        var uv = (40 + 10 + srcOffsetX) / srcSizeX;
        fuzzyCompare(sourceRect.x + uv * sourceRect.width, 475, .001);
    }
    function test_ancestor_motion_and_transform_object_changes_are_live() {
        panel.scale = 1.25;
        slide.y = 16;
        tryCompare(mapping, "rect", Qt.rect(425, 195, 125, 82.5));
        panel.x = 460;
        tryCompare(mapping, "rect", Qt.rect(385, 195, 125, 82.5));
        slide.x = 24;
        tryCompare(mapping, "rect", Qt.rect(415, 195, 125, 82.5));
    }
    function test_padding_maps_in_the_same_coordinate_system() {
        panel.scale = 1.25; mapping.padding = 64;
        tryCompare(mapping, "rect", Qt.rect(345, 95, 285, 242.5));
    }
    function test_reparent_rebuilds_observers() {
        tile.parent = alternate;
        tryCompare(mapping, "rect", Qt.rect(110, 90, 100, 66));
        alternate.x = 110;
        tryCompare(mapping, "rect", Qt.rect(130, 90, 100, 66));
        alternate.x = 90;
    }
    function test_hidden_and_fading_ancestors_release_blur() {
        panel.opacity = .5;
        tryCompare(mapping, "effectiveOpacity", .5);
        panel.visible = false;
        tryCompare(mapping, "effectiveOpacity", 0);
        panel.visible = true; panel.opacity = 0;
        tryCompare(mapping, "effectiveOpacity", 0);
    }
    function test_idle_geometry_does_not_poll_or_animate() {
        var revision = mapping.revision;
        wait(100);
        compare(mapping.revision, revision);
    }
}
