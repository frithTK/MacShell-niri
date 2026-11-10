.pragma library

function parse(text) {
    var t = String(text || "").replace(/^\s+|\s+$/g, "");
    if (/^(file|find)\s+/i.test(t)) {
        return {
            exclusive: true,
            query: t.replace(/^(file|find)\s+/i, "").replace(/^\s+|\s+$/g, "")
        };
    }
    return { exclusive: false, query: t };
}

function ready(query) {
    return String(query || "").length >= 2;
}
