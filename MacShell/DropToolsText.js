.pragma library

var messages = {
    en: {
        title: "Convert",
        description: "Convert images and PDF next to the original",
        comment: "MacShell Convert"
    },
    ru: {
        title: "Конвертер",
        description: "Преобразовать изображения и PDF рядом с оригиналом",
        comment: "Конвертер MacShell"
    }
};

function text(language, key) {
    return (messages[language] || messages.en)[key] || messages.en[key] || key;
}
