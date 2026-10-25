import QtQuick

// Keep delegates (and their input registrations) stable when other outputs change.
ListModel {
    id: root
    property var rows: []
    onRowsChanged: sync()
    function sync() {
        for (var i = 0; i < rows.length; i++) {
            var item = rows[i], found = -1;
            for (var j = i; j < count; j++) if (get(j).wid === item.wid) { found = j; break; }
            if (found < 0) insert(i, item);
            else { if (found !== i) move(found, i, 1); set(i, item); }
        }
        if (count > rows.length) remove(rows.length, count - rows.length);
    }
}
