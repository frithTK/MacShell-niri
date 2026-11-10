import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/ImageWidgetData.js" as ImageData

TestCase {
    id: test
    name: "ImageWidget"; when: windowShown
    width: 500; height: 500; visible: true
    Component { id: cardComponent; Port.ImageWidget { style: "normal"; size: "small"; preview: true } }
    function test_rejects_network_and_relative_paths() {
        verify(ImageData.validSettings({}));
        verify(ImageData.validSettings({path: "/tmp/photo.png"}));
        verify(!ImageData.validSettings({path: "https://example.com/a.png"}));
        verify(!ImageData.validSettings({path: "http://example.com/a.png"}));
        verify(!ImageData.validSettings(null));
        compare(ImageData.source({path: "https://example.com/a.png"}), "");
        compare(ImageData.source({path: "photo.png"}), "");
        compare(ImageData.source({path: "/tmp/photo.png"}), "file:///tmp/photo.png");
        compare(ImageData.source({path: "file:///tmp/photo.png"}), "file:///tmp/photo.png");
    }
    function test_placeholder_for_missing_and_empty() {
        var empty = createTemporaryObject(cardComponent, test, {settings: {}});
        waitForRendering(empty);
        compare(findChild(empty, "imageWidgetPlaceholder").text, "No image");
        compare(empty.imageSource, "");
        var missing = createTemporaryObject(cardComponent, test, {settings: {path: "/tmp/macshell-missing-image-widget.png"}});
        waitForRendering(missing);
        tryCompare(findChild(missing, "imageWidgetPlaceholder"), "text", "Image not found");
        compare(missing.imageSource, "file:///tmp/macshell-missing-image-widget.png");
    }
}
