.pragma library

var ids = ["yellow", "pink", "blue", "green", "orange", "purple"];
var papers = {
    yellow: { fill: "#fff1ad", bar: "#efd984", border: "#c9ad61", title: "#574b22", ink: "#302b1b", muted: "#756737", placeholder: "#958456", button: "#ead899", buttonText: "#42391b", error: "#8e2c20" },
    pink: { fill: "#ffd6e5", bar: "#f5b3c8", border: "#d4899e", title: "#6a3044", ink: "#3a1f28", muted: "#8a5464", placeholder: "#b07c8c", button: "#f0c4d2", buttonText: "#4a2432", error: "#8e2c20" },
    blue: { fill: "#cfe6ff", bar: "#9ec8f2", border: "#6f9cc4", title: "#2a4a6e", ink: "#1c3148", muted: "#4a6a88", placeholder: "#7a98b0", button: "#bdd8f5", buttonText: "#1e364e", error: "#8e2c20" },
    green: { fill: "#d8f0c8", bar: "#a8d494", border: "#7aaa68", title: "#2f5a28", ink: "#1e3a1c", muted: "#4a7044", placeholder: "#7a9a70", button: "#c5e4b4", buttonText: "#244820", error: "#8e2c20" },
    orange: { fill: "#ffd9b3", bar: "#f0b078", border: "#c88848", title: "#6a3c14", ink: "#3e2610", muted: "#8a5a30", placeholder: "#b08458", button: "#f5c898", buttonText: "#4a2c10", error: "#8e2c20" },
    purple: { fill: "#e6d6ff", bar: "#c4a8ee", border: "#9878c4", title: "#4a2e6e", ink: "#2c1c44", muted: "#6a5488", placeholder: "#947cb0", button: "#d4c2f5", buttonText: "#3a2458", error: "#8e2c20" }
};

function normalize(value) {
    return ids.indexOf(value) >= 0 ? value : "yellow";
}

function paper(value) {
    return papers[normalize(value)];
}
