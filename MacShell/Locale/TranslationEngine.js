.pragma library

function normalizedLanguage(value) {
    if (typeof value !== "string") return "";
    var code = value.trim().toLowerCase().split(/[_.@-]/)[0];
    return code === "ru" || code === "en" ? code : "";
}

function language(selection, systemLanguages) {
    if (selection !== "system") return normalizedLanguage(selection) || "en";
    for (var candidate of systemLanguages || []) {
        var supported = normalizedLanguage(candidate);
        if (supported) return supported;
    }
    return "en";
}

function has(object, key) {
    return object !== null && typeof object === "object" && Object.prototype.hasOwnProperty.call(object, key);
}

function message(catalog, language, key) {
    if (has(catalog, language) && has(catalog[language], key)) return catalog[language][key];
    if (has(catalog, "en") && has(catalog.en, key)) return catalog.en[key];
    return null;
}

// Named substitution is one pass. User strings cannot introduce new placeholders.
// The result is plain text; callers must set Text.PlainText for dynamic parameters.
function substitute(template, parameters) {
    return template.replace(/\{([a-zA-Z][a-zA-Z0-9_]*)\}/g, function(token, name) {
        return has(parameters, name) ? String(parameters[name]) : token;
    });
}

function text(catalog, language, key, parameters) {
    var entry = message(catalog, language, key);
    return typeof entry === "string" ? substitute(entry, parameters) : "⟦" + key + "⟧";
}

var indexedCatalog = null;
var englishIds = null;
function legacy(catalog, language, value) {
    if (typeof value !== "string") return value;
    if (indexedCatalog !== catalog) {
        indexedCatalog = catalog; englishIds = Object.create(null);
        for (var key of Object.keys(catalog.en)) {
            if (typeof catalog.en[key] === "string" && !has(englishIds, catalog.en[key])) englishIds[catalog.en[key]] = key;
        }
        for (var key of Object.keys(catalog.ru)) {
            if (typeof catalog.ru[key] === "string" && !has(englishIds, catalog.ru[key])) englishIds[catalog.ru[key]] = key;
        }
    }
    return has(englishIds, value) ? text(catalog, language, englishIds[value]) : value;
}

function pluralCategory(language, count) {
    var number = Math.abs(count);
    if (language === "ru") {
        if (number % 1 !== 0) return "other";
        if (number % 10 === 1 && number % 100 !== 11) return "one";
        if (number % 10 >= 2 && number % 10 <= 4 && !(number % 100 >= 12 && number % 100 <= 14)) return "few";
        return "many";
    }
    return number === 1 ? "one" : "other";
}

function plural(catalog, language, key, count, formattedCount, parameters) {
    if (typeof count !== "number" || !isFinite(count)) return "⟦" + key + "⟧";
    var entry = message(catalog, language, key);
    // A missing translated message must use the fallback language's plural rules.
    var sourceLanguage = has(catalog, language) && has(catalog[language], key) ? language : "en";
    if (!entry || typeof entry !== "object") return "⟦" + key + "⟧";
    var category = pluralCategory(sourceLanguage, count);
    var template = has(entry, category) ? entry[category] : entry.other;
    if (typeof template !== "string") return "⟦" + key + "⟧";
    var args = Object.create(null);
    for (var name of Object.keys(parameters || {})) args[name] = parameters[name];
    args.count = formattedCount;
    return substitute(template, args);
}
