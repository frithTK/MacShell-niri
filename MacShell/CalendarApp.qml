import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Locale" as Language
import "CalendarText.js" as Texts
import "RemindersTime.js" as LocalTime

Scope {
    id: root
    property var hub: null
    readonly property var i18n: hub && hub.translations ? hub.translations : Language.I18n
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color ink: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color muted: dark ? "#aaaab3" : "#686870"
    readonly property int weekStart: hub && hub.bar && hub.bar.weekStartsMonday ? 1 : 0
    property date selectedDate: new Date()
    property date month: new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1)
    property bool closePending: false
    property bool backgroundEnabled: true
    function repeatLabel(rule) {
        return tr(({none: "repeatNone", daily: "repeatDaily", weekly: "repeatWeekly", monthly: "repeatMonthly"})[rule] || "repeatNone");
    }
    property alias controller: controller
    property alias window: win
    readonly property var visibleEvents: controller.occurrences.length ? controller.occurrences : controller.events
    readonly property var dayEvents: visibleEvents.filter(event => root.onDay(event, root.selectedDate)).sort((a, b) =>
        b.all_day - a.all_day || (a.start_ms || 0) - (b.start_ms || 0) || a.title.localeCompare(b.title))
    function tr(key) { return Texts.text(i18n.activeLanguage, key); }
    function pad(n) { return String(n).padStart(2, "0"); }
    function dateKey(d) { return d.getFullYear() + "-" + pad(d.getMonth()+1) + "-" + pad(d.getDate()); }
    function validDate(s) {
        var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
        if (!m || +m[1] < 1970) return false;
        var d = new Date(+m[1], +m[2]-1, +m[3]);
        return d.getFullYear() === +m[1] && d.getMonth() === +m[2]-1 && d.getDate() === +m[3];
    }
    function onDay(event, day) {
        if (event.all_day) return event.day === dateKey(day);
        var start = new Date(day.getFullYear(), day.getMonth(), day.getDate()).getTime();
        var end = new Date(day.getFullYear(), day.getMonth(), day.getDate()+1).getTime();
        return event.start_ms < end && event.end_ms > start;
    }
    function dayAt(index) {
        var first = new Date(month.getFullYear(), month.getMonth(), 1);
        var lead = (first.getDay() - weekStart + 7) % 7;
        return new Date(month.getFullYear(), month.getMonth(), 1 - lead + index);
    }
    function selectDay(day) { selectedDate = day; month = new Date(day.getFullYear(), day.getMonth(), 1); }
    function changeMonth(delta) { month = new Date(month.getFullYear(), month.getMonth()+delta, 1); }
    function open() { closePending = false; win.show(); win.raise(); win.requestActivate(); }
    function requestClose() { if (!controller.busy) win.hide(); else closePending = true; }
    component ActionButton: Button {
        id: control
        implicitHeight: 32; implicitWidth: Math.max(36, label.implicitWidth + 24)
        font.family: root.family; font.pixelSize: 12
        contentItem: Text { id: label; text: control.text; color: root.ink; opacity: control.enabled ? 1 : .45; font: control.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { radius: 8; color: control.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : control.hovered ? (root.dark ? "#4c4c51" : "#eeeeef") : (root.dark ? "#3a3a3e" : "#ffffff"); border.width: 1; border.color: control.activeFocus ? "#2789ed" : (root.dark ? "#525257" : "#d0d0d5"); opacity: control.enabled ? 1 : .5 }
    }
    component InputField: TextField {
        color: root.ink; placeholderTextColor: root.muted; font.family: root.family; font.pixelSize: 13
        leftPadding: 10; selectByMouse: true; implicitHeight: 34
        background: Rectangle { radius: 8; color: root.dark ? "#3a3a3e" : "#ffffff"; border.width: 1; border.color: parent.activeFocus ? "#2789ed" : (root.dark ? "#515155" : "#d0d0d5") }
    }
    component ThemedDialog: Dialog {
        padding: 16
        background: Rectangle { radius: 12; color: root.dark ? "#29292d" : "#f7f7f8"; border.width: 1; border.color: root.dark ? "#505057" : "#c8c8ce" }
        header: Text { text: parent.title; color: root.ink; font.family: root.family; font.pixelSize: 17; font.weight: Font.DemiBold; leftPadding: 20; rightPadding: 20; topPadding: 18; bottomPadding: 4; wrapMode: Text.Wrap }
    }
    CalendarController {
        id: controller
        enabled: root.backgroundEnabled || win.visible || root.closePending || busy
        storePath: (Quickshell.env("MACSHELL_CALENDAR_DATA_HOME") || Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/macshell/calendar/events.sqlite3"
        onSettled: if (root.closePending && !error) { root.closePending = false; win.hide(); }
    }
    Window {
        id: win; title: "Calendar"; visible: false; width: 940; height: 690; minimumWidth: 700; minimumHeight: 480
        color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.requestClose(); }
        Rectangle { anchors.fill: parent; radius: 12; color: root.dark ? "#1c1c1e" : "#f7f7f8"; border.width: 1; border.color: root.dark ? "#49494f" : "#c8c8ce" }
        AppTitlebar { id: titlebar; x: 1; width: parent.width-2; window: win; dark: root.dark; family: root.family; title: root.tr("title"); controlObjectPrefix: "calendarWindowControl_"; closeLabel: root.tr("close"); minimizeLabel: root.tr("minimize"); maximizeLabel: root.tr("maximize"); onCloseRequested: root.requestClose() }
        Loader {
            anchors { left: parent.left; right: parent.right; top: titlebar.bottom; bottom: parent.bottom; margins: 1 }
            active: win.visible
            sourceComponent: RowLayout {
                id: content
                function editEvent(event) {
                    eventDialog.event = event;
                    eventTitle.text = event ? event.title : "";
                    allDay.checked = event ? !!event.all_day : false;
                    eventDate.text = event && event.all_day ? event.day : root.dateKey(root.selectedDate);
                    var day = root.selectedDate;
                    var start = event && !event.all_day ? event.start_ms : new Date(day.getFullYear(), day.getMonth(), day.getDate(), 9).getTime();
                    var end = event && !event.all_day ? event.end_ms : new Date(day.getFullYear(), day.getMonth(), day.getDate(), 10).getTime();
                    startInput.text = LocalTime.format(start); endInput.text = LocalTime.format(end);
                    repeatInput.currentIndex = Math.max(0, repeatInput.rules.indexOf(event && event.repeat_rule ? event.repeat_rule : "none"));
                    controller.error = ""; eventDialog.open(); eventTitle.forceActiveFocus();
                }
                Connections { target: controller; function onSaved() { eventDialog.close(); } }
                spacing: 0
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; color: "transparent"
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 18; spacing: 9
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; text: root.i18n.formatLocale.standaloneMonthName(root.month.getMonth(), Locale.LongFormat) + " " + root.month.getFullYear(); color: root.ink; font.family: root.family; font.pixelSize: 24; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            ActionButton { objectName: "calendarToday"; text: root.tr("today"); onClicked: root.selectDay(new Date()) }
                            AppIconButton { objectName: "calendarPrevious"; dark: root.dark; glyph: "chevL"; label: root.tr("previous"); onClicked: root.changeMonth(-1) }
                            AppIconButton { objectName: "calendarNext"; dark: root.dark; glyph: "chevR"; label: root.tr("next"); onClicked: root.changeMonth(1) }
                        }
                        GridLayout {
                            Layout.fillWidth: true; columns: 7; columnSpacing: 3
                            Repeater { model: 7; Text { required property int index; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.i18n.formatLocale.dayName((index + root.weekStart) % 7, Locale.ShortFormat); color: root.muted; font.family: root.family; font.pixelSize: 12 } }
                        }
                        GridLayout {
                            Layout.fillWidth: true; Layout.fillHeight: true; columns: 7; rows: 6; columnSpacing: 3; rowSpacing: 3
                            Repeater {
                                model: 42
                                delegate: Button {
                                    id: dayButton; required property int index
                                    property date date: root.dayAt(index)
                                    readonly property bool selected: root.dateKey(date) === root.dateKey(root.selectedDate)
                                    readonly property bool currentMonth: date.getMonth() === root.month.getMonth()
                                    readonly property bool hasEvents: root.visibleEvents.some(event => root.onDay(event, date))
                                    objectName: "calendarDay_" + root.dateKey(date)
                                    Layout.fillWidth: true; Layout.fillHeight: true; padding: 0
                                    Accessible.name: root.dateKey(date)
                                    onClicked: root.selectDay(date)
                                    background: Rectangle { radius: 9; color: dayButton.selected ? (root.dark ? "#374e69" : "#c8dff9") : dayButton.hovered ? (root.dark ? "#333338" : "#e9e9ed") : "transparent"; border.width: dayButton.activeFocus ? 1 : 0; border.color: "#2789ed" }
                                    contentItem: Item {
                                        Text { anchors.centerIn: parent; text: dayButton.date.getDate(); color: root.ink; opacity: dayButton.currentMonth ? 1 : .38; font.family: root.family; font.pixelSize: 15 }
                                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 7; width: 5; height: 5; radius: 3; visible: dayButton.hasEvents; color: "#2789ed" }
                                    }
                                }
                            }
                        }
                        Text { Layout.fillWidth: true; text: root.tr("repeatHint"); color: root.muted; font.family: root.family; font.pixelSize: 11; wrapMode: Text.Wrap }
                    }
                }
                Rectangle {
                    Layout.fillHeight: true; Layout.preferredWidth: 300; color: root.dark ? "#29292c" : "#eeeeef"
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 14; spacing: 9
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; text: root.selectedDate.getDate() + " " + root.i18n.formatLocale.monthName(root.selectedDate.getMonth(), Locale.LongFormat); color: root.ink; font.family: root.family; font.pixelSize: 20; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            AppIconButton { objectName: "calendarTrash"; dark: root.dark; glyph: "trash"; label: root.tr("recentlyDeleted"); enabled: controller.ready && !controller.busy; onClicked: trashDialog.open() }
                            AppIconButton { objectName: "calendarAdd"; dark: root.dark; glyph: "plus"; label: root.tr("newEvent"); enabled: controller.ready && !controller.busy; onClicked: content.editEvent(null) }
                        }
                        Text { visible: controller.error !== ""; Layout.fillWidth: true; text: root.tr("failed") + " " + controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        ListView {
                            id: events; objectName: "calendarEvents"; Layout.fillWidth: true; Layout.fillHeight: true; spacing: 6; clip: true; model: root.dayEvents
                            Text { anchors.centerIn: parent; width: parent.width; visible: events.count === 0; text: root.tr("empty"); horizontalAlignment: Text.AlignHCenter; color: root.muted; font.family: root.family; wrapMode: Text.Wrap }
                            delegate: Rectangle {
                                id: row; required property var modelData; width: ListView.view.width; height: 74; radius: 9; color: root.dark ? "#38383d" : "#ffffff"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 5
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 2
                                        Text { Layout.fillWidth: true; text: row.modelData.title; textFormat: Text.PlainText; color: root.ink; font.family: root.family; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                        Text { Layout.fillWidth: true; text: (row.modelData.all_day ? root.tr("allDay") : LocalTime.format(row.modelData.start_ms) + " – " + LocalTime.format(row.modelData.end_ms)) + (row.modelData.repeat_rule && row.modelData.repeat_rule !== "none" ? " · " + root.repeatLabel(row.modelData.repeat_rule) : ""); color: root.muted; font.family: root.family; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                    }
                                    AppIconButton { objectName: "calendarEdit_" + row.modelData.id; dark: root.dark; glyph: "pencil"; label: root.tr("edit"); enabled: controller.ready && !controller.busy; onClicked: content.editEvent(row.modelData) }
                                    AppIconButton { objectName: "calendarDelete_" + row.modelData.id; dark: root.dark; glyph: "trash"; label: root.tr("remove"); enabled: controller.ready && !controller.busy; onClicked: controller.setDeleted(row.modelData, true) }
                                }
                            }
                        }
                    }
                }
                ThemedDialog {
                    id: eventDialog; objectName: "calendarEventDialog"; parent: Overlay.overlay; anchors.centerIn: parent; modal: true; implicitWidth: 460
                    property var event: null
                    title: event ? root.tr("edit") : root.tr("newEvent")
                    ColumnLayout {
                        width: 420; spacing: 9
                        InputField { id: eventTitle; objectName: "calendarEventTitle"; Layout.fillWidth: true; placeholderText: root.tr("eventTitle"); maximumLength: 500 }
                        CheckBox {
                            id: allDay; objectName: "calendarAllDay"; text: root.tr("allDay"); font.family: root.family
                            contentItem: Text { text: allDay.text; color: root.ink; font: allDay.font; verticalAlignment: Text.AlignVCenter; leftPadding: allDay.indicator.width + allDay.spacing }
                        }
                        InputField { id: eventDate; objectName: "calendarEventDate"; visible: allDay.checked; Layout.fillWidth: true; placeholderText: "YYYY-MM-DD"; Accessible.name: root.tr("date") }
                        Text { visible: !allDay.checked; text: root.tr("timeHint"); color: root.muted; font.family: root.family; font.pixelSize: 12 }
                        InputField { id: startInput; objectName: "calendarEventStart"; visible: !allDay.checked; Layout.fillWidth: true; placeholderText: root.tr("start"); Accessible.name: root.tr("start"); readonly property var parsed: LocalTime.parse(text, eventDialog.event && !eventDialog.event.all_day ? eventDialog.event.start_ms : null) }
                        InputField { id: endInput; objectName: "calendarEventEnd"; visible: !allDay.checked; Layout.fillWidth: true; placeholderText: root.tr("end"); Accessible.name: root.tr("end"); readonly property var parsed: LocalTime.parse(text, eventDialog.event && !eventDialog.event.all_day ? eventDialog.event.end_ms : null) }
                        Text { Layout.fillWidth: true; visible: controller.error !== ""; text: root.tr("failed") + " " + controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        Text { Layout.fillWidth: true; visible: !allDay.checked && (!startInput.parsed.ok || !endInput.parsed.ok || startInput.parsed.value === null || endInput.parsed.value === null || endInput.parsed.value <= startInput.parsed.value); text: startInput.parsed.error === "ambiguous" || endInput.parsed.error === "ambiguous" ? root.tr("ambiguous") : root.tr("invalidTime"); color: root.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 12
                            Text { text: root.tr("repeat"); color: root.ink; font.family: root.family; font.pixelSize: 12; Layout.fillWidth: true }
                            ComboBox {
                                id: repeatInput; objectName: "calendarRepeat"; Layout.preferredWidth: 200; Layout.preferredHeight: 32
                                readonly property var rules: ["none", "daily", "weekly", "monthly"]
                                readonly property string rule: rules[currentIndex] || "none"
                                model: rules
                                displayText: root.repeatLabel(rule)
                                Accessible.name: root.tr("repeat")
                                font.family: root.family; font.pixelSize: 12
                                contentItem: Text { text: repeatInput.displayText; color: root.ink; font: repeatInput.font; leftPadding: 10; rightPadding: 28; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
                                indicator: Text { x: repeatInput.width - width - 10; anchors.verticalCenter: parent.verticalCenter; text: "▾"; color: root.muted; font.pixelSize: 13 }
                                background: Rectangle { radius: 8; color: root.dark ? "#424247" : "#dedee3"; border.width: repeatInput.activeFocus ? 1 : 0; border.color: root.dark ? "#83bfff" : "#2273c9" }
                                delegate: ItemDelegate {
                                    required property string modelData
                                    required property int index
                                    width: repeatInput.width; text: root.repeatLabel(modelData); highlighted: repeatInput.highlightedIndex === index
                                    contentItem: Text { text: parent.text; color: root.ink; font: repeatInput.font; leftPadding: 8; verticalAlignment: Text.AlignVCenter }
                                    background: Rectangle { radius: 6; color: parent.highlighted ? (root.dark ? "#48576b" : "#c6def9") : "transparent" }
                                }
                                popup: Popup {
                                    y: repeatInput.height + 4; width: repeatInput.width; padding: 4
                                    contentItem: ListView { implicitHeight: contentHeight; model: repeatInput.popup.visible ? repeatInput.delegateModel : null; currentIndex: repeatInput.highlightedIndex; clip: true }
                                    background: Rectangle { radius: 9; color: root.dark ? "#37373c" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                                }
                            }
                        }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { text: root.tr("cancel"); enabled: !controller.busy; onClicked: eventDialog.close() }
                            ActionButton { objectName: "calendarSave"; text: root.tr("save"); enabled: controller.ready && !controller.busy && !!eventTitle.text.trim() && (allDay.checked ? root.validDate(eventDate.text) : startInput.parsed.ok && endInput.parsed.ok && startInput.parsed.value !== null && endInput.parsed.value !== null && endInput.parsed.value > startInput.parsed.value); onClicked: controller.save(eventDialog.event, eventTitle.text, allDay.checked, eventDate.text, startInput.parsed.value, endInput.parsed.value, repeatInput.rule) }
                        }
                    }
                }
                ThemedDialog {
                    id: trashDialog; objectName: "calendarTrashDialog"; parent: Overlay.overlay; anchors.centerIn: parent; modal: true; implicitWidth: 480; title: root.tr("recentlyDeleted")
                    ColumnLayout {
                        width: 440; spacing: 10
                        ListView {
                            id: deletedEvents; objectName: "calendarDeletedEvents"; Layout.fillWidth: true; Layout.preferredHeight: 250; clip: true; model: controller.deleted
                            Text { anchors.centerIn: parent; visible: deletedEvents.count === 0; text: root.tr("noDeleted"); color: root.muted }
                            delegate: RowLayout {
                                required property var modelData; width: ListView.view.width; height: 42
                                Text { Layout.fillWidth: true; text: modelData.title; textFormat: Text.PlainText; color: root.ink; font.family: root.family; elide: Text.ElideRight }
                                AppIconButton { objectName: "calendarRestore_" + modelData.id; dark: root.dark; glyph: "undo"; label: root.tr("restore"); enabled: controller.ready && !controller.busy; onClicked: controller.setDeleted(modelData, false) }
                            }
                        }
                        ActionButton { objectName: "calendarTrashClose"; Layout.alignment: Qt.AlignRight; text: root.tr("cancel"); enabled: !controller.busy; onClicked: trashDialog.close() }
                    }
                }
            }
        }
    }
}
