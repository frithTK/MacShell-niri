.pragma library

function preview(note) {
    if (!note)
        return "";
    if (note.format === "html")
        return String(note.excerpt || "");
    if (note.excerpt !== undefined && note.excerpt !== null)
        return String(note.excerpt);
    return String(note.body || "");
}

function titleLine(note) {
    return preview(note).split("\n")[0].trim();
}

function snippet(note) {
    return preview(note).replace(/\n/g, " ").trim();
}

function matches(note, query) {
    if (!query)
        return true;
    return preview(note).toLocaleLowerCase().indexOf(String(query).toLocaleLowerCase()) >= 0;
}
