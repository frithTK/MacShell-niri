.pragma library

function canonical(state) {
    return state && state.version === 2 && state.timing && state.timing.version === 1 ? state.timing : null;
}

function finiteNonnegative(value) {
    return typeof value === "number" && isFinite(value) && value >= 0;
}

function ringTime(event, use24h) {
    if (!event) return "";
    var hour, minute;
    if (finiteNonnegative(event.occurredWallMs)) {
        var when = new Date(event.occurredWallMs);
        if (!isFinite(when.getTime())) return event.time || "";
        hour = when.getHours(); minute = when.getMinutes();
    } else if (finiteNonnegative(event.hour) && event.hour <= 23 &&
               finiteNonnegative(event.minute) && event.minute <= 59) {
        hour = event.hour; minute = event.minute;
    } else return event.time || "";
    var minutes = (minute < 10 ? "0" : "") + minute;
    if (use24h) return (hour < 10 ? "0" : "") + hour + ":" + minutes;
    var twelve = hour % 12 || 12;
    return twelve + ":" + minutes + (hour < 12 ? " AM" : " PM");
}

function status(timing, item, clockReady, bootId) {
    if (!timing || !item) return "legacy";
    if (item.state === "recovery") return "recovery";
    if (item.state !== "running" && item.state !== "paused") return "normal";
    if (item.state === "running" && !(finiteNonnegative(item.deadlineBootMs) ||
            (finiteNonnegative(item.startedBootMs) && finiteNonnegative(item.accumulatedMs)))) return "unavailable";
    if (!clockReady) return item.state === "running" ? "unavailable" : "normal";
    return timing.bootId === bootId ? "normal" : "recovery";
}

function timerRemaining(state, nowMs, clockReady, bootId, bootMs) {
    var timing = canonical(state), item = timing && timing.timer;
    if (!item) {
        var timer = state && state.timer;
        return !timer ? 0 : timer.state === "running" ? Math.max(0, timer.endAt - nowMs) : timer.left;
    }
    var checkpoint = finiteNonnegative(item.remainingCheckpointMs) ? item.remainingCheckpointMs : 0;
    if (item.state !== "running") return checkpoint;
    if (status(timing, item, clockReady, bootId) !== "normal") return checkpoint;
    if (!finiteNonnegative(item.deadlineBootMs) || !finiteNonnegative(bootMs)) return checkpoint;
    return Math.max(0, item.deadlineBootMs - bootMs);
}

function stopwatchElapsed(state, nowMs, clockReady, bootId, bootMs) {
    var timing = canonical(state), item = timing && timing.stopwatch;
    if (!item) {
        var sw = state && state.sw;
        return !sw ? 0 : sw.acc + (sw.running ? nowMs - sw.startAt : 0);
    }
    var checkpoint = finiteNonnegative(item.elapsedCheckpointMs) ? item.elapsedCheckpointMs : 0;
    if (item.state !== "running" || status(timing, item, clockReady, bootId) !== "normal") return checkpoint;
    if (!finiteNonnegative(item.accumulatedMs) || !finiteNonnegative(item.startedBootMs) ||
            !finiteNonnegative(bootMs) || bootMs < item.startedBootMs) return checkpoint;
    return item.accumulatedMs + bootMs - item.startedBootMs;
}
