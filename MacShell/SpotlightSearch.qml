// Filename search for Spotlight. Ranking lives in SpotlightRank.js; the overlay stays in MacBar.
import QtQuick
import Quickshell
import Quickshell.Io
import "FileSearch.js" as FileSearch
import "SpotlightRank.js" as Rank

Scope {
    id: root
    property string helper: decodeURIComponent(Qt.resolvedUrl("file-search.sh").toString().replace(/^file:\/\//, ""))
    property string query: ""
    property string searchingFor: ""
    property bool pending: false
    property var hits: []

    function update(q) {
        query = q;
        hits = [];
        pending = true;
        debounce.restart();
    }
    function clear() {
        debounce.stop();
        if (proc.running) proc.running = false;
        query = "";
        searchingFor = "";
        hits = [];
        pending = false;
    }
    function sync(text) {
        var parsed = FileSearch.parse(text);
        if (parsed.exclusive) {
            if (FileSearch.ready(parsed.query)) update(parsed.query);
            else clear();
            return;
        }
        if (FileSearch.ready(parsed.query) && !Rank.skipFileSearch(parsed.query))
            update(parsed.query);
        else
            clear();
    }

    Process {
        id: proc
        command: ["sh", root.helper, "--limit", "8", "--", root.query]
        stdout: StdioCollector {
            onStreamFinished: {
                var a = text.trim().split("\n").filter(function (x) { return x !== ""; });
                if (root.searchingFor === root.query) {
                    root.hits = a;
                    root.pending = false;
                } else debounce.restart();
            }
        }
        onExited: if (root.searchingFor !== root.query) debounce.restart()
    }
    Timer {
        id: debounce
        interval: 260
        onTriggered: {
            if (root.query.length > 0 && !proc.running) {
                root.searchingFor = root.query;
                root.pending = true;
                proc.running = true;
            }
        }
    }
}
