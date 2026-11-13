import QtQuick
import Quickshell
import Quickshell.Io
import "AboutState.js" as AboutState

Scope {
    id: root
    property string osRelease: ""
    property string hostname: ""
    property string kernel: ""
    property string cpuinfo: ""
    property string meminfo: ""
    property string dmiVendor: ""
    property string dmiProduct: ""
    property string drm: ""
    property string niriVersion: ""
    property string version: ""
    readonly property var snapshot: AboutState.snapshot({
        osRelease: root.osRelease,
        hostname: root.hostname,
        kernel: root.kernel,
        cpuinfo: root.cpuinfo,
        meminfo: root.meminfo,
        dmiVendor: root.dmiVendor,
        dmiProduct: root.dmiProduct,
        drm: root.drm,
        niriVersion: root.niriVersion,
        version: root.version
    })

    function mergeDrm(current, next) {
        var chunk = String(next || "");
        if (!chunk)
            return current;
        if (!current)
            return chunk;
        if (current.indexOf(chunk) >= 0)
            return current;
        return current + "\n---\n" + chunk;
    }

    FileView { path: "/etc/os-release"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.osRelease = text() }
    FileView { path: "/etc/hostname"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.hostname = text().replace(/[\n\r]/g, "") }
    FileView { path: "/proc/sys/kernel/osrelease"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.kernel = text().replace(/[\n\r]/g, "") }
    FileView { path: "/proc/cpuinfo"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.cpuinfo = text() }
    FileView { path: "/proc/meminfo"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.meminfo = text() }
    FileView { path: "/sys/class/dmi/id/sys_vendor"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.dmiVendor = text().replace(/[\n\r]/g, "") }
    FileView { path: "/sys/class/dmi/id/product_name"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.dmiProduct = text().replace(/[\n\r]/g, "") }
    FileView {
        path: decodeURIComponent(Qt.resolvedUrl("VERSION").toString().replace(/^file:\/\//, ""))
        preload: true; watchChanges: false; printErrors: false
        onLoaded: root.version = text().replace(/[\n\r]/g, "")
    }
    FileView { path: "/sys/class/drm/card0/device/uevent"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.drm = root.mergeDrm(root.drm, text()) }
    FileView { path: "/sys/class/drm/card1/device/uevent"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.drm = root.mergeDrm(root.drm, text()) }
    FileView { path: "/sys/class/drm/card2/device/uevent"; preload: true; watchChanges: false; printErrors: false; onLoaded: root.drm = root.mergeDrm(root.drm, text()) }

    Process {
        running: true
        command: ["niri", "--version"]
        stdout: StdioCollector {
            onStreamFinished: root.niriVersion = String(text).replace(/^\s+|\s+$/g, "")
        }
    }
}
