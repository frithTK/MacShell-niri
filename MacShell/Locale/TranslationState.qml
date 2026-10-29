import QtQuick
import "TranslationCatalog.js" as Catalog
import "TranslationEngine.js" as Engine
import "UnicodeData.js" as Unicode

// One instance per process, passed to screens. No workers, timers or global Qt mutation.
QtObject {
    id: root
    property string language: "system"
    property string region: "system"
    property var systemLanguages: Qt.locale().uiLanguages
    property string systemRegion: Qt.locale().name
    readonly property string activeLanguage: Engine.language(language, systemLanguages)
    readonly property var formatLocale: Qt.locale(region === "system" ? systemRegion : region)
    readonly property bool supportedSelection: language === "system" || Engine.normalizedLanguage(language) !== ""

    function text(key, parameters) { return Engine.text(Catalog.messages, activeLanguage, key, parameters); }
    function english(key) { return Engine.text(Catalog.messages, "en", key); }
    // Bridge only for owned metadata and legacy helper messages, never user content.
    function legacy(value) { return Engine.legacy(Catalog.messages, activeLanguage, value); }
    function currencyName(code, fallback) {
        var entry = Unicode.data.currencies[code];
        return entry && entry[activeLanguage] ? entry[activeLanguage] : fallback;
    }
    function cityName(zone, fallback) {
        if (activeLanguage !== "ru") return fallback;
        var key = "city.name_" + String(fallback).toLowerCase().replace(/[^a-z0-9]/g, "_");
        if (typeof Engine.message(Catalog.messages, activeLanguage, key) === "string") return text(key);
        var entry = Unicode.data.cities[zone];
        // An exemplar city names a timezone, not every city within that zone.
        return entry && entry.en === fallback && entry.ru ? entry.ru : fallback;
    }
    function emojiName(emoji, fallback) {
        var entry = Unicode.data.emoji[String(emoji).replace(/\uFE0F/g, "")];
        return activeLanguage === "ru" && entry && entry.name ? entry.name : fallback;
    }
    function emojiKeywords(emoji) {
        var entry = Unicode.data.emoji[String(emoji).replace(/\uFE0F/g, "")];
        return activeLanguage === "ru" && entry && entry.keywords ? entry.keywords : "";
    }
    function weatherCondition(value) {
        var key = String(value).toLowerCase().replace(/[^a-z0-9]+/g, "_");
        var message = Engine.message(Catalog.messages, activeLanguage, "weather." + key);
        return typeof message === "string" ? text("weather." + key) : legacy(value);
    }
    function plural(key, count, parameters) {
        return Engine.plural(Catalog.messages, activeLanguage, key, count, formatNumber(count), parameters);
    }
    function formatNumber(value, precision) {
        if (typeof value !== "number" || !isFinite(value)) return "—";
        if (precision === undefined) return value.toLocaleString(formatLocale, 'g', 15);
        if (typeof precision !== "number" || precision % 1 !== 0 || precision < 0 || precision > 15) return "—";
        return value.toLocaleString(formatLocale, 'f', precision);
    }
    function formatDate(value, format) {
        if (!(value instanceof Date) || !isFinite(value.getTime())) return "—";
        return value.toLocaleDateString(formatLocale, format === undefined ? Locale.ShortFormat : format);
    }
    function formatTime(value, format) {
        if (!(value instanceof Date) || !isFinite(value.getTime())) return "—";
        return value.toLocaleTimeString(formatLocale, format === undefined ? Locale.ShortFormat : format);
    }
    function formatDateTime(value, format) {
        if (!(value instanceof Date) || !isFinite(value.getTime())) return "—";
        return value.toLocaleString(formatLocale, format === undefined ? Locale.ShortFormat : format);
    }
}
