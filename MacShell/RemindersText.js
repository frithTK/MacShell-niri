.pragma library

var messages = {
    en: {
        title: "Reminders", inbox: "Tasks", lists: "Lists", newList: "New list", add: "Add",
        taskPlaceholder: "New task", empty: "No tasks in this list", edit: "Edit", remove: "Delete",
        restore: "Undo delete", save: "Save", cancel: "Cancel", close: "Close Reminders",
        minimize: "Minimize Reminders", maximize: "Maximize Reminders", failed: "Could not save changes.",
        retry: "Retry", search: "Search tasks", noAlerts: "Due times use the current local time zone.",
        description: "Local task lists", comment: "MacShell Reminders", editTitle: "Edit task",
        renameList: "Rename list", deleteList: "Delete list", undoList: "Undo list deletion",
        deleteListQuestion: "Delete this list? Its tasks can be restored from Recently Deleted.",
        trash: "Recently Deleted", trashEmpty: "No deleted lists or tasks", restoreItem: "Restore", deletedList: "List",
        due: "Due (local time)", dueHint: "YYYY-MM-DD HH:MM — leave empty for no reminder",
        dueInvalid: "Enter a valid local date and time.", dueAmbiguous: "This time occurs twice. Choose another time.",
        repeat: "Repeat", repeatNone: "Never", repeatDaily: "Every day", repeatWeekly: "Every week", repeatMonthly: "Every month",
        repeatHint: "Completing the task schedules its next occurrence in the time zone used when it was set.",
        repeatNeedsDue: "Choose a due time before setting a repeat.",
        alertDelivered: "Notification sent", alertFailed: "Notification failed; retrying", alertUnknown: "Delivery is uncertain",
        resolve: "Review", resolveTitle: "Reminder delivery is uncertain",
        resolveMessage: "The service stopped during delivery. Choose whether to retry or mark it handled.",
        retryAlert: "Send again", markHandled: "Mark handled", schedulerUnavailable: "Reminder service unavailable; alerts are not being sent.",
        resolveCompleted: "This task is completed. Mark it incomplete to retry, or mark the alert handled."
    },
    ru: {
        title: "Напоминания", inbox: "Задачи", lists: "Списки", newList: "Новый список", add: "Добавить",
        taskPlaceholder: "Новая задача", empty: "В этом списке пока нет задач", edit: "Изменить", remove: "Удалить",
        restore: "Вернуть задачу", save: "Сохранить", cancel: "Отмена", close: "Закрыть напоминания",
        minimize: "Свернуть напоминания", maximize: "Развернуть напоминания", failed: "Не удалось сохранить изменения.",
        retry: "Повторить", search: "Поиск задач", noAlerts: "Сроки указаны в текущем местном часовом поясе.",
        description: "Локальные списки задач", comment: "Напоминания MacShell", editTitle: "Изменить задачу",
        renameList: "Переименовать список", deleteList: "Удалить список", undoList: "Вернуть список",
        deleteListQuestion: "Удалить список? Его задачи можно восстановить в разделе «Недавно удалённые».",
        trash: "Недавно удалённые", trashEmpty: "Удалённых списков и задач нет", restoreItem: "Восстановить", deletedList: "Список",
        due: "Срок (местное время)", dueHint: "ГГГГ-ММ-ДД ЧЧ:ММ — пустое поле отключает напоминание",
        dueInvalid: "Введите существующие местные дату и время.", dueAmbiguous: "Это время встречается дважды. Выберите другое.",
        repeat: "Повтор", repeatNone: "Никогда", repeatDaily: "Каждый день", repeatWeekly: "Каждую неделю", repeatMonthly: "Каждый месяц",
        repeatHint: "После выполнения появится следующий срок в часовом поясе, выбранном при настройке.",
        repeatNeedsDue: "Чтобы включить повтор, задайте срок.",
        alertDelivered: "Уведомление отправлено", alertFailed: "Не удалось отправить; повторяем", alertUnknown: "Доставка не подтверждена",
        resolve: "Выбрать", resolveTitle: "Доставка напоминания не подтверждена",
        resolveMessage: "Служба остановилась во время отправки. Повторите уведомление или отметьте его обработанным.",
        retryAlert: "Отправить снова", markHandled: "Обработано", schedulerUnavailable: "Служба напоминаний недоступна; уведомления не отправляются.",
        resolveCompleted: "Задача выполнена. Чтобы повторить уведомление, сначала снимите отметку выполнения; либо отметьте его обработанным."
    }
};
function text(language, key) { return (messages[language] || messages.en)[key] || messages.en[key] || key; }
