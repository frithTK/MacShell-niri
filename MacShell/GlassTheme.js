.pragma library

function lightTint(frosting) { return .64 + Math.max(0, Math.min(1, frosting)) * .28; }
