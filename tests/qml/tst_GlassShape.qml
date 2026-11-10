import QtQuick
import QtTest
import "../../MacShell/GlassShape.js" as GS

TestCase {
    name: "GlassShape"

    function kinds(cmds) {
        var out = [];
        for (var i = 0; i < cmds.length; i++)
            out.push(cmds[i][0]);
        return out.join("");
    }

    function test_body_without_tail() {
        var a = GS.cmds(2, 3, 180, 28, 12, 90, 0, 0, 3);
        compare(a[0][0], "M");
        compare(a[a.length - 1][0], "Z");
        verify(kinds(a).indexOf("Q") < 0);
        var path = GS.svg(2, 3, 180, 28, 12, 90, 0, 0, 3);
        verify(path.indexOf("M") === 0);
        verify(path.indexOf("Z") >= 0);
    }

    function test_tail_adds_quadratic_wedge() {
        var a = GS.cmds(0, 0, 200, 30, 14, 100, 24, 9, 3.6);
        verify(kinds(a).indexOf("Q") >= 0);
        compare(a[a.length - 1][0], "Z");
        var path = GS.svg(0, 0, 200, 30, 14, 100, 24, 9, 3.6);
        verify(path.indexOf("Q") >= 0);
    }

    function test_tail_clamps_away_from_corners() {
        var left = GS.cmds(0, 0, 160, 28, 12, 0, 24, 9, 3);
        var right = GS.cmds(0, 0, 160, 28, 12, 160, 24, 9, 3);
        var mid = GS.cmds(0, 0, 160, 28, 12, 80, 24, 9, 3);
        function firstTailX(cmds) {
            for (var i = 0; i < cmds.length; i++) {
                if (cmds[i][0] === "Q")
                    return cmds[i][1];
            }
            return -1;
        }
        verify(firstTailX(left) > 8);
        verify(firstTailX(right) < 160 - 8);
        compare(Math.round(firstTailX(mid)), Math.round(firstTailX(GS.cmds(0, 0, 160, 28, 12, 80, 24, 9, 3))));
    }
}
