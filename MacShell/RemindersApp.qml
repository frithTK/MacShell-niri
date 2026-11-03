import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Locale" as Language
import "RemindersText.js" as Texts
import "RemindersTime.js" as ReminderTime

Scope {
    id: root
    property var hub: null
    readonly property var i18n: hub && hub.translations ? hub.translations : Language.I18n
    readonly property string language: i18n.activeLanguage
    readonly property bool dark: hub && hub.dock ? hub.dock.darkMode : true
    readonly property string family: hub && hub.dock ? hub.dock.fontFamily : "Inter Variable"
    readonly property color ink: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color muted: dark ? "#aaaab3" : "#686870"
    property bool closePending: false
    property bool backgroundEnabled: true
    property string taskDraft: ""
    property string listDraft: ""
    property alias controller: controller
    property alias window: win
    readonly property var currentList: controller.lists.find(l => l.id === controller.selectedList) || null
    function tr(key) { return Texts.text(language, key); }
    function repeatLabel(rule) {
        return tr(({none: "repeatNone", daily: "repeatDaily", weekly: "repeatWeekly", monthly: "repeatMonthly"})[rule] || "repeatNone");
    }
    function open() { closePending = false; win.show(); win.raise(); win.requestActivate(); }
    function requestClose() { if (!controller.busy) win.hide(); else closePending = true; }
    component ActionButton: Button {
        id: control
        implicitHeight: 32; implicitWidth: Math.max(36, label.implicitWidth + 24)
        font.family: root.family; font.pixelSize: 12
        contentItem: Text { id: label; text: control.text; color: root.ink; opacity: control.enabled ? 1 : .45; font: control.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle {
            radius: 8; color: control.down ? (root.dark ? "#5b5b60" : "#c9c9ce") : control.hovered ? (root.dark ? "#4c4c51" : "#eeeeef") : (root.dark ? "#3a3a3e" : "#ffffff")
            border.width: 1; border.color: control.activeFocus ? (root.dark ? "#83bfff" : "#2273c9") : (root.dark ? "#525257" : "#d0d0d5")
            opacity: control.enabled ? 1 : .5
        }
    }
    component InputField: TextField {
        color: root.ink; placeholderTextColor: root.muted; font.family: root.family; font.pixelSize: 13
        leftPadding: 10; selectByMouse: true; implicitHeight: 34
        background: Rectangle { radius: 8; color: root.dark ? "#3a3a3e" : "#ffffff"; border.width: 1; border.color: parent.activeFocus ? (root.dark ? "#83bfff" : "#2273c9") : (root.dark ? "#515155" : "#d0d0d5") }
    }
    component ThemedDialog: Dialog {
        header: Text {
            text: parent.title; color: root.ink; font.family: root.family
            font.pixelSize: 17; font.weight: Font.DemiBold
            leftPadding: 20; rightPadding: 20; topPadding: 18; bottomPadding: 4
            wrapMode: Text.Wrap
        }
    }
    RemindersController {
        id: controller
        enabled: root.backgroundEnabled || win.visible || root.closePending || busy
        storePath: (Quickshell.env("MACSHELL_REMINDERS_DATA_HOME") || Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/macshell/reminders/tasks.sqlite3"
        onSettled: if (root.closePending && !error) { root.closePending = false; win.hide(); }
    }
    Window {
        id: win; title: "Reminders"; visible: false; width: 920; height: 680; minimumWidth: 650; minimumHeight: 440
        color: "transparent"; flags: Qt.Window | Qt.FramelessWindowHint
        onClosing: close => { close.accepted = false; root.requestClose(); }
        Rectangle { anchors.fill: parent; radius: 12; color: root.dark ? "#1c1c1e" : "#f7f7f8"; border.width: 1; border.color: root.dark ? "#49494f" : "#c8c8ce" }
        AppTitlebar {
            id: titlebar; x: 1; width: parent.width - 2
            window: win; dark: root.dark; family: root.family; title: root.tr("title")
            controlObjectPrefix: "remindersWindowControl_"
            closeLabel: root.tr("close"); minimizeLabel: root.tr("minimize"); maximizeLabel: root.tr("maximize")
            onCloseRequested: root.requestClose()
        }
        Loader {
            anchors { left: parent.left; right: parent.right; top: titlebar.bottom; bottom: parent.bottom; margins: 1 }
            active: win.visible
            sourceComponent: RowLayout {
                spacing: 0
                Rectangle {
                    Layout.fillHeight: true; Layout.preferredWidth: 255; color: root.dark ? "#29292c" : "#eeeeef"
                    Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: root.dark ? "#424245" : "#d4d4d8" }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 12; spacing: 9
                        Text { text: root.tr("lists"); color: root.ink; font.family: root.family; font.pixelSize: 21; font.weight: Font.DemiBold }
                        ListView {
                            id: listView; objectName: "remindersLists"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                            model: controller.lists
                            delegate: Rectangle {
                                id: listRow
                                required property var modelData
                                objectName: "remindersList_" + modelData.id
                                width: ListView.view.width; height: 42; radius: 8
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.id === "inbox" ? root.tr("inbox") : modelData.name
                                border.width: activeFocus ? 1 : 0; border.color: root.dark ? "#83bfff" : "#2273c9"
                                Keys.onReturnPressed: if (!controller.busy) controller.selectList(modelData.id)
                                Keys.onSpacePressed: if (!controller.busy) controller.selectList(modelData.id)
                                color: controller.selectedList === modelData.id ? (root.dark ? "#364e69" : "#c6def9") : listMouse.containsMouse ? (root.dark ? "#363639" : "#e2e2e5") : "transparent"
                                Rectangle {
                                    x: 10; anchors.verticalCenter: parent.verticalCenter; width: 24; height: 24; radius: 7
                                    color: listRow.modelData.id === "inbox" ? "#0a84ff" : "#ff9f0a"
                                    Text { anchors.centerIn: parent; text: listRow.modelData.id === "inbox" ? "✓" : "≡"; color: "white"; font.pixelSize: 14; font.weight: Font.DemiBold }
                                }
                                Text {
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 43; rightMargin: 10 }
                                    text: parent.modelData.id === "inbox" ? root.tr("inbox") : parent.modelData.name; color: root.ink; font.family: root.family; font.pixelSize: 13; elide: Text.ElideRight; textFormat: Text.PlainText
                                }
                                MouseArea { id: listMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !controller.busy; onClicked: { listRow.forceActiveFocus(); controller.selectList(listRow.modelData.id); } }
                            }
                        }
                        ActionButton { objectName: "remindersTrash"; Layout.fillWidth: true; text: root.tr("trash"); enabled: controller.ready && !controller.busy; onClicked: trashDialog.open() }
                        RowLayout {
                            Layout.fillWidth: true
                            InputField { id: listInput; objectName: "remindersNewList"; Layout.fillWidth: true; placeholderText: root.tr("newList"); text: root.listDraft; onTextChanged: root.listDraft = text; onAccepted: if (!controller.busy) controller.createList(text) }
                            ActionButton { objectName: "remindersAddList"; text: "+"; Accessible.name: root.tr("newList"); enabled: controller.ready && !controller.busy && !!listInput.text.trim(); onClicked: controller.createList(listInput.text) }
                        }
                        ActionButton { objectName: "remindersUndoList"; Layout.fillWidth: true; visible: !!controller.lastDeletedList; text: root.tr("undoList"); enabled: controller.ready && !controller.busy; onClicked: controller.undoList() }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; color: "transparent"
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 16; spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true; color: root.ink; font.family: root.family; font.pixelSize: 20; font.weight: Font.DemiBold; elide: Text.ElideRight
                                text: { var list = controller.lists.find(l => l.id === controller.selectedList); return !list || list.id === "inbox" ? root.tr("inbox") : list.name; }
                                textFormat: Text.PlainText
                            }
                            AppIconButton { objectName: "remindersRenameList"; visible: !!root.currentList && root.currentList.id !== "inbox"; glyph: "pencil"; label: root.tr("renameList"); dark: root.dark; enabled: controller.ready && !controller.busy; onClicked: { listEditDialog.list = root.currentList; listEditInput.text = root.currentList.name; listEditDialog.open(); listEditInput.forceActiveFocus(); } }
                            AppIconButton { objectName: "remindersDeleteList"; visible: !!root.currentList && root.currentList.id !== "inbox"; glyph: "trash"; label: root.tr("deleteList"); dark: root.dark; enabled: controller.ready && !controller.busy; onClicked: { listDeleteDialog.list = root.currentList; listDeleteDialog.open(); } }
                            ActionButton { objectName: "remindersUndoDelete"; visible: !!controller.lastDeleted && controller.lists.some(l => l.id === controller.lastDeleted.list_id); text: root.tr("restore"); enabled: controller.ready && !controller.busy; onClicked: controller.undoDelete() }
                        }
                        Text { Layout.fillWidth: true; text: root.tr("noAlerts"); color: root.muted; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap }
                        Text { Layout.fillWidth: true; visible: controller.schedulerState === "unavailable"; text: root.tr("schedulerUnavailable"); color: root.dark ? "#ffb3a8" : "#a32618"; font.family: root.family; font.pixelSize: 12; wrapMode: Text.Wrap }
                        RowLayout {
                            visible: controller.error !== ""; Layout.fillWidth: true
                            Text { Layout.fillWidth: true; text: root.tr("failed") + " " + controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; font.family: root.family; textFormat: Text.PlainText }
                            ActionButton { text: root.tr("retry"); enabled: controller.ready && !controller.busy; onClicked: controller.load() }
                        }
                        AppSearchField { id: search; objectName: "remindersSearch"; Layout.fillWidth: true; placeholderText: root.tr("search"); Accessible.name: placeholderText; dark: root.dark; font.family: root.family }
                        ListView {
                            id: taskView; objectName: "remindersTasks"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                            model: controller.tasks.filter(t => t.list_id === controller.selectedList && (!search.text || t.title.toLocaleLowerCase().indexOf(search.text.toLocaleLowerCase()) >= 0))
                            delegate: Rectangle {
                                id: taskRow; required property var modelData
                                width: ListView.view.width; height: modelData.due_at === null ? 58 : 72; radius: 11; color: root.dark ? "#29292d" : "#ffffff"
                                border.width: 1; border.color: root.dark ? "#38383c" : "#e2e2e6"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                                    ActionButton {
                                        id: completion
                                        objectName: "remindersToggle_" + taskRow.modelData.id; text: taskRow.modelData.done ? "✓" : ""; implicitWidth: 36
                                        Accessible.name: taskRow.modelData.title; Accessible.role: Accessible.CheckBox; Accessible.checked: !!taskRow.modelData.done
                                        enabled: controller.ready && !controller.busy
                                        background: Item {}
                                        contentItem: Item {
                                            Rectangle {
                                                anchors.centerIn: parent; width: 22; height: 22; radius: 11
                                                color: taskRow.modelData.done ? "#0a84ff" : "transparent"
                                                border.width: completion.activeFocus ? 2 : 1
                                                border.color: taskRow.modelData.done ? "#0a84ff" : (root.dark ? "#92929a" : "#8e8e96")
                                                Text { anchors.centerIn: parent; visible: taskRow.modelData.done; text: "✓"; color: "white"; font.pixelSize: 14; font.bold: true }
                                            }
                                        }
                                        onClicked: controller.update(taskRow.modelData, "done", !taskRow.modelData.done)
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 2
                                        Text { Layout.fillWidth: true; text: taskRow.modelData.title; color: root.ink; opacity: taskRow.modelData.done ? .55 : 1; font.family: root.family; font.pixelSize: 14; font.strikeout: !!taskRow.modelData.done; elide: Text.ElideRight; textFormat: Text.PlainText }
                                        Text { Layout.fillWidth: true; visible: taskRow.modelData.due_at !== null; text: ReminderTime.format(taskRow.modelData.due_at) + (taskRow.modelData.repeat_rule && taskRow.modelData.repeat_rule !== "none" ? " · " + root.repeatLabel(taskRow.modelData.repeat_rule) : "") + (taskRow.modelData.alert_state === "uncertain" ? " · " + root.tr("alertUnknown") : taskRow.modelData.alert_error === "notification_failed" ? " · " + root.tr("alertFailed") : taskRow.modelData.alert_state === "delivered" ? " · " + root.tr("alertDelivered") : ""); color: root.muted; font.family: root.family; font.pixelSize: 11; elide: Text.ElideRight }
                                    }
                                    ActionButton { objectName: "remindersResolve_" + taskRow.modelData.id; visible: taskRow.modelData.alert_state === "uncertain"; text: root.tr("resolve"); enabled: controller.ready && !controller.busy; onClicked: { alertDialog.task = taskRow.modelData; alertDialog.open(); } }
                                    AppIconButton { objectName: "remindersEdit_" + taskRow.modelData.id; glyph: "pencil"; label: root.tr("edit"); dark: root.dark; enabled: controller.ready && !controller.busy; onClicked: { editDialog.task = taskRow.modelData; editInput.text = taskRow.modelData.title; dueInput.text = ReminderTime.format(taskRow.modelData.due_at); repeatInput.currentIndex = Math.max(0, repeatInput.rules.indexOf(taskRow.modelData.repeat_rule || "none")); editDialog.open(); editInput.forceActiveFocus(); } }
                                    AppIconButton { objectName: "remindersDelete_" + taskRow.modelData.id; glyph: "trash"; label: root.tr("remove"); dark: root.dark; enabled: controller.ready && !controller.busy; onClicked: controller.update(taskRow.modelData, "deleted", true) }
                                }
                            }
                            Text { anchors.centerIn: parent; visible: taskView.count === 0; text: root.tr("empty"); color: root.muted; font.family: root.family }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            InputField { id: taskInput; objectName: "remindersNewTask"; Layout.fillWidth: true; placeholderText: root.tr("taskPlaceholder"); text: root.taskDraft; onTextChanged: root.taskDraft = text; onAccepted: if (!controller.busy) controller.createTask(text) }
                            ActionButton { objectName: "remindersAddTask"; text: root.tr("add"); enabled: controller.ready && !controller.busy && !!taskInput.text.trim(); onClicked: controller.createTask(taskInput.text) }
                        }
                    }
                }
                Connections {
                    target: controller
                    function onTaskCreated(value) { if (taskInput.text === value) { taskInput.clear(); root.taskDraft = ""; } }
                    function onListCreated(value) { if (listInput.text === value) { listInput.clear(); root.listDraft = ""; } }
                    function onTaskUpdated(id, field) { if (field === "title" && editDialog.task && id === editDialog.task.id) editDialog.close(); if (field === "resolve-alert" && alertDialog.task && id === alertDialog.task.id) alertDialog.close(); }
                    function onListUpdated(id, field) {
                        if (field === "name" && listEditDialog.list && id === listEditDialog.list.id) listEditDialog.close();
                        if (field === "deleted" && listDeleteDialog.list && id === listDeleteDialog.list.id) listDeleteDialog.close();
                    }
                }
                ThemedDialog {
                    id: editDialog; objectName: "remindersEditDialog"; parent: Overlay.overlay; modal: true; anchors.centerIn: parent; implicitWidth: 460
                    property var task: null
                    title: root.tr("editTitle"); closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        width: 420; spacing: 12
                        InputField { id: editInput; objectName: "remindersEditInput"; Layout.fillWidth: true; onAccepted: if (saveEdit.enabled) controller.setDetails(editDialog.task, text, dueInput.parsed.value, repeatInput.rule) }
                        Text { text: root.tr("due"); color: root.ink; font.family: root.family; font.pixelSize: 12 }
                        InputField { id: dueInput; objectName: "remindersDueInput"; Layout.fillWidth: true; placeholderText: "YYYY-MM-DD HH:MM"; readonly property var parsed: ReminderTime.parse(text, editDialog.task ? editDialog.task.due_at : null); onAccepted: if (saveEdit.enabled) controller.setDetails(editDialog.task, editInput.text, parsed.value, repeatInput.rule) }
                        Text { Layout.fillWidth: true; text: dueInput.parsed.ok ? root.tr("dueHint") : root.tr(dueInput.parsed.error === "ambiguous" ? "dueAmbiguous" : "dueInvalid"); color: dueInput.parsed.ok ? root.muted : (root.dark ? "#ffb3a8" : "#a32618"); wrapMode: Text.Wrap; font.family: root.family; font.pixelSize: 12 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 12
                            Text { text: root.tr("repeat"); color: root.ink; font.family: root.family; font.pixelSize: 12; Layout.fillWidth: true }
                            ComboBox {
                                id: repeatInput; objectName: "remindersRepeat"; Layout.preferredWidth: 200; Layout.preferredHeight: 32
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
                        Text { Layout.fillWidth: true; visible: repeatInput.rule !== "none"; text: dueInput.parsed.ok && dueInput.parsed.value === null ? root.tr("repeatNeedsDue") : root.tr("repeatHint"); color: dueInput.parsed.ok && dueInput.parsed.value === null ? (root.dark ? "#ffb3a8" : "#a32618") : root.muted; wrapMode: Text.Wrap; font.family: root.family; font.pixelSize: 12 }
                        Text { Layout.fillWidth: true; visible: !!controller.error; text: controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { text: root.tr("cancel"); enabled: !controller.busy; onClicked: editDialog.close() }
                            ActionButton { id: saveEdit; objectName: "remindersEditSave"; text: root.tr("save"); enabled: controller.ready && !controller.busy && !!editInput.text.trim() && dueInput.parsed.ok && (repeatInput.rule === "none" || dueInput.parsed.value !== null); onClicked: controller.setDetails(editDialog.task, editInput.text, dueInput.parsed.value, repeatInput.rule) }
                        }
                    }
                }
                ThemedDialog {
                    id: alertDialog; objectName: "remindersAlertDialog"; parent: Overlay.overlay; modal: true; anchors.centerIn: parent; implicitWidth: 460
                    property var task: null
                    title: root.tr("resolveTitle"); closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        implicitWidth: 420; spacing: 12
                        Text { Layout.fillWidth: true; text: root.tr(alertDialog.task && alertDialog.task.done ? "resolveCompleted" : "resolveMessage"); color: root.ink; wrapMode: Text.Wrap; font.family: root.family }
                        Text { Layout.fillWidth: true; visible: !!controller.error; text: controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { text: root.tr("cancel"); enabled: !controller.busy; onClicked: alertDialog.close() }
                            ActionButton { objectName: "remindersMarkHandled"; text: root.tr("markHandled"); enabled: controller.ready && !controller.busy; onClicked: controller.resolveAlert(alertDialog.task, false) }
                            ActionButton { objectName: "remindersRetryAlert"; text: root.tr("retryAlert"); enabled: controller.ready && !controller.busy && !!alertDialog.task && !alertDialog.task.done; onClicked: controller.resolveAlert(alertDialog.task, true) }
                        }
                    }
                }
                ThemedDialog {
                    id: trashDialog; objectName: "remindersTrashDialog"; parent: Overlay.overlay; modal: true; anchors.centerIn: parent; implicitWidth: 500
                    title: root.tr("trash"); closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        implicitWidth: 460; spacing: 12
                        ListView {
                            id: trashView; objectName: "remindersTrashList"; Layout.fillWidth: true; Layout.preferredHeight: 280; clip: true; spacing: 4
                            model: controller.deletedLists.map(x => ({kind: "list", item: x})).concat(controller.deletedTasks.map(x => ({kind: "task", item: x})))
                            delegate: Rectangle {
                                id: trashRow; required property var modelData
                                width: ListView.view.width; height: 48; radius: 8; color: root.dark ? "#414146" : "#e1e1e6"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                                    Text { Layout.fillWidth: true; text: (trashRow.modelData.kind === "list" ? root.tr("deletedList") + ": " : "") + (trashRow.modelData.kind === "list" ? trashRow.modelData.item.name : trashRow.modelData.item.title); color: root.ink; font.family: root.family; elide: Text.ElideRight; textFormat: Text.PlainText }
                                    ActionButton {
                                        objectName: "remindersRestore_" + trashRow.modelData.item.id; text: root.tr("restoreItem"); enabled: controller.ready && !controller.busy
                                        onClicked: if (trashRow.modelData.kind === "list") controller.updateList(trashRow.modelData.item, "deleted", false); else controller.update(trashRow.modelData.item, "deleted", false)
                                    }
                                }
                            }
                            Text { anchors.centerIn: parent; visible: trashView.count === 0; text: root.tr("trashEmpty"); color: root.muted; font.family: root.family }
                        }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { objectName: "remindersTrashClose"; text: root.tr("cancel"); enabled: !controller.busy; onClicked: trashDialog.close() }
                        }
                    }
                }
                ThemedDialog {
                    id: listEditDialog; objectName: "remindersListEditDialog"; parent: Overlay.overlay; modal: true; anchors.centerIn: parent; implicitWidth: 460
                    property var list: null
                    title: root.tr("renameList"); closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        width: 420; spacing: 12
                        InputField { id: listEditInput; objectName: "remindersListEditInput"; Layout.fillWidth: true; onAccepted: if (controller.ready && !controller.busy && text.trim()) controller.updateList(listEditDialog.list, "name", text) }
                        Text { Layout.fillWidth: true; visible: !!controller.error; text: controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { text: root.tr("cancel"); enabled: !controller.busy; onClicked: listEditDialog.close() }
                            ActionButton { objectName: "remindersListEditSave"; text: root.tr("save"); enabled: controller.ready && !controller.busy && !!listEditInput.text.trim(); onClicked: controller.updateList(listEditDialog.list, "name", listEditInput.text) }
                        }
                    }
                }
                ThemedDialog {
                    id: listDeleteDialog; objectName: "remindersListDeleteDialog"; parent: Overlay.overlay; modal: true; anchors.centerIn: parent; implicitWidth: 460
                    property var list: null
                    title: root.tr("deleteList"); closePolicy: controller.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
                    background: Rectangle { radius: 12; color: root.dark ? "#303034" : "#f4f4f6"; border.color: root.dark ? "#56565d" : "#c8c8ce" }
                    contentItem: ColumnLayout {
                        width: 420; spacing: 12
                        Text { Layout.fillWidth: true; text: root.tr("deleteListQuestion"); color: root.ink; wrapMode: Text.Wrap; font.family: root.family }
                        Text { Layout.fillWidth: true; visible: !!controller.error; text: controller.error; color: root.dark ? "#ffb3a8" : "#a32618"; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            ActionButton { text: root.tr("cancel"); enabled: !controller.busy; onClicked: listDeleteDialog.close() }
                            ActionButton { objectName: "remindersConfirmListDelete"; text: root.tr("deleteList"); enabled: controller.ready && !controller.busy; onClicked: controller.updateList(listDeleteDialog.list, "deleted", true) }
                        }
                    }
                }
            }
        }
        MouseArea { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 10; height: 10; cursorShape: Qt.SizeFDiagCursor; onPressed: win.startSystemResize(Qt.RightEdge | Qt.BottomEdge) }
        Shortcut { sequence: "Ctrl+W"; enabled: win.visible && win.active; onActivated: root.requestClose() }
    }
}
