.pragma library

function searchApps(list, usage, q) {
    q = (q || "").trim().toLowerCase();
    if (q === "") return [];
    var hits = [];
    for (var i = 0; i < (list || []).length; i++) {
        var e = list[i], n = (e.name || "").toLowerCase(), sc = 0;
        if (n === q) sc = 100;
        else if (n.indexOf(q) === 0) sc = 80;
        else if (n.indexOf(" " + q) >= 0) sc = 60;
        else if (n.indexOf(q) >= 0) sc = 40;
        else if ((e.genericName || "").toLowerCase().indexOf(q) >= 0) sc = 25;
        else if ((e.comment || "").toLowerCase().indexOf(q) >= 0) sc = 10;
        else {
            var kw = e.keywords || [];
            for (var k = 0; k < kw.length; k++) if (String(kw[k]).toLowerCase().indexOf(q) >= 0) { sc = 15; break; }
        }
        if (sc > 0) hits.push({ e: e, s: sc + Math.min((usage && usage[e.id]) || 0, 20) });
    }
    hits.sort(function (a, b) { return b.s - a.s; });
    return hits.map(function (h) { return h.e; });
}

function calcValue(expr) {
    var t = String(expr || "").replace(/[xX×]/g, "*").replace(/÷/g, "/");
    if (!/^[0-9+\-*/%.()\s]+$/.test(t) || !/[0-9]/.test(t)) return null;
    var i = 0;
    function ws() { while (i < t.length && /\s/.test(t[i])) i++; }
    function atom() {
        ws();
        if (t[i] === "+") { i++; return atom(); }
        if (t[i] === "-") { i++; return -atom(); }
        if (t[i] === "(") { i++; var v = sum(); ws(); if (t[i] !== ")") throw 0; i++; return v; }
        var m = t.substring(i).match(/^(?:\d+(?:\.\d*)?|\.\d+)/);
        if (!m) throw 0;
        i += m[0].length;
        return Number(m[0]);
    }
    function term() {
        var v = atom();
        for (;;) {
            ws();
            var op = t[i];
            if (op !== "*" && op !== "/" && op !== "%") break;
            i++;
            var r = atom();
            if ((op === "/" || op === "%") && r === 0) throw 0;
            v = op === "*" ? v * r : (op === "/" ? v / r : v % r);
        }
        return v;
    }
    function sum() {
        var v = term();
        for (;;) {
            ws();
            var op = t[i];
            if (op !== "+" && op !== "-") break;
            i++;
            var r = term();
            v = op === "+" ? v + r : v - r;
        }
        return v;
    }
    try {
        var v = sum();
        ws();
        return i === t.length && isFinite(v) ? v : null;
    } catch (e) { return null; }
}

function conversion(q) {
    var m = (q || "").trim().match(/^(-?\d+(?:\.\d+)?)\s*([a-z°]+)\s+(?:to|in)\s+([a-z°]+)$/i);
    if (!m) return null;
    var val = Number(m[1]), a = m[2].toLowerCase(), b = m[3].toLowerCase();
    var units = {mm: ["len", .001], cm: ["len", .01], m: ["len", 1], km: ["len", 1000], in: ["len", .0254], ft: ["len", .3048],
        mi: ["len", 1609.344], g: ["mass", .001], kg: ["mass", 1], lb: ["mass", .45359237], oz: ["mass", .0283495],
        ml: ["vol", .001], l: ["vol", 1], gal: ["vol", 3.78541], ms: ["time", .001], s: ["time", 1], min: ["time", 60],
        h: ["time", 3600], c: ["temp", 1], "°c": ["temp", 1], f: ["temp", 1], "°f": ["temp", 1]};
    if (!units[a] || !units[b] || units[a][0] !== units[b][0]) return null;
    var result;
    if (units[a][0] === "temp") result = (a === "f" || a === "°f") ? (val - 32) * 5 / 9 : val, result = (b === "f" || b === "°f") ? result * 9 / 5 + 32 : result;
    else result = val * units[a][1] / units[b][1];
    return { title: Number(result.toPrecision(7)) + " " + b, result: result, from: a, to: b };
}

function skipFileSearch(q) {
    if (conversion(q)) return true;
    var expr = String(q || "").replace(/^=\s*/, "");
    return calcValue(expr) !== null && (String(q).charAt(0) === "=" || /[+*/%xX×÷()]/.test(q));
}

function fileRows(hits, limit) {
    var out = [], cap = limit > 0 ? limit : 8;
    for (var i = 0; i < (hits || []).length && out.length < cap; i++) {
        var path = hits[i];
        out.push({ title: path.substring(path.lastIndexOf("/") + 1) || path, sub: path, glyph: "folder", kind: "file", path: path });
    }
    return out;
}

function appendGroup(out, items, limit, groupLimit) {
    var n = 0;
    var maxGroup = groupLimit > 0 ? groupLimit : limit;
    for (var i = 0; i < (items || []).length && out.length < limit && n < maxGroup; i++) {
        out.push(items[i]);
        n++;
    }
    return out;
}

function matchActions(all, q) {
    var s = (q || "").trim().toLowerCase(), out = [];
    for (var i = 0; i < (all || []).length; i++) {
        if (s !== "" && (all[i].title + " " + (all[i].keywords || "")).toLowerCase().indexOf(s) < 0) continue;
        out.push(all[i]);
    }
    return out;
}

function assembleHome(query, groups, labels) {
    var s = String(query || "").trim();
    var out = [];
    if (groups && groups.exclusive) {
        out = (groups.files || []).slice();
        if (out.length === 0) {
            out.push({
                title: groups.filePending ? (labels && labels.searching) || "" : (labels && labels.noFiles) || "",
                sub: (labels && labels.homeFolder) || "", glyph: "folder"
            });
        }
        return out;
    }
    if (s.length > 0) out = (groups && groups.apps || []).slice();
    if (groups && groups.conversion) out.unshift(groups.conversion);
    else if (groups && groups.calc) out.unshift(groups.calc);
    appendGroup(out, groups && groups.settings, 8, 4);
    appendGroup(out, groups && groups.actions, 8, 4);
    appendGroup(out, groups && groups.windows, 8, 4);
    appendGroup(out, groups && groups.files, 8, 3);
    if (s.length > 0 && out.length < 8 && labels && labels.webPrefix)
        out.push({ title: labels.webPrefix + s + (labels.webQuote || "”"), sub: labels.webHint || "", glyph: "search", kind: "web" });
    return out.slice(0, 8);
}
