.pragma library

var strings = {
    en: {title: "Stickies", description: "Quick notes on your desktop", comment: "MacShell Stickies", close: "Close sticky note", minimize: "Minimize sticky note", maximize: "Maximize sticky note", newNote: "New sticky note", pin: "Open as sticky note", placeholder: "Write a note…", saveCopy: "Save a copy", retry: "Retry", unavailable: "Notes storage unavailable", saved: "Saved", saving: "Saving…", cannotOpen: "This note is no longer available"},
    ru: {title: "Записки", description: "Быстрые записки на рабочем столе", comment: "Записки MacShell", close: "Закрыть записку", minimize: "Свернуть записку", maximize: "Развернуть записку", newNote: "Новая записка", pin: "Открыть как записку", placeholder: "Напишите записку…", saveCopy: "Сохранить копию", retry: "Повторить", unavailable: "Хранилище заметок недоступно", saved: "Сохранено", saving: "Сохранение…", cannotOpen: "Эта заметка больше недоступна"}
};
function text(language, key) { return (strings[language] || strings.en)[key] || strings.en[key] || key; }
