import QtQuick
import QtTest
import "../../MacShell/StickiesColor.js" as Color

TestCase {
    name: "StickiesColor"

    function test_palette_has_six_named_papers() {
        compare(Color.ids.join(), "yellow,pink,blue,green,orange,purple")
        compare(Color.normalize(""), "yellow")
        compare(Color.normalize("red"), "yellow")
        compare(Color.normalize("#fff1ad"), "yellow")
        compare(Color.normalize("blue"), "blue")
        compare(Color.paper("yellow").fill, "#fff1ad")
        compare(Color.paper("purple").fill.charAt(0), "#")
        verify(Color.paper("pink").fill !== Color.paper("yellow").fill)
    }
}
