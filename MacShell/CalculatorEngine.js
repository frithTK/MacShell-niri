.pragma library

function format(value) {
    if (!isFinite(value)) throw new Error("Result is outside the supported range");
    var rounded = Number(value.toPrecision(14));
    return String(Object.is(value, -0) ? 0 : isFinite(rounded) ? rounded : value);
}
function evaluate(expression, degrees, answer) {
    try {
        var text = String(expression || "").trim().replace(/×/g, "*").replace(/(\d|\))\s*[xX]\s*(?=[\d.(])/g, "$1*")
            .replace(/÷/g, "/").replace(/−/g, "-").replace(/π/g, "pi").replace(/,/g, ".");
        if (!text) return {ok: false, error: "Enter an expression"};
        if (text.length > 512) throw new Error("Expression is too long");
        var tokens = [], offset = 0;
        var functions = ["sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "exp", "abs", "floor", "ceil", "round"];
        while (offset < text.length) {
            var ch = text[offset];
            if (/\s/.test(ch)) { offset++; continue; }
            var number = text.slice(offset).match(/^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/);
            var name = text.slice(offset).match(/^[a-z]+/i);
            if (number) { tokens.push({kind: "number", value: Number(number[0])}); offset += number[0].length; }
            else if (name) {
                var key = name[0].toLowerCase();
                if (functions.indexOf(key) < 0 && ["pi", "e", "ans"].indexOf(key) < 0) throw new Error("Unknown function or constant");
                tokens.push({kind: functions.indexOf(key) >= 0 ? "function" : "number", name: key,
                    value: key === "pi" ? Math.PI : key === "e" ? Math.E : key === "ans" ? (answer || 0) : 0});
                offset += name[0].length;
            } else if ("+-*/^()%!".indexOf(ch) >= 0) { tokens.push({kind: ch}); offset++; }
            else throw new Error("Unsupported character");
            if (tokens.length > 256) throw new Error("Expression is too long");
        }
        var expanded = [];
        tokens.forEach((token, index) => {
            var previous = tokens[index - 1];
            if (previous && ["number", ")", "!", "%"].indexOf(previous.kind) >= 0
                && (token.kind === "(" || token.kind === "function" || token.kind === "number" && (previous.kind !== "number" || !!token.name || !!previous.name)))
                expanded.push({kind: "*"});
            expanded.push(token);
        });
        tokens = expanded;
        var cursor = 0, depth = 0;
        function finite(value) { if (!isFinite(value)) throw new Error("Result is outside the supported range"); return value; }
        function parse(minimum) {
            if (++depth > 64) throw new Error("Expression is too deeply nested");
            var token = tokens[cursor++], left;
            if (!token) throw new Error("Complete the expression");
            if (token.kind === "number") left = {value: finite(token.value), percent: false};
            else if (token.kind === "+" || token.kind === "-") {
                left = parse(25); if (token.kind === "-") left.value = -left.value;
            } else if (token.kind === "(" || token.kind === "function") {
                if (token.kind === "function" && (!tokens[cursor] || tokens[cursor++].kind !== "(")) throw new Error("Use parentheses after a function");
                left = parse(0);
                if (!tokens[cursor] || tokens[cursor++].kind !== ")") throw new Error("Missing closing parenthesis");
                if (token.kind === "function") {
                    var value = left.value, radians = degrees === false ? value : value * Math.PI / 180;
                    var inverse = degrees === false ? 1 : 180 / Math.PI;
                    if (token.name === "sqrt" && value < 0 || ["ln", "log"].indexOf(token.name) >= 0 && value <= 0
                        || ["asin", "acos"].indexOf(token.name) >= 0 && Math.abs(value) > 1) throw new Error("Value is outside this function's domain");
                    if (token.name === "tan" && Math.abs(Math.cos(radians)) < 1e-14) throw new Error("Tangent is undefined at this angle");
                    var result = token.name === "sin" ? Math.sin(radians) : token.name === "cos" ? Math.cos(radians) : token.name === "tan" ? Math.tan(radians)
                        : token.name === "asin" ? Math.asin(value) * inverse : token.name === "acos" ? Math.acos(value) * inverse : token.name === "atan" ? Math.atan(value) * inverse
                        : token.name === "ln" ? Math.log(value) : token.name === "log" ? Math.log(value) / Math.LN10 : token.name === "sqrt" ? Math.sqrt(value)
                        : token.name === "exp" ? Math.exp(value) : token.name === "abs" ? Math.abs(value) : token.name === "floor" ? Math.floor(value)
                        : token.name === "ceil" ? Math.ceil(value) : Math.round(value);
                    if (["sin", "cos", "tan"].indexOf(token.name) >= 0 && Math.abs(result) < 1e-14) result = 0;
                    left = {value: finite(result), percent: false};
                }
            } else throw new Error("Expected a number or function");
            while (cursor < tokens.length) {
                var operator = tokens[cursor].kind, precedence = operator === "%" || operator === "!" ? 50 : operator === "^" ? 30
                    : operator === "*" || operator === "/" ? 20 : operator === "+" || operator === "-" ? 10 : -1;
                if (precedence < minimum) break;
                cursor++;
                if (operator === "%") { left = {value: left.value / 100, percent: true}; continue; }
                if (operator === "!") {
                    if (!Number.isInteger(left.value) || left.value < 0 || left.value > 170) throw new Error("Factorial requires an integer from 0 to 170");
                    var factorial = 1; for (var i = 2; i <= left.value; i++) factorial *= i;
                    left = {value: factorial, percent: false}; continue;
                }
                var right = parse(precedence + (operator === "^" ? 0 : 1)), rhs = right.value;
                if ((operator === "+" || operator === "-") && right.percent) rhs *= left.value;
                if (operator === "/" && rhs === 0) throw new Error("Cannot divide by zero");
                left = {value: finite(operator === "+" ? left.value + rhs : operator === "-" ? left.value - rhs
                    : operator === "*" ? left.value * rhs : operator === "/" ? left.value / rhs : Math.pow(left.value, rhs)), percent: false};
            }
            depth--; return left;
        }
        var result = parse(0).value;
        if (cursor !== tokens.length) throw new Error("Check the operators and parentheses");
        return {ok: true, value: result, text: format(result), error: ""};
    } catch (error) { return {ok: false, error: error.message || "Invalid expression"}; }
}

var groups = [
    {key: "length", label: "Length", units: [["m", "Metres", 1], ["cm", "Centimetres", .01], ["mm", "Millimetres", .001], ["km", "Kilometres", 1000], ["in", "Inches", .0254], ["ft", "Feet", .3048], ["yd", "Yards", .9144], ["mi", "Miles", 1609.344]]},
    {key: "mass", label: "Mass", units: [["kg", "Kilograms", 1], ["g", "Grams", .001], ["mg", "Milligrams", .000001], ["t", "Tonnes", 1000], ["lb", "Pounds", .45359237], ["oz", "Ounces", .028349523125]]},
    {key: "temperature", label: "Temperature", units: [["C", "Celsius", 1, 273.15], ["F", "Fahrenheit", 5 / 9, 273.15 - 32 * 5 / 9], ["K", "Kelvin", 1, 0]]},
    {key: "volume", label: "Volume", units: [["L", "Litres", 1], ["mL", "Millilitres", .001], ["m3", "Cubic metres", 1000], ["gal", "US gallons", 3.785411784], ["qt", "US quarts", .946352946], ["pt", "US pints", .473176473]]},
    {key: "time", label: "Time", units: [["s", "Seconds", 1], ["ms", "Milliseconds", .001], ["min", "Minutes", 60], ["h", "Hours", 3600], ["d", "Days (24 hours)", 86400]]},
    {key: "speed", label: "Speed", units: [["m/s", "Metres per second", 1], ["km/h", "Kilometres per hour", 1 / 3.6], ["mph", "Miles per hour", .44704], ["kn", "Knots", 1852 / 3600]]},
    {key: "area", label: "Area", units: [["m2", "Square metres", 1], ["km2", "Square kilometres", 1000000], ["ha", "Hectares", 10000], ["ft2", "Square feet", .09290304], ["acre", "Acres", 4046.8564224]]},
    {key: "data", label: "Data", units: [["B", "Bytes", 1], ["kB", "Kilobytes", 1000], ["MB", "Megabytes", 1000000], ["GB", "Gigabytes", 1000000000], ["KiB", "Kibibytes", 1024], ["MiB", "Mebibytes", 1048576], ["GiB", "Gibibytes", 1073741824]]}
];
function convert(value, group, from, to) {
    var definition = groups.find(item => item.key === group);
    if (!definition || !isFinite(value)) return {ok: false, error: "Invalid conversion"};
    var a = definition.units.find(item => item[0] === from), b = definition.units.find(item => item[0] === to);
    if (!a || !b) return {ok: false, error: "Choose compatible units"};
    var base = value * a[2] + (a[3] || 0);
    if (group === "temperature" && base < -1e-10) return {ok: false, error: "Temperature is below absolute zero"};
    var result = (base - (b[3] || 0)) / b[2];
    try { return {ok: true, value: result, text: format(result), error: ""}; }
    catch (error) { return {ok: false, error: error.message}; }
}
