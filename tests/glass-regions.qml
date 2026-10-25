import QtQuick
import Quickshell
import "../MacShell" as Port

ShellRoot {
    QtObject {
        id: regionHost
        property Item contentItem: scene
        property var glassSurfaces: []
        property bool visible: true
        property int commits: 0
        property int clearCommits: 0
    }
    Port.GlassRegion {
        id: aggregate
        host: regionHost
        renderWindow: QtObject {
            id: frame
            property bool autoSwap: true
            signal frameSwapped()
            function update() {
                regionHost.commits++;
                if (aggregate.clearFrames > 0) regionHost.clearCommits++;
                if (autoSwap) Qt.callLater(frame.frameSwapped);
            }
        }
    }
    Item {
        id: scene
        width: 1000; height: 800
        Item {
            id: panel
            x: 500; y: 100; width: 400; height: 300
            scale: 1.25; transformOrigin: Item.TopRight
            transform: Translate { id: slide }
            Port.GlassFallback { id: glass; host: regionHost; x: 20; y: 60; width: 100; height: 66; radius: 20 }
        }
    }
    function check(condition, message) { if (!condition) throw new Error(message); }
    Timer {
        interval: 50; running: true; repeat: true
        property int step: 0
        onTriggered: {
            try {
                if (step === 1) {
                    check(glass.blurRegion.x === 465 && glass.blurRegion.y === 191, "Ancestor animation must move the native region");
                    regionHost.commits = 0;
                    regionHost.clearCommits = 0;
                    panel.opacity = 0; step++; return;
                }
                if (step === 2) {
                    check(!glass.blurActive, "Fully transparent glass must not leave blur behind");
                    check(aggregate.regions.length === 0, "Last closed surface must clear the aggregate region");
                    check(regionHost.commits > 0, "Clearing the last region must submit a final frame even without visible changes");
                    check(regionHost.clearCommits >= 2, "The clipped empty effect must be submitted before removal");
                    check(aggregate.clearFrames === 0 && aggregate.width === 0 && aggregate.height === 0, "The temporary clear region must be removed after the submitted frames");
                    panel.opacity = 1; panel.visible = false; step++; return;
                }
                if (step === 3) {
                    check(!glass.blurActive, "Hidden ancestors must release blur");
                    panel.visible = true; glass.blurEnabled = false; step++; return;
                }
                if (step === 4) {
                    check(!glass.blurActive, "Disabling effects must release blur");
                    glass.blurEnabled = true; glass.blurAmount = 0; step++; return;
                }
                if (step === 5) {
                    check(!glass.blurActive, "Zero blur strength must release the native region");
                    regionHost.commits = 0;
                    glass.blurAmount = 80; step++; return;
                }
                if (step === 6) {
                    check(glass.blurActive, "Positive blur strength must restore the native region");
                    check(aggregate.regions.length === 1 && regionHost.commits > 0, "Reopening glass must submit the region again");
                    regionHost.commits = 0; step++; return;
                }
                if (step === 7) {
                    check(regionHost.commits === 0, "Idle glass must not request continuous frames");
                    frame.autoSwap = false; glass.blurAmount = 0; step++; return;
                }
                if (step === 8) {
                    check(aggregate.clearFrames === 2 && aggregate.width === 1, "Clear must wait for submitted frames, not a timer");
                    glass.blurAmount = 80; step++; return;
                }
                if (step === 9) {
                    check(aggregate.regions.length === 1 && aggregate.clearFrames === 0 && aggregate.width === 0, "Reopening must cancel pending clear immediately");
                    frame.frameSwapped(); frame.autoSwap = true; step++; return;
                }
                if (step === 10) {
                    check(aggregate.regions.length === 1 && glass.blurActive, "A late frame callback must not erase reopened glass");
                    console.log("MACSHELL_GLASS_REGIONS_PASS"); Qt.exit(0); return;
                }
                check(regionHost.glassSurfaces.length === 1, "Glass must register once");
                check(glass.blurActive, "Visible glass must have native blur");
                check(aggregate.regions.length === 1 && regionHost.commits > 0, "Visible glass must commit its native region");
                check(glass.blurRegion.x === 425 && glass.blurRegion.y === 175, "Blur must follow the scaled top-right pivot");
                check(glass.blurRegion.width === 125 && glass.blurRegion.height === 83, "Region must enclose fractional bounds");
                check(glass.blurRegion.radius === 25, "Corner radius must scale with the surface");
                panel.x += 40; slide.y = 16;
                step++;
            } catch (error) { console.error(error); Qt.exit(1); }
        }
    }
}
