import QtQuick
import QtQuick.Dialogs
import "Locale" as Language
import "QuickLook.js" as QuickLook

Column {
    id: page
    required property var t
    required property var bar
    width: parent ? parent.width : 0
    spacing: 10

    readonly property var net: bar && bar.network ? bar.network : null
    readonly property var hotspot: net && net.hotspot ? net.hotspot : null
    readonly property var vpn: net && net.vpn ? net.vpn : null
    readonly property bool busy: net ? net.busy !== "" : false
    readonly property var ownLinks: (net && net.links ? net.links : []).filter(function (item) { return !!item.controllable; })
    readonly property var otherLinks: (net && net.links ? net.links : []).filter(function (item) { return !item.controllable; })
    property string confirm: ""
    property string method: "none"
    property string pac: ""
    property string http: ""
    property string https: ""
    property string socks: ""
    property string bypass: ""
    property bool editing: false
    property string ssid: "MacShell"
    property bool ssidTouched: false
    property string password: ""
    property bool showPassword: false
    property string vpnTyped: ""
    property string notice: ""
    property string noticeAt: ""

    function forget() { notice = ""; noticeAt = ""; }
    function note(scope, key) { noticeAt = scope; notice = Language.I18n.text(key); }
    function sectionError(scope) {
        if (noticeAt === scope && notice !== "") return notice;
        return net && net.fault === scope && net.error ? net.error : "";
    }
    function linkStatus(link) {
        var parts = [];
        if (!link.controllable) parts.push(Language.I18n.text("network.vpn_external"));
        parts.push(link.active ? Language.I18n.text("ui.t_22965568d22a") : Language.I18n.text("ui.t_87d82c046732"));
        if (link.ip) parts.push(link.ip);
        if (page.vpn && page.vpn.available && link.uuid === page.vpn.uuid && !link.active)
            parts.push(Language.I18n.text("network.vpn_last"));
        return parts.join(" · ");
    }
    function loadProxy() {
        if (editing || !net || !net.proxy) return;
        method = net.proxy.method || "none";
        pac = net.proxy.pac || "";
        http = net.proxy.http || "";
        https = net.proxy.https || "";
        socks = net.proxy.socks || "";
        bypass = net.proxy.bypass || "";
    }
    function proxyDirty() {
        if (!net || !net.proxy) return false;
        var saved = net.proxy.method || "none";
        if (method !== saved) return true;
        if (method === "auto") return pac !== (net.proxy.pac || "") || bypass !== (net.proxy.bypass || "");
        if (method === "manual") {
            return http !== (net.proxy.http || "") || https !== (net.proxy.https || "")
                || socks !== (net.proxy.socks || "") || bypass !== (net.proxy.bypass || "");
        }
        return false;
    }
    function markProxy() { editing = proxyDirty(); }
    function utf8len(value) {
        var count = 0;
        for (var i = 0; i < value.length; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x80) count += 1;
            else if (code < 0x800) count += 2;
            else if (code >= 0xD800 && code <= 0xDBFF) { count += 4; i++; }
            else count += 3;
        }
        return count;
    }
    function clientUuid() {
        if (!bar || !bar.wifiNets) return "";
        var current = bar.wifiNets.find(function (item) { return item.inUse; });
        return current ? (current.uuid || "") : "";
    }
    function saveProxy() {
        if (!net || !net.proxy || busy || !proxyDirty()) return;
        forget();
        net.saveProxy({
            uuid: net.proxy.uuid,
            method: method,
            pac: method === "auto" ? pac : "",
            http: method === "manual" ? http : "",
            https: method === "manual" ? https : "",
            socks: method === "manual" ? socks : "",
            bypass: method === "none" ? "" : bypass
        });
    }
    function sendVpn() {
        if (!net || vpnTyped === "") return;
        var value = vpnTyped;
        vpnTyped = "";
        forget();
        net.submitVpn(value);
    }
    function startShare() {
        if (!net || busy) return;
        if (bar && bar.mirroring && (bar.mirroring.sending || bar.mirroring.receiverState === "streaming")) {
            note("hotspot", "network.hotspot_airplay");
            return;
        }
        if (ssid.indexOf("\0") >= 0 || utf8len(ssid) < 1 || utf8len(ssid) > 32) {
            note("hotspot", "network.hotspot_name_bad");
            return;
        }
        if (password.indexOf("\0") >= 0 || password.length < 8 || password.length > 63) {
            note("hotspot", "network.hotspot_password_bad");
            return;
        }
        forget();
        net.startHotspot(ssid, password, clientUuid());
        password = "";
    }
    function stopShare() {
        if (!net || busy) return;
        forget();
        net.stopHotspot();
    }

    onNetChanged: loadProxy()
    onHotspotChanged: if (!ssidTouched && hotspot && hotspot.ssid !== "") ssid = hotspot.ssid
    Connections {
        target: page.net
        function onProxyChanged() { page.loadProxy(); }
        function onVpnPromptChanged() { if (page.net && !page.net.vpnPrompt) page.vpnTyped = ""; }
        function onSettled(scope, ok) {
            if (!ok) return;
            page.notice = "";
            page.noticeAt = "";
            if (scope === "proxy") { page.editing = false; page.loadProxy(); }
        }
    }
    Component.onCompleted: loadProxy()

    component Head: Text {
        required property var ink
        width: parent ? parent.width : 0
        leftPadding: 4
        wrapMode: Text.WordWrap
        color: ink.text2
        font.family: ink.fam
        font.pixelSize: 12
        font.weight: Font.DemiBold
    }
    component Card: Rectangle {
        id: card
        required property var ink
        default property alias content: body.data
        width: parent ? parent.width : 0
        height: body.implicitHeight
        radius: 10
        color: ink.card
        border.width: 1
        border.color: ink.cardBorder
        Column { id: body; width: parent.width }
    }
    component Line: Item {
        id: line
        required property var ink
        property string title: ""
        property string subtitle: ""
        property bool ownSplit: true
        default property alias control: slot.data
        width: parent ? parent.width : 0
        height: Math.max(44, textCol.height + 22, slot.height + 20)
        Rectangle {
            visible: line.ownSplit && line.y > 0.5
            x: 14; width: parent.width - 14; height: 1
            color: line.ink.sep
        }
        Column {
            id: textCol
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, line.width - x - slot.width - 28)
            spacing: 2
            Text {
                width: parent.width
                text: line.title
                elide: Text.ElideRight
                color: line.ink.text
                font.family: line.ink.fam
                font.pixelSize: 13
            }
            Text {
                visible: line.subtitle !== ""
                width: parent.width
                text: line.subtitle
                wrapMode: Text.WordWrap
                color: line.ink.text2
                font.family: line.ink.fam
                font.pixelSize: 12
            }
        }
        Item {
            id: slot
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }
    component Push: Rectangle {
        id: b
        required property var ink
        property string label: ""
        property bool danger: false
        signal clicked()
        width: lbl.implicitWidth + 26
        height: 24
        radius: 6
        opacity: enabled ? 1 : 0.45
        color: ma.pressed ? ink.buttonPressed : ink.button
        border.width: 1
        border.color: ink.buttonBorder
        Text {
            id: lbl
            anchors.centerIn: parent
            text: b.label
            color: b.danger ? b.ink.danger : b.ink.text
            font.family: b.ink.fam
            font.pixelSize: 13
        }
        MouseArea { id: ma; anchors.fill: parent; enabled: b.enabled; onClicked: b.clicked() }
    }
    component Entry: Rectangle {
        id: box
        required property var ink
        property string value: ""
        property string hint: ""
        property bool secret: false
        signal edited(string value)
        signal accepted()
        width: 220
        height: 26
        radius: 6
        color: ink.field
        border.width: 1
        border.color: ink.cardBorder
        Text {
            visible: input.text === "" && box.hint !== ""
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            text: box.hint
            color: box.ink.text3
            font.family: box.ink.fam
            font.pixelSize: 12
        }
        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            selectByMouse: true
            color: box.ink.text
            selectionColor: box.ink.accent
            font.family: box.ink.fam
            font.pixelSize: 12
            echoMode: box.secret ? TextInput.Password : TextInput.Normal
            onTextEdited: box.edited(text)
            onAccepted: box.accepted()
        }
        Component.onCompleted: input.text = box.value
        onValueChanged: if (input && input.text !== box.value) input.text = box.value
    }
    component Knob: Item {
        id: knob
        required property var ink
        property bool checked: false
        property bool enabled: true
        signal toggled(bool value)
        width: 38
        height: 22
        opacity: enabled ? 1 : 0.45
        Rectangle { anchors.fill: parent; radius: 11; color: knob.checked ? knob.ink.accent : knob.ink.switchOff }
        Rectangle {
            x: knob.checked ? 18 : 2; y: 2; width: 18; height: 18; radius: 9; color: "white"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.10)
        }
        MouseArea { anchors.fill: parent; enabled: knob.enabled; onClicked: knob.toggled(!knob.checked) }
    }

    Head { objectName: "setting-vpn"; ink: page.t; text: Language.I18n.text("network.vpn"); topPadding: 0 }
    Card {
        ink: page.t
        Line {
            ink: page.t
            ownSplit: false
            title: Language.I18n.text("network.vpn")
            subtitle: page.vpn && page.vpn.available ? page.vpn.name : Language.I18n.text("network.vpn_none")
            Knob {
                ink: page.t
                enabled: page.vpn && page.vpn.available && !page.busy
                checked: !!(page.vpn && page.vpn.on)
                onToggled: value => { if (page.net) page.net.toggleVpn(value); }
            }
        }
        Repeater {
            model: page.ownLinks
            delegate: Item {
                id: own
                required property var modelData
                width: parent.width
                height: ownRow.height
                Rectangle { visible: own.y > 0.5; x: 14; width: parent.width - 14; height: 1; color: page.t.sep }
                Line {
                    id: ownRow
                    ownSplit: false
                    width: parent.width
                    ink: page.t
                    title: own.modelData.name
                    subtitle: page.linkStatus(own.modelData)
                    Row {
                        spacing: 8
                        Push {
                            ink: page.t
                            enabled: !page.busy
                            label: own.modelData.active ? Language.I18n.text("network.vpn_disconnect") : Language.I18n.text("network.vpn_connect")
                            onClicked: { page.confirm = ""; page.forget(); page.net.linkToggle(own.modelData); }
                        }
                        Push {
                            ink: page.t
                            visible: own.modelData.removable
                            danger: page.confirm === own.modelData.uuid
                            enabled: !page.busy
                            label: page.confirm === own.modelData.uuid ? Language.I18n.text("network.vpn_delete_confirm") : Language.I18n.text("network.vpn_delete")
                            onClicked: {
                                if (page.confirm !== own.modelData.uuid) page.confirm = own.modelData.uuid;
                                else { page.confirm = ""; page.forget(); page.net.linkDelete(own.modelData); }
                            }
                        }
                    }
                }
            }
        }
        Line {
            ink: page.t
            visible: page.net && page.net.vpnPrompt
            title: Language.I18n.text("network.vpn_password")
            Row {
                spacing: 8
                Entry {
                    ink: page.t
                    width: 180
                    value: page.vpnTyped
                    secret: true
                    onEdited: value => page.vpnTyped = value
                    onAccepted: page.sendVpn()
                }
                Push { ink: page.t; label: Language.I18n.text("network.vpn_connect"); onClicked: page.sendVpn() }
                Push { ink: page.t; label: Language.I18n.text("common.cancel"); onClicked: if (page.net) page.net.cancelVpn() }
            }
        }
        Line {
            ink: page.t
            title: page.ownLinks.length === 0 ? Language.I18n.text("network.vpn_empty") : Language.I18n.text("network.vpn_import")
            subtitle: Language.I18n.text("network.vpn_formats")
            Push {
                ink: page.t
                enabled: !page.busy
                label: page.ownLinks.length === 0 ? Language.I18n.text("network.vpn_import") : Language.I18n.text("network.vpn_choose")
                onClicked: importer.open()
            }
        }
        Text {
            visible: page.sectionError("vpn") !== ""
            width: parent.width
            leftPadding: 14; rightPadding: 14; topPadding: 4; bottomPadding: 12
            wrapMode: Text.WordWrap
            color: page.t.danger
            font.family: page.t.fam
            font.pixelSize: 12
            text: page.sectionError("vpn")
        }
    }

    Head { ink: page.t; text: Language.I18n.text("network.vpn_other"); topPadding: 8; visible: page.otherLinks.length > 0 }
    Card {
        ink: page.t
        visible: page.otherLinks.length > 0
        Repeater {
            model: page.otherLinks
            delegate: Item {
                id: other
                required property var modelData
                width: parent.width
                height: otherRow.height
                Rectangle { visible: other.y > 0.5; x: 14; width: parent.width - 14; height: 1; color: page.t.sep }
                Line {
                    id: otherRow
                    ownSplit: false
                    width: parent.width
                    ink: page.t
                    title: other.modelData.name
                    subtitle: page.linkStatus(other.modelData)
                }
            }
        }
    }

    Head { objectName: "setting-proxy"; ink: page.t; text: Language.I18n.text("network.proxy"); topPadding: 8 }
    Card {
        ink: page.t
        Line {
            ink: page.t
            ownSplit: false
            title: page.net && page.net.proxy ? page.net.proxy.name : Language.I18n.text("network.proxy")
            subtitle: page.net && page.net.proxy ? Language.I18n.text("network.proxy_note") : Language.I18n.text("network.proxy_missing")
        }
        Item {
            visible: page.net && page.net.proxy
            width: parent.width
            height: visible ? 44 : 0
            Rectangle { x: 14; width: parent.width - 14; height: 1; color: page.t.sep }
            SegmentedControl {
                x: 14
                anchors.verticalCenter: parent.verticalCenter
                enabled: page.net && page.net.proxy && !page.busy
                opacity: enabled ? 1 : 0.45
                t: page.t
                segWidth: 96
                model: [Language.I18n.text("network.proxy_none"), Language.I18n.text("network.proxy_auto"), Language.I18n.text("network.proxy_manual")]
                current: page.method === "auto" ? 1 : (page.method === "manual" ? 2 : 0)
                onPicked: index => {
                    var next = ["none", "auto", "manual"][index];
                    if (next === page.method) return;
                    page.method = next;
                    page.markProxy();
                }
            }
        }
        Line {
            ink: page.t
            visible: page.method === "auto" && page.net && page.net.proxy
            title: Language.I18n.text("network.proxy_pac")
            Entry { ink: page.t; width: 260; enabled: !page.busy; value: page.pac; onEdited: value => { page.pac = value; page.markProxy(); } }
        }
        Line {
            ink: page.t
            visible: page.method === "manual" && page.net && page.net.proxy
            title: Language.I18n.text("network.proxy_http")
            Entry { ink: page.t; width: 220; enabled: !page.busy; value: page.http; onEdited: value => { page.http = value; page.markProxy(); } }
        }
        Line {
            ink: page.t
            visible: page.method === "manual" && page.net && page.net.proxy
            title: Language.I18n.text("network.proxy_https")
            Entry { ink: page.t; width: 220; enabled: !page.busy; value: page.https; onEdited: value => { page.https = value; page.markProxy(); } }
        }
        Line {
            ink: page.t
            visible: page.method === "manual" && page.net && page.net.proxy
            title: Language.I18n.text("network.proxy_socks")
            Entry { ink: page.t; width: 220; enabled: !page.busy; value: page.socks; onEdited: value => { page.socks = value; page.markProxy(); } }
        }
        Line {
            ink: page.t
            visible: page.method !== "none" && page.net && page.net.proxy
            title: Language.I18n.text("network.proxy_bypass")
            Entry { ink: page.t; width: 260; enabled: !page.busy; value: page.bypass; onEdited: value => { page.bypass = value; page.markProxy(); } }
        }
        Line {
            ink: page.t
            visible: page.proxyDirty()
            title: page.method === "auto" ? Language.I18n.text("network.proxy_auto") : (page.method === "manual" ? Language.I18n.text("network.proxy_manual") : Language.I18n.text("network.proxy_none"))
            Push { ink: page.t; enabled: !page.busy; label: Language.I18n.text("network.save"); onClicked: page.saveProxy() }
        }
        Text {
            visible: page.sectionError("proxy") !== ""
            width: parent.width
            leftPadding: 14; rightPadding: 14; topPadding: 4; bottomPadding: 12
            wrapMode: Text.WordWrap
            color: page.t.danger
            font.family: page.t.fam
            font.pixelSize: 12
            text: page.sectionError("proxy")
        }
    }

    Head { objectName: "setting-hotspot"; ink: page.t; text: Language.I18n.text("network.hotspot"); topPadding: 8; visible: page.hotspot }
    Card {
        ink: page.t
        visible: page.hotspot
        Line {
            ink: page.t
            ownSplit: false
            visible: page.hotspot && !page.hotspot.available
            title: Language.I18n.text("network.hotspot")
            subtitle: Language.I18n.text("network.hotspot_unavailable")
        }
        Line {
            ink: page.t
            ownSplit: false
            visible: page.hotspot && page.hotspot.active
            title: page.hotspot ? page.hotspot.ssid : ""
            subtitle: !page.hotspot ? "" : ((page.hotspot.address || "") + (!page.hotspot.upstream ? (page.hotspot.address ? " · " : "") + Language.I18n.text("network.hotspot_no_upstream") : ""))
            Push { ink: page.t; enabled: !page.busy; label: Language.I18n.text("network.hotspot_stop"); onClicked: page.stopShare() }
        }
        Line {
            ink: page.t
            ownSplit: false
            visible: page.hotspot && page.hotspot.available && !page.hotspot.active
            title: Language.I18n.text("network.hotspot_ssid")
            Entry { ink: page.t; enabled: !page.busy; value: page.ssid; onEdited: value => { page.ssidTouched = true; page.ssid = value; } }
        }
        Line {
            ink: page.t
            visible: page.hotspot && page.hotspot.available && !page.hotspot.active
            title: Language.I18n.text("network.hotspot_password")
            subtitle: Language.I18n.text("network.hotspot_rule")
            Row {
                spacing: 8
                Entry {
                    ink: page.t
                    enabled: !page.busy
                    value: page.password
                    secret: !page.showPassword
                    onEdited: value => page.password = value
                    onAccepted: page.startShare()
                }
                Push {
                    ink: page.t
                    label: page.showPassword ? Language.I18n.text("network.hotspot_hide") : Language.I18n.text("network.hotspot_show")
                    onClicked: page.showPassword = !page.showPassword
                }
            }
        }
        Line {
            ink: page.t
            visible: page.hotspot && page.hotspot.available && !page.hotspot.active
            title: page.net && page.net.ssid !== "" ? page.net.ssid : "Wi-Fi"
            subtitle: Language.I18n.text("network.hotspot_note")
            Push { ink: page.t; enabled: !page.busy; label: Language.I18n.text("network.hotspot_start"); onClicked: page.startShare() }
        }
        Text {
            visible: page.sectionError("hotspot") !== ""
            width: parent.width
            leftPadding: 14; rightPadding: 14; topPadding: 4; bottomPadding: 12
            wrapMode: Text.WordWrap
            color: page.t.danger
            font.family: page.t.fam
            font.pixelSize: 12
            text: page.sectionError("hotspot")
        }
    }

    FileDialog {
        id: importer
        title: Language.I18n.text("network.vpn_import")
        fileMode: FileDialog.OpenFile
        nameFilters: ["VPN (*.ovpn *.conf)"]
        onAccepted: {
            var path = QuickLook.localPath(selectedFile);
            if (path && page.net) { page.forget(); page.net.importProfile(path); }
        }
    }
}
