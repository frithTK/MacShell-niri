import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/WidgetAppearance.js" as Appearance
import "../../MacShell/WidgetCatalog.js" as Catalog

TestCase {
    id: test
    name: "WidgetAppearance"; when: windowShown
    width: 600; height: 600; visible: true
    Component { id: previewComponent; Port.WidgetPreview {} }
    function test_partial_overrides_follow_only_their_inherited_fields() {
        var local = {theme: "light", fontFamily: "monospace", textScale: 1.2};
        var first = Appearance.resolve("clock", "liquid", local, "dark", "Inter", true, .8);
        var changed = Appearance.resolve("clock", "liquid", local, "dark", "Noto Sans", false, .8);
        compare(first.dark, false); compare(changed.family, "monospace"); compare(changed.textScale, 1.2);
        compare(Appearance.resolve("clock", "liquid", {}, "dark", "Noto Sans", true, .8).dark, true);
        compare(Appearance.resolve("clock", "liquid", {}, "dark", "Noto Sans", false, .8).dark, false);
        compare(Appearance.resolve("calendar", "normal", {}, "dark", "Inter", false, .8).dark, true);
        compare(Appearance.resolve("calendar", "normal", {theme: "auto"}, "dark", "Inter", false, .8).dark, false);
        compare(Appearance.resolve("calendar", "normal", {}, "auto", "Noto Sans", false, .8).family, "Noto Sans");
        compare(Appearance.supports("weather", "normal", "theme"), false);
        compare(Appearance.supports("clock", "light", "theme"), false);
        compare(Appearance.supports("clock", "liquid", "density"), false);
        compare(Appearance.supports("player", "liquid", "tint"), true);
    }
    function test_large_text_and_fonts_fit_every_supported_card_data() {
        var rows = [];
        for (var type of Catalog.types) for (var size of type.sizes) for (var style of type.styles)
            for (var dark of [true, false]) for (var family of ["Noto Sans", "monospace"])
                rows.push({tag: [type.type, size, style, dark, family].join("/"), type: type.type, size: size, style: style, dark: dark, family: family});
        return rows;
    }
    function test_large_text_and_fonts_fit_every_supported_card(data) {
        var dims = Catalog.dimensions(data.size);
        var preview = createTemporaryObject(previewComponent, test, {widgetType: data.type, widgetSize: data.size,
            widgetStyle: data.style, dark: data.dark, width: dims[0], height: dims[1],
            appearance: {theme: "auto", fontFamily: data.family, textScale: 1.2, density: "comfortable", tint: "#377cc8"}});
        waitForRendering(preview); verify(preview.visual !== null);
        compare(preview.visual.fam, data.family); compare(preview.visual.textScale, 1.2);
        if (data.style === "liquid" || data.type === "calendar") compare(preview.visual.dark, data.dark);
        if (data.type === "player") { compare(preview.visual.contentScale, .9); compare(String(preview.visual.tintOverride), "#377cc8"); }
        function bounds(item) {
            if (!item.visible || item.opacity === 0) return;
            if (item.text !== undefined && item.font !== undefined && item.text !== "") {
                // Scrolling subtitles intentionally extend inside their clipped viewport.
                var ancestor = item.parent, clipped = false;
                while (ancestor && ancestor !== preview.visual) { if (ancestor.clip) clipped = true; ancestor = ancestor.parent; }
                if (!clipped) {
                    var rect = item.mapToItem(preview.visual, 0, 0, item.width, item.height);
                    verify(rect.x >= -1 && rect.y >= -1 && rect.x + rect.width <= dims[0] + 1 && rect.y + rect.height <= dims[1] + 1,
                           item.text + " lies outside " + data.tag + ": " + JSON.stringify(rect));
                }
            }
            for (var child of item.children || []) bounds(child);
        }
        bounds(preview.visual);
    }
}
