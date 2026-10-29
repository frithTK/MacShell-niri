// One desktop widget's content (Weather / Calendar / Clock / Player / Activity / Batteries). Used by MacWidgets.qml for the desktop layer and by
// MacBar.qml to mirror the widgets into the Liquid Glass backdrop, so a menu refracts them together with the live windows.
import QtQuick
import Quickshell.Services.Mpris
import "WidgetCatalog.js" as Catalog
import "WidgetAppearance.js" as Appearance

Item {
    id: v
    required property var host           // the MacWidgets instance (data, glass state, wallpaper lookup)
    property string wtype: "weather"
    property string wstyle: "liquid"
    property string wsize: "small"
    property string wmode: "auto"
    property string wappearance: "{}"
    property string wactivity: "{}"
    property string wbatteries: "{}"
    readonly property var localAppearance: JSON.parse(wappearance)
    readonly property var look: Appearance.resolve(wtype, wstyle, localAppearance, wmode, host.fontFamily, host.darkGlass, host.playerScale)
    readonly property var visual: visualLoader.item
    property bool animationsEnabled: true
    property bool renderActive: true
    property bool mirror: false
    property string instanceId: ""
    opacity: renderActive ? 1 : 0
    WidgetConsumer {
        registry: v.host.subscriptions; instanceId: v.instanceId; widgetType: v.wtype; outputName: v.sname
        active: v.renderActive && v.visible
        secondsMode: v.look.secondsMode
        lyricsOpen: v.wtype === "player" && v.wsize !== "small" && v.host.widgetLyricsOpen(v.instanceId)
    }
    property var displayDate: new Date()
    readonly property var liveDate: renderActive ? (wtype === "clock" ? host.clockSource.timeFor(look.secondsMode)
        : wtype === "calendar" ? host.clockSource.dayNow : null) : null
    onLiveDateChanged: if (liveDate !== null) displayDate = liveDate
    // Conditional dependencies freeze the last snapshot without discarding the
    // loaded artwork or the visual's local animation state while it is culled.
    property var weatherData: ({city: "—", located: false, ready: false, temp: 0, hi: 0, lo: 0, cond: "Loading…", kind: "cloud", day: true, hourly: [], daily: []})
    readonly property var liveWeatherData: renderActive && wtype === "weather" ? ({
        city: host.wxCity, located: host.wxLocated, ready: host.wxReady, temp: host.wxTemp, hi: host.wxHi, lo: host.wxLo,
        cond: host.wxReady ? host.wxInfo.t : host.wxError || "Loading…", kind: host.wxReady ? host.wxInfo.k : "cloud",
        day: host.wxDay, hourly: host.wxHourly, daily: host.wxDaily}) : null
    onLiveWeatherDataChanged: if (liveWeatherData !== null) weatherData = liveWeatherData
    property var playerData: ({hasPlayer: false, title: "", artist: "", album: "", artUrl: "", playing: false,
        shuffle: false, canShuffle: false, loop: 0, canLoop: false, position: 0, length: 0, canSeek: false,
        lyrics: [], lyricsState: "idle", lyricsSynced: false})
    readonly property var livePlayerData: {
        if (!renderActive || wtype !== "player") return null;
        var player = host.player;
        return {hasPlayer: !!player, title: player ? player.trackTitle : "", artist: player ? player.trackArtist : "",
            album: player ? player.trackAlbum : "", artUrl: player ? player.trackArtUrl : "", playing: !!player && player.isPlaying,
            shuffle: !!player && player.shuffleSupported && player.shuffle, canShuffle: !!player && player.shuffleSupported,
            loop: player && player.loopSupported ? (player.loopState === MprisLoopState.Track ? 1 : player.loopState === MprisLoopState.Playlist ? 2 : 0) : 0,
            canLoop: !!player && player.loopSupported, position: player && player.positionSupported ? player.position : 0,
            length: player && player.lengthSupported ? player.length : 0, canSeek: !!player && player.canSeek && player.positionSupported && player.lengthSupported,
            lyrics: host.lyricsLines, lyricsState: host.lyricsState, lyricsSynced: host.lyricsSynced};
    }
    onLivePlayerDataChanged: if (livePlayerData !== null) playerData = livePlayerData
    property var activityData: ({sample: {}, history: [], stale: true, appearance: {}})
    readonly property var liveActivityData: renderActive && wtype === "activity" && host.stats ? ({
        sample: host.stats.sample, history: host.stats.history, stale: host.stats.stale, appearance: host.activityAppearance}) : null
    onLiveActivityDataChanged: if (liveActivityData !== null) activityData = liveActivityData
    property var batteryData: []
    readonly property var liveBatteryData: renderActive && wtype === "batteries" ? host.batteryDevices.entries : null
    onLiveBatteryDataChanged: if (liveBatteryData !== null) batteryData = liveBatteryData
    property real sx: 0                  // position on the screen (the glass uses it to find the wallpaper behind the widget)
    property real sy: 0
    property string sname: ""            // screen name
    property real sw: 1920
    property real sh: 1080
    readonly property var definition: Catalog.find(wtype)
    readonly property bool interactive: renderActive && !mirror && !!definition && definition.interactive && (wtype !== "player" || host.player !== null)
        Component {
            id: weatherVisual
            WeatherWidget {
                style: wstyle
                size: wsize
                fam: v.look.family
                textScale: v.look.textScale
                screenX: v.sx; screenY: v.sy
                city: v.weatherData.city; located: v.weatherData.located; hasData: v.weatherData.ready
                temp: v.weatherData.temp; hi: v.weatherData.hi; lo: v.weatherData.lo
                cond: v.weatherData.cond; kind: v.weatherData.kind; isDay: v.weatherData.day
                hourly: v.weatherData.hourly; daily: v.weatherData.daily
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut
                wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw
                screenH: v.sh
                glassOpacity: host.glassOpacity
                glassBlur: host.glassBlur
                glassLiquid: host.glassLiquid
                glassRim: host.glassRim
                glassGrain: host.glassGrain
                darkGlass: v.look.dark
                editing: host.editing
                onGlassFailed: host.glassState = "failed"
            }
        }
        Component {
            id: calendarVisual
            CalendarWidget {
                style: wstyle
                size: wsize
                mode: v.look.theme
                managedClock: true; active: v.renderActive; now: v.displayDate
                fam: v.look.family
                textScale: v.look.textScale
                screenX: v.sx; screenY: v.sy
                weekStart: 0
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut
                wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw
                screenH: v.sh
                glassOpacity: host.glassOpacity
                glassBlur: host.glassBlur
                glassLiquid: host.glassLiquid
                glassRim: host.glassRim
                glassGrain: host.glassGrain
                darkGlass: v.look.dark
                editing: host.editing
                onGlassFailed: host.glassState = "failed"
            }
        }
        Component {
            id: clockVisual
            ClockWidget {
                style: wstyle
                size: wsize
                fam: v.look.family
                textScale: v.look.textScale
                screenX: v.sx; screenY: v.sy
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut
                wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw
                screenH: v.sh
                glassOpacity: host.glassOpacity
                glassBlur: host.glassBlur
                glassLiquid: host.glassLiquid
                glassRim: host.glassRim
                glassGrain: host.glassGrain
                darkGlass: v.look.dark
                preview: false
                managedClock: true; active: v.renderActive; now: v.displayDate; secondsMode: v.look.secondsMode
                editing: host.editing
                onGlassFailed: host.glassState = "failed"
            }
        }
        Component {
            id: playerVisual
            PlayerWidget {
                animationsEnabled: v.animationsEnabled && v.renderActive
                style: wstyle
                size: wsize
                contentScale: v.look.contentScale
                tintOverride: v.look.tint
                fam: v.look.family
                textScale: v.look.textScale
                screenX: v.sx; screenY: v.sy
                hasPlayer: v.playerData.hasPlayer; title: v.playerData.title; artist: v.playerData.artist; album: v.playerData.album
                artUrl: v.playerData.artUrl; playing: v.playerData.playing
                shuffle: v.playerData.shuffle; canShuffle: v.playerData.canShuffle; loop: v.playerData.loop; canLoop: v.playerData.canLoop
                position: v.playerData.position; length: v.playerData.length; canSeek: v.playerData.canSeek
                lyrics: v.playerData.lyrics; lyricsState: v.playerData.lyricsState; lyricsSynced: v.playerData.lyricsSynced
                managedLyrics: true; lyricsOn: v.host.widgetLyricsOpen(v.instanceId)
                onLyricsToggled: on => host.setWidgetLyrics(v.instanceId, on)
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut
                wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw
                screenH: v.sh
                glassOpacity: host.glassOpacity
                glassBlur: host.glassBlur
                glassLiquid: host.glassLiquid
                glassRim: host.glassRim
                glassGrain: host.glassGrain
                darkGlass: v.look.dark
                editing: host.editing
                onSeek: seconds => { if (host.player && host.player.canSeek) host.player.position = seconds; }
                onTogglePlaying: { if (host.player && host.player.canTogglePlaying) host.player.togglePlaying(); }
                onNextTrack: { if (host.player && host.player.canGoNext) host.player.next(); }
                onPreviousTrack: { if (host.player && host.player.canGoPrevious) host.player.previous(); }
                onToggleShuffle: { if (host.player && host.player.shuffleSupported) host.player.shuffle = !host.player.shuffle; }
                onCycleLoop: {
                    if (!host.player || !host.player.loopSupported) return;
                    // off -> repeat all -> repeat song -> off
                    var ls = host.player.loopState;
                    host.player.loopState = ls === MprisLoopState.None ? MprisLoopState.Playlist
                                          : (ls === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None);
                }
                onGlassFailed: host.glassState = "failed"
            }
        }
        Component {
            id: activityVisual
            ActivityWidget {
                style: v.wstyle; size: v.wsize; fam: v.look.family; textScale: v.look.textScale
                settings: JSON.parse(v.wactivity)
                sample: v.activityData.sample; history: v.activityData.history; stale: v.activityData.stale
                appearance: v.activityData.appearance
                screenX: v.sx; screenY: v.sy
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut; wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw; screenH: v.sh
                glassOpacity: host.glassOpacity; glassBlur: host.glassBlur; glassLiquid: host.glassLiquid
                glassRim: host.glassRim; glassGrain: host.glassGrain; darkGlass: v.look.dark
                editing: host.editing; interactive: v.interactive && !host.editing
                onOpenRequested: host.openActivity(v.sname)
                onGlassFailed: host.glassState = "failed"
            }
        }
        Component {
            id: batteriesVisual
            BatteriesWidget {
                style: v.wstyle; size: v.wsize; fam: v.look.family; textScale: v.look.textScale
                settings: JSON.parse(v.wbatteries); entries: v.batteryData
                screenX: v.sx; screenY: v.sy
                glassReady: host.glassState === "ready" && v.renderActive
                shaderUrl: "file://" + host.glassShaderOut; wallUrl: host.fileUrl(host.wallpaperFor(v.sname))
                screenW: v.sw; screenH: v.sh
                glassOpacity: host.glassOpacity; glassBlur: host.glassBlur; glassLiquid: host.glassLiquid
                glassRim: host.glassRim; glassGrain: host.glassGrain; darkGlass: v.look.dark
                editing: host.editing
                onGlassFailed: host.glassState = "failed"
            }
        }
        Loader {
            id: visualLoader
            anchors.fill: parent
            sourceComponent: v.definition ? ({WeatherWidget: weatherVisual, CalendarWidget: calendarVisual, ClockWidget: clockVisual, PlayerWidget: playerVisual, ActivityWidget: activityVisual, BatteriesWidget: batteriesVisual})[v.definition.component] || null : null
        }
}
