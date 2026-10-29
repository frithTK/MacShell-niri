import QtQuick
import Quickshell
import Quickshell.Io
import "LocaleConfig.js" as Config

Scope {
    id: root
    function apply(source) {
        var values = Config.parse(source);
        I18n.language = values.ui;
        I18n.region = values.region;
    }
    FileView {
        id: preferences
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/environment.d/90-macshell-locale.conf"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply(text())
        onLoadFailed: root.apply("")
    }
}
