import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "ClockSounds"; when: windowShown
    width: 600; height: 500; visible: true
    Component {
        id: clientComponent
        QtObject {
            property bool ready: true
            property bool busy: false
            property var allSounds: [{id: "builtin-chime-01", name: "Chime 1", category: "chime"},
                                     {id: "user-example", name: "My recording"},
                                     {id: "user-packaged", name: "Radar", category: "apple", imported: false}]
            property var sounds: allSounds
            property string soundError: ""
            property string previewId: ""
            property bool showBuiltins: true
            property int refreshed: 0
            property string deleted: ""
            property string renamed: ""
            function refreshSounds() { refreshed++; }
            function setBuiltinsVisible(value) {
                showBuiltins = value;
                sounds = value ? allSounds : allSounds.filter(sound => !sound.id.startsWith("builtin-"));
            }
            function previewSound(id) { previewId = id; }
            function stopPreview() { previewId = ""; }
            function favoriteSound(id, favorite) {
                sounds = sounds.map(sound => sound.id === id ? Object.assign({}, sound, {favorite: favorite}) : sound);
            }
            function deleteSound(id) { deleted = id; }
            function renameSound(id, name) { renamed = id + ":" + name; }
        }
    }
    Component { id: importerComponent; QtObject { property string error: ""; property bool busy: false; property bool cancelled: false; property bool aacSupported: false; property int importedCount: 0; property int duplicateCount: 0; function cancel() { cancelled = true; } function probeCodecs() {} } }
    Component { id: panelComponent; Port.ClockSounds { width: 480; height: 430 } }
    function test_preview_and_search_data() { return [{tag: "dark", dark: true}, {tag: "light", dark: false}]; }
    function test_preview_and_search(data) {
        var client = createTemporaryObject(clientComponent, test);
        var importer = createTemporaryObject(importerComponent, test);
        var panel = createTemporaryObject(panelComponent, test, {client: client, importer: importer, darkMode: data.dark});
        waitForRendering(panel);
        compare(client.refreshed, 1); compare(panel.filtered.length, 3);
        var fileDialog = findChild(panel, "clockSoundFileDialog");
        verify(fileDialog.nameFilters[0].indexOf("*.aac") < 0);
        importer.aacSupported = true;
        verify(fileDialog.nameFilters[0].indexOf("*.aac") >= 0);
        var search = findChild(panel, "clockSoundSearch");
        search.text = "My recording"; tryCompare(panel, "filtered", [client.sounds[1]]);
        var play = findChild(panel, "clockSoundPreview"); verify(play !== null);
        mouseClick(play); compare(client.previewId, "user-example");
        mouseClick(play); compare(client.previewId, "");
        mouseClick(findChild(panel, "clockSoundFavorite")); verify(client.sounds[1].favorite);
        search.text = "";
        var filter = findChild(panel, "clockSoundFilter"); filter.currentIndex = 1;
        compare(panel.filtered.length, 1); compare(panel.filtered[0].id, "user-example");
        mouseClick(findChild(panel, "clockSoundRename"));
        var renameDialog = findChild(panel, "clockSoundRenameDialog"); tryCompare(renameDialog, "visible", true);
        findChild(panel, "clockSoundRenameInput").text = "New name";
        mouseClick(findChild(panel, "clockSoundConfirmRename")); compare(client.renamed, "user-example:New name");
        tryCompare(renameDialog, "visible", false); waitForRendering(panel);
        mouseClick(findChild(panel, "clockSoundDelete"));
        var confirmation = findChild(panel, "clockSoundDeleteConfirmation");
        tryCompare(confirmation, "visible", true);
        mouseClick(findChild(panel, "clockSoundConfirmDelete"));
        compare(client.deleted, "user-example");
        tryCompare(confirmation, "visible", false); waitForRendering(panel);
        filter.currentIndex = 0; search.text = "Radar";
        tryCompare(panel, "filtered", [client.sounds[2]]); waitForRendering(panel);
        verify(!findChild(panel, "clockSoundDelete").visible);
        verify(!findChild(panel, "clockSoundRename").visible);
        search.text = "";
        filter.currentIndex = 0;
        mouseClick(findChild(panel, "clockSoundBuiltinVisibility"));
        compare(client.showBuiltins, false); compare(panel.filtered.length, 2);
        mouseClick(findChild(panel, "clockSoundBuiltinVisibility"));
        compare(client.showBuiltins, true); compare(panel.filtered.length, 3);
        importer.busy = true; compare(findChild(panel, "clockSoundImport").enabled, false); waitForRendering(panel);
        mouseClick(findChild(panel, "clockSoundCancelImport")); verify(importer.cancelled);
    }
}
