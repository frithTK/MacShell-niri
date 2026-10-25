.pragma library

// The adapter infers fullscreen only from complete output-sized geometry.
// Unknown positions and ordinary overlapping windows cannot prove coverage.
function covered(output, clients, connected, overview, editing) {
    if (!connected || overview || editing) return false;
    return clients.some(window => window.output === output && window.geometryKnown === true && window.fullscreen > 0
        && window.workspaceActive === true && window.mapped === true && !window.hidden);
}
