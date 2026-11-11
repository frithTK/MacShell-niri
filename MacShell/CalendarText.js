.pragma library
var messages = {
    en: {title: "Calendar", description: "Local calendar events", comment: "MacShell Calendar",
        close: "Close Calendar", minimize: "Minimize Calendar", maximize: "Maximize Calendar",
        previous: "Previous month", next: "Next month", today: "Today", newEvent: "New event", edit: "Edit event", remove: "Delete event", restore: "Restore event",
        empty: "No events on this day", allDay: "All day", eventTitle: "Title", start: "Starts", end: "Ends", date: "Date", timeHint: "Local time · YYYY-MM-DD HH:MM",
        invalidTime: "Enter valid local times; the end must be after the start.", ambiguous: "This local time occurs twice. Choose another time.",
        save: "Save", cancel: "Cancel", recentlyDeleted: "Recently Deleted", noDeleted: "No deleted events", failed: "Could not save changes.", retry: "Retry",
        repeat: "Repeat", repeatNone: "Never", repeatDaily: "Every day", repeatWeekly: "Every week", repeatMonthly: "Every month",
        repeatHint: "Repeating events stay local. Notifications fire at the start, or at 09:00 on all-day dates. CalDAV and ICS are not available."},
    ru: {title: "Календарь", description: "Локальные события календаря", comment: "Календарь MacShell",
        close: "Закрыть календарь", minimize: "Свернуть календарь", maximize: "Развернуть календарь",
        previous: "Предыдущий месяц", next: "Следующий месяц", today: "Сегодня", newEvent: "Новое событие", edit: "Изменить событие", remove: "Удалить событие", restore: "Восстановить событие",
        empty: "На этот день событий нет", allDay: "Весь день", eventTitle: "Название", start: "Начало", end: "Окончание", date: "Дата", timeHint: "Местное время · ГГГГ-ММ-ДД ЧЧ:ММ",
        invalidTime: "Укажите существующие местные дату и время; окончание должно быть позже начала.", ambiguous: "Это местное время встречается дважды. Выберите другое.",
        save: "Сохранить", cancel: "Отмена", recentlyDeleted: "Недавно удалённые", noDeleted: "Удалённых событий нет", failed: "Не удалось сохранить изменения.", retry: "Повторить",
        repeat: "Повтор", repeatNone: "Никогда", repeatDaily: "Каждый день", repeatWeekly: "Каждую неделю", repeatMonthly: "Каждый месяц",
        repeatHint: "Повторы остаются локальными. Уведомление приходит в начало события или в 09:00 в день события на весь день. CalDAV и ICS недоступны."}
};
function text(language, key) { return (messages[language] || messages.en)[key] || messages.en[key] || key; }
