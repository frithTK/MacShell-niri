.pragma library

function clone(value) { return JSON.parse(JSON.stringify(value)); }
function defaults(fields) {
    var values = {};
    fields.forEach(field => values[field.key] = clone(field.default));
    return values;
}
function validate(fields, values) {
    var errors = {};
    fields.forEach(field => {
        var value = values[field.key], valid = true;
        if (field.type === "integer")
            valid = typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= field.minimum && value <= field.maximum;
        else if (field.type === "choice")
            valid = field.choices.some(choice => choice.value === value);
        else if (field.type === "order")
            valid = Array.isArray(value) && value.length === field.choices.length
                && field.choices.every(choice => value.indexOf(choice.value) >= 0);
        if (!valid) errors[field.key] = field.label + " has an invalid value.";
        else if (field.lessThan && value >= values[field.lessThan])
            errors[field.key] = field.label + " must be below the critical threshold.";
    });
    return errors;
}
function search(fields, query) {
    var words = query.trim().toLowerCase().split(/\s+/);
    if (!query.trim()) return [];
    return fields.filter(field => {
        var text = (field.key + " " + field.label + " " + field.description + " " + field.keywords).toLowerCase();
        return words.every(word => text.indexOf(word) >= 0);
    });
}
