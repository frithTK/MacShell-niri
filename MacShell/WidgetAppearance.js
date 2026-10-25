.pragma library
.import "WidgetCatalog.js" as Catalog

var fonts = [{value: "Inter Variable", label: "Inter"}, {value: "Noto Sans", label: "Noto Sans"},
             {value: "sans-serif", label: "System sans"}, {value: "monospace", label: "Monospace"}];
var tints = [{value: "#746ba5", label: "Violet"}, {value: "#377cc8", label: "Blue"},
             {value: "#3d907b", label: "Green"}, {value: "#b26946", label: "Amber"}, {value: "#ae587e", label: "Rose"}];
var fields = ["theme", "fontFamily", "textScale", "density", "tint", "secondsMode"];
function supports(type, style, key) {
    var definition = Catalog.find(type);
    if (!definition || definition.appearance.indexOf(key) < 0) return false;
    return key !== "theme" || style === "liquid" || type === "calendar";
}
function valid(key, value) {
    if (key === "theme") return ["auto", "light", "dark"].indexOf(value) >= 0;
    if (key === "fontFamily") return typeof value === "string" && value.trim().length > 0 && value.length <= 100 && !/[\u0000-\u001f]/.test(value);
    if (key === "textScale") return typeof value === "number" && isFinite(value) && value >= .9 && value <= 1.2;
    if (key === "density") return ["compact", "comfortable"].indexOf(value) >= 0;
    if (key === "tint") return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value);
    if (key === "secondsMode") return ["smooth", "tick", "hidden"].indexOf(value) >= 0;
    return false;
}
function resolve(type, style, local, mode, family, dark, scale) {
    var theme = local.theme !== undefined ? local.theme : type === "calendar" ? mode : "auto";
    return {theme: theme || "auto", dark: theme === "dark" || (theme !== "light" && dark),
            family: local.fontFamily || family, textScale: local.textScale === undefined ? 1 : local.textScale,
            contentScale: type === "player" && local.density ? (local.density === "compact" ? .7 : .9) : scale,
            tint: type === "player" && local.tint ? local.tint : "transparent",
            secondsMode: type === "clock" ? local.secondsMode || "smooth" : "hidden"};
}
