import QtQuick
import QtTest
import "../../MacShell/CursorGrow.js" as Grow

TestCase {
    name: "CursorGrow"

    function feed(points) {
        var state = []
        var spun = false
        for (var i = 0; i < points.length; i++) {
            var step = Grow.sample(state, points[i].t, points[i].x, points[i].y)
            state = step.samples
            if (step.spin) spun = true
        }
        return spun
    }

    function circle(count, radius, duration) {
        var points = []
        for (var i = 0; i <= count; i++) {
            var angle = -Math.PI / 2 + (i / count) * Math.PI * 2
            points.push({
                t: Math.round(i * duration / count),
                x: 400 + Math.cos(angle) * radius,
                y: 400 + Math.sin(angle) * radius
            })
        }
        return points
    }

    function test_a_fast_circle_grows_the_cursor() {
        verify(feed(circle(24, 80, 360)))
    }

    function test_a_straight_line_does_not_grow() {
        var points = []
        for (var i = 0; i < 20; i++) points.push({ t: i * 16, x: i * 30, y: 10 })
        verify(!feed(points))
    }

    function test_shaking_side_to_side_does_not_grow() {
        var points = []
        for (var i = 0; i < 20; i++) points.push({ t: i * 16, x: (i % 2) * 140, y: 20 })
        verify(!feed(points))
    }

    function test_a_slow_circle_does_not_grow() {
        verify(!feed(circle(48, 80, 2200)))
    }

    function test_a_tiny_circle_does_not_grow() {
        verify(!feed(circle(20, 10, 280)))
    }
}
