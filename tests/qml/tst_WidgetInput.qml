import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test; name: "WidgetInput"; when: windowShown
    width: 900; height: 700; visible: true
    Component { id: registryComponent; Port.WidgetInputRegistry {} }
    Component { id: targetComponent; Port.WidgetInputTarget {} }
    Component { id: itemComponent; Item {} }
    Component {
        id: handleComponent
        Port.WidgetEditHandle {
            property int moves: 0
            property int selections: 0
            property int contexts: 0
            property point lastMove: Qt.point(0, 0)
            onMoveRequested: (x, y) => { moves++; lastMove = Qt.point(x, y); }
            onSelectRequested: selections++
            onContextRequested: contexts++
        }
    }
    function test_more_than_four_targets_and_different_outputs_are_independent() {
        var registry = createTemporaryObject(registryComponent, test, {outputName: "DP-1", surfaceItem: test});
        var types = ["player", "button", "notes", "timer", "battery", "player"];
        for (var i = 0; i < types.length; i++) {
            var item = createTemporaryObject(itemComponent, test, {x: i * 100, y: 30, width: 80, height: 80});
            createTemporaryObject(targetComponent, item, {registry: registry, instanceId: types[i] + i, outputName: "DP-1", sourceItem: item, targetItem: test, interactive: true});
        }
        var other = createTemporaryObject(itemComponent, test, {x: 650, y: 30, width: 80, height: 80});
        createTemporaryObject(targetComponent, other, {registry: registry, instanceId: "player0", outputName: "DP-2", sourceItem: other, targetItem: test, interactive: true});
        tryVerify(() => registry.activeTargets.length === 6);
        verify(registry.accepts(550, 60)); verify(!registry.accepts(90, 60)); verify(!registry.accepts(680, 60));
        registry.outputName = "DP-2"; compare(registry.activeTargets.length, 1); verify(registry.accepts(680, 60));
    }
    function test_visibility_transforms_interactivity_and_last_release_clear_input() {
        var registry = createTemporaryObject(registryComponent, test, {outputName: "one", surfaceItem: test});
        var ancestor = createTemporaryObject(itemComponent, test, {x: 40, y: 20});
        var source = createTemporaryObject(itemComponent, ancestor, {x: 10, y: 10, width: 100, height: 60, transformOrigin: Item.TopLeft, scale: 1.25});
        var target = createTemporaryObject(targetComponent, source, {registry: registry, instanceId: "a", outputName: "one", sourceItem: source, targetItem: test, interactive: true});
        tryVerify(() => registry.activeTargets.length === 1);
        verify(registry.accepts(174, 104)); verify(!registry.accepts(176, 104));
        ancestor.x = 80; verify(registry.accepts(210, 50));
        ancestor.visible = false; tryCompare(registry, "activeTargets", []);
        ancestor.visible = true; tryVerify(() => registry.activeTargets.length === 1);
        ancestor.opacity = 0; tryVerify(() => registry.activeTargets.length === 0);
        ancestor.opacity = 1; tryVerify(() => registry.activeTargets.length === 1);
        source.enabled = false; compare(registry.activeTargets.length, 0);
        source.enabled = true; target.interactive = false; compare(registry.activeTargets.length, 0);
        target.interactive = true; compare(registry.activeTargets.length, 1);
        target.destroy(); tryVerify(() => registry.targets.length === 0); verify(!registry.accepts(120, 50));
    }
    function test_replacement_and_edit_full_surface_have_no_stale_registration() {
        var registry = createTemporaryObject(registryComponent, test, {outputName: "one", surfaceItem: test});
        var first = createTemporaryObject(itemComponent, test, {x: 0, y: 0, width: 80, height: 80});
        var second = createTemporaryObject(itemComponent, test, {x: 200, y: 0, width: 80, height: 80});
        var old = createTemporaryObject(targetComponent, first, {registry: registry, instanceId: "same", outputName: "one", sourceItem: first, targetItem: test, interactive: true});
        var newer = createTemporaryObject(targetComponent, second, {registry: registry, instanceId: "same", outputName: "one", sourceItem: second, targetItem: test, interactive: true});
        tryVerify(() => registry.activeTargets.length === 1);
        verify(!registry.accepts(40, 40)); verify(registry.accepts(240, 40));
        old.destroy(); tryVerify(() => registry.targets.length === 1); verify(registry.accepts(240, 40));
        registry.editing = true; compare(registry.activeTargets.length, 0); verify(registry.accepts(850, 650)); verify(!registry.accepts(920, 650));
        registry.blocked = true; verify(!registry.accepts(240, 40));
        registry.blocked = false; registry.editing = false; newer.destroy(); tryVerify(() => registry.activeTargets.length === 0);
    }
    function test_click_right_click_drag_and_cancel_are_distinct() {
        var card = createTemporaryObject(itemComponent, test, {x: 60, y: 100, width: 150, height: 120});
        var handle = createTemporaryObject(handleComponent, card, {width: 150, height: 120, targetItem: card, coordinateItem: test});
        card.x = Qt.binding(() => 60 + handle.offsetX); card.y = Qt.binding(() => 100 + handle.offsetY);
        waitForRendering(card);
        mouseClick(handle, 75, 60); compare(handle.selections, 1); compare(handle.moves, 0);
        mouseClick(handle, 75, 60, Qt.RightButton); compare(handle.contexts, 1); compare(handle.moves, 0);
        mousePress(handle, 75, 60); mouseMove(test, 370, 280, 50); mouseRelease(test, 370, 280);
        compare(handle.moves, 1); verify(handle.lastMove.x > 200); compare(handle.offsetX, 0); compare(handle.selections, 1);
        mousePress(handle, 75, 60); mouseMove(test, 400, 300, 50); handle.enabled = false;
        mouseRelease(test, 400, 300); compare(handle.moves, 1); compare(handle.offsetX, 0); compare(handle.offsetY, 0);
    }
    function test_repeated_mount_transfer_and_unmount_release_the_exact_owner() {
        var first = createTemporaryObject(registryComponent, test, {outputName: "one", surfaceItem: test});
        var second = createTemporaryObject(registryComponent, test, {outputName: "one", surfaceItem: test});
        for (var i = 0; i < 20; i++) {
            var source = createTemporaryObject(itemComponent, test, {x: 40, y: 40, width: 80, height: 80});
            var target = createTemporaryObject(targetComponent, source, {registry: first, instanceId: "card", outputName: "one", sourceItem: source, targetItem: test, interactive: true});
            first.acquire(target); compare(first.targets.length, 1);
            target.registry = second; compare(first.targets.length, 0); compare(second.targets.length, 1);
            source.destroy(); tryVerify(() => second.targets.length === 0);
        }
    }
}
