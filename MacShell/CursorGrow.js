.pragma library

var WINDOW_MS = 450
var MIN_SPAN_MS = 140
var MIN_SEGMENTS = 8
var MIN_PATH = 220
var MIN_TURN = 5.0
var MIN_RADIUS = 24
var MIN_SPEED = 650

function sample(previous, now, x, y) {
    var next = []
    var list = previous || []
    for (var i = 0; i < list.length; i++) {
        if (now - list[i].t <= WINDOW_MS) next.push(list[i])
    }
    var last = next.length ? next[next.length - 1] : null
    if (!last || Math.hypot(x - last.x, y - last.y) >= 1.5)
        next.push({ t: now, x: x, y: y })
    if (next.length > 48) next = next.slice(next.length - 48)
    return { samples: next, spin: spinning(next) }
}

function spinning(samples) {
    if (!samples || samples.length < MIN_SEGMENTS + 2) return false
    var span = samples[samples.length - 1].t - samples[0].t
    if (span < MIN_SPAN_MS) return false
    var path = 0
    var turn = 0
    var segments = 0
    var previousX = 0
    var previousY = 0
    var hasVector = false
    for (var i = 1; i < samples.length; i++) {
        var dx = samples[i].x - samples[i - 1].x
        var dy = samples[i].y - samples[i - 1].y
        var distance = Math.hypot(dx, dy)
        if (distance < 2) continue
        path += distance
        if (hasVector) {
            turn += Math.atan2(previousX * dy - previousY * dx, previousX * dx + previousY * dy)
            segments++
        }
        previousX = dx
        previousY = dy
        hasVector = true
    }
    if (segments < MIN_SEGMENTS || path < MIN_PATH || Math.abs(turn) < MIN_TURN) return false
    if (path / span * 1000 < MIN_SPEED) return false
    var cx = 0
    var cy = 0
    for (var p = 0; p < samples.length; p++) {
        cx += samples[p].x
        cy += samples[p].y
    }
    cx /= samples.length
    cy /= samples.length
    var radius = 0
    for (var r = 0; r < samples.length; r++)
        radius += Math.hypot(samples[r].x - cx, samples[r].y - cy)
    radius /= samples.length
    if (radius < MIN_RADIUS) return false
    return path <= radius * 14
}
