import QtQuick
import "WidgetCatalog.js" as Catalog
import "WidgetAppearance.js" as Appearance
import "ActivityWidgetData.js" as ActivityData
import "BatteriesData.js" as BatteriesData

Item {
    id: root
    property string widgetType: "weather"
    property string widgetSize: "small"
    property string widgetStyle: "liquid"
    property bool dark: true
    property string family: "Inter"
    property string mode: "auto"
    property var appearance: ({})
    property var activity: ({})
    property var batteries: ({})
    property var timer: ({})
    property var image: ({})
    readonly property var look: Appearance.resolve(widgetType, widgetStyle, appearance, mode, family, dark, .8)
    readonly property var definition: Catalog.find(widgetType)
    readonly property var footprint: Catalog.dimensions(widgetSize)
    readonly property var visual: loader.item
    implicitWidth: footprint[0]
    implicitHeight: footprint[1]
    Component {
        id: weather
        WeatherWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; hasData: true; located: false
            city: "Demo City"; temp: 18; hi: 21; lo: 13; cond: "Partly cloudy"; kind: "sun"
            hourly: [{h: "Now", t: 18, k: "sun"}, {h: "11", t: 19, k: "sun"}, {h: "12", t: 21, k: "sun"}, {h: "13", t: 20, k: "cloud"}, {h: "14", t: 19, k: "cloud"}, {h: "15", t: 18, k: "sun"}]
            daily: [{d: "Today", lo: 13, hi: 21, k: "sun"}, {d: "Sat", lo: 14, hi: 22, k: "sun"}, {d: "Sun", lo: 12, hi: 19, k: "cloud"}, {d: "Mon", lo: 11, hi: 18, k: "rain"}, {d: "Tue", lo: 13, hi: 20, k: "sun"}]
        }
    }
    Component {
        id: calendar
        CalendarWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            mode: root.look.theme; preview: true; darkGlass: root.look.dark; now: new Date(2026, 9, 23, 9, 41)
        }
    }
    Component {
        id: clock
        ClockWidget {
            secondsMode: root.look.secondsMode
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark
        }
    }
    Component {
        id: player
        PlayerWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; contentScale: root.look.contentScale
            hasPlayer: true; title: "Night Walk"; artist: "Demo Artist"; album: "Evening"
            playing: false; position: 74; length: 216; tintOverride: root.look.tint === "transparent" ? "#746ba5" : root.look.tint
        }
    }
    Component {
        id: activityPreview
        ActivityWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; settings: root.activity
            sample: ActivityData.demoSample(1060, 60); history: ActivityData.demoHistory(); stale: false
        }
    }
    Component {
        id: timerPreview
        TimerWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; settings: root.timer
        }
    }
    Component {
        id: batteriesPreview
        BatteriesWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; settings: root.batteries; entries: BatteriesData.demoFor(root.batteries)
        }
    }
    Component {
        id: notesPreview
        NotesWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; ready: true
            notes: [{id: "demo", body: "Shopping\nMilk, bread, fruit"}]
            body: "Shopping\nMilk, bread, fruit"
        }
    }
    Component {
        id: remindersPreview
        RemindersWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; ready: true
            tasks: [{id: "a", title: "Try the new widgets", done: false}, {id: "b", title: "Open Reminders", done: true}]
        }
    }
    Component {
        id: imagePreview
        ImageWidget {
            anchors.fill: parent; size: root.widgetSize; style: root.widgetStyle; fam: root.look.family; textScale: root.look.textScale
            preview: true; darkGlass: root.look.dark; settings: root.image
        }
    }
    Loader {
        id: loader; anchors.fill: parent
        sourceComponent: root.definition ? ({WeatherWidget: weather, CalendarWidget: calendar, ClockWidget: clock, PlayerWidget: player, ActivityWidget: activityPreview, BatteriesWidget: batteriesPreview, TimerWidget: timerPreview, NotesWidget: notesPreview, RemindersWidget: remindersPreview, ImageWidget: imagePreview})[root.definition.component] || null : null
    }
}
