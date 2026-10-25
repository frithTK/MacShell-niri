import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test; name: "MarqueeActivity"; when: windowShown
    width: 220; height: 60; visible: true
    Component {
        id: marqueeComponent
        Port.MarqueeText { width: 100; text: "A long artist and album name that needs smooth scrolling"; speed: 150 }
    }
    function test_hidden_mirror_pauses_and_resumes_without_resetting_the_visible_frame() {
        var marquee = createTemporaryObject(marqueeComponent, test);
        verify(marquee.overflow);
        tryVerify(() => marquee.scrollX < -5, 4000);
        var motion = findChild(marquee, "marqueeMotion");
        verify(motion.running); verify(!motion.paused);
        marquee.animationsEnabled = false;
        tryVerify(() => motion.paused);
        var frozen = marquee.scrollX;
        wait(200);
        compare(marquee.scrollX, frozen);
        verify(motion.running);
        marquee.animationsEnabled = true;
        tryVerify(() => !motion.paused && marquee.scrollX < frozen - 1, 500);
    }
    function test_paused_content_still_receives_track_changes_and_short_text_stays_still() {
        var marquee = createTemporaryObject(marqueeComponent, test, {animationsEnabled: false});
        var motion = findChild(marquee, "marqueeMotion");
        tryVerify(() => motion.paused);
        marquee.text = "Next artist and album are immediately available for the first frame";
        compare(marquee.text, "Next artist and album are immediately available for the first frame");
        marquee.text = "Short";
        tryVerify(() => !motion.running);
        compare(marquee.scrollX, 0);
    }
}
