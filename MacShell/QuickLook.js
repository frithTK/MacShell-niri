.pragma library
.import "SettingsSearch.js" as SettingsSearch

function localPath(value) {
    var text = String(value || "").trim();
    if (text.indexOf("file://") === 0) {
        var rest = text.slice(7);
        if (rest.indexOf("/") !== 0)
            return "";
        try {
            text = decodeURIComponent(rest);
        } catch (error) {
            return "";
        }
    }
    return SettingsSearch.isLocalPath(text) ? text : "";
}

function fileName(path) {
    var text = String(path || "");
    if (text.length > 1 && text.charAt(text.length - 1) === "/")
        text = text.substring(0, text.length - 1);
    var slash = text.lastIndexOf("/");
    return slash < 0 ? text : text.substring(slash + 1);
}

function fileUrl(path) {
    var local = localPath(path);
    if (!local)
        return "";
    return "file://" + encodeURI(local).replace(/#/g, "%23").replace(/\?/g, "%3F");
}

function uriList(path) {
    var url = fileUrl(path);
    return url ? url + "\r\n" : "";
}

function formatSize(bytes) {
    var size = Number(bytes);
    if (!isFinite(size) || size < 0)
        size = 0;
    if (size < 1024)
        return Math.round(size) + " B";
    if (size < 1024 * 1024) {
        var kb = size / 1024;
        return (kb < 10 ? kb.toFixed(1) : Math.round(kb)) + " KB";
    }
    var mb = size / (1024 * 1024);
    return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MB";
}
