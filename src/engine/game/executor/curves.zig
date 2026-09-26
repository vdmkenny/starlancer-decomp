//! A mission's curves (`mission_curves`, section `curves` of a [`.DTE`](../../../../docs/formats/dte.md)):
//! the points along each, how long a path of them is, and the curve that carries a path on. The
//! director's camera flies along them ([`director.zig`](director.zig)).
//!
//! **Unverified:** the source file. The code lies between `loadout.cpp`'s and `Executor.cpp`'s, and
//! the Executor's commands are what reach it.

const std = @import("std");

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;

const Curve = dte.Curve;

/// The point `t` of the way along `curve`, from 0 at its start to 1 at its end, and on past them
/// for a `t` past them (`curve_point`, `0x00457050`, a component at a time in `0x00457090`): its
/// ends weighed by the Hermite functions `2t³ - 3t² + 1` and `3t² - 2t³`, its leaving tangent by
/// `t³ - 2t² + t` and its arriving tangent, turned about, by `t² - t³` (`0x00457130` to
/// `0x004571B0`), each tangent `tangent_scale` times as long as the record has it.
pub fn point(curve: Curve, t: f32) Vector {
    const t2 = t * t;
    const t3 = t2 * t;
    const leaving: Vector = @as(Vector, curve.leaving) * @as(Vector, @splat(tangent_scale));
    const arriving: Vector = @as(Vector, curve.arriving) * @as(Vector, @splat(-tangent_scale));
    return @as(Vector, curve.to) * @as(Vector, @splat(3 * t2 - 2 * t3)) +
        @as(Vector, curve.from) * @as(Vector, @splat(2 * t3 - 3 * t2 + 1)) +
        arriving * @as(Vector, @splat(t3 - t2)) +
        leaving * @as(Vector, @splat(t3 - 2 * t2 + t));
}

/// How many times longer a curve's tangents weigh than the record has them (`0x00457090`).
pub const tangent_scale: f32 = 10;

/// How long `curve` is (`curve_length`, `0x00457250`): the sum of the chords between its points at
/// each `steps`th of the way (`0x00457260`).
///
/// The game takes the points from a table of the four weights at each 32nd of the way
/// (`curve_weights`, `0x00529FC0`), which `mission_script_start` fills (`0x00456F00`), through
/// `0x00456F70`; OpenReliant computes them, as the table holds them at those points.
pub fn length(curve: Curve) f32 {
    var sum: f32 = 0;
    var before = point(curve, 0);
    for (1..steps + 1) |n| {
        const at = point(curve, @as(f32, @floatFromInt(n)) / steps);
        sum += math.distance(at, before);
        before = at;
    }
    return sum;
}

/// The steps a curve is measured by (`0x004DC724`, and a 32nd, `0x004DC478`).
pub const steps = 32;

/// `curve_starting_at` (`0x004571D0`): the first of `curves` that starts at ship `ship`, or null
/// for none.
pub fn starting(curves: []align(1) const Curve, ship: u16) ?usize {
    for (curves, 0..) |curve, n| {
        if (curve.start.index == ship) return n;
    }
    return null;
}

/// `curve_next` (`0x00457200`): the curve that carries a path on from ship `at`, other than
/// `curves[from]`: the first that starts there, or, unless `starting_only`, that ends there. Null
/// for none.
pub fn next(curves: []align(1) const Curve, from: usize, at: u16, starting_only: bool) ?usize {
    for (curves, 0..) |curve, n| {
        if (n == from) continue;
        if (curve.start.index == at) return n;
        if (curve.end.index == at and !starting_only) return n;
    }
    return null;
}

/// `curve_path_length` (`0x00457320`): how long the path from `curves[first]` is: that curve, and
/// each that carries it on from where the last ends (`next`), to one that ends at no ship.
///
/// **Fix:** the game follows a path that comes round to a curve it has taken for ever; OpenReliant
/// stops once it has taken as many curves as the mission has.
pub fn pathLength(curves: []align(1) const Curve, first: usize) f32 {
    var sum: f32 = 0;
    var at: ?usize = first;
    var taken: usize = 0;
    while (at) |n| : (taken += 1) {
        if (n >= curves.len or taken >= curves.len) break;
        const curve = curves[n];
        sum += length(curve);
        const end = curve.endShip() orelse break;
        at = next(curves, n, end, false);
    }
    return sum;
}

/// `curve_ride` (`0x004574A0`): `on`, a point of a path that rides along with a ship, carried with
/// it: by how far `start` lies from `placed`, where the mission placed the ship, and, where `now`
/// is given, by how far the ship has come from `start` to `now`.
pub fn ride(on: Vector, placed: Vector, start: Vector, now: ?Vector) Vector {
    var carried = on;
    if (now) |at| carried += at - start;
    return carried + (start - placed);
}

/// A curve's next marker, as `nextMarker` finds it: the share of the way to it, 0 for none, and the
/// point the camera passes at the share it was asked from, where there is one.
pub const Marker = struct { at: f32, passed: ?u16 };

/// `curve_next_marker` (`0x00457510`): the nearest place on curve `curve` past `after` that one of
/// the mission's points marks (`dte.Ship.markedCurve`), and the last of the points that mark
/// `after` itself.
pub fn nextMarker(ships: []align(1) const dte.Ship, curve: u16, after: f32) Marker {
    var found: Marker = .{ .at = 0, .passed = null };
    for (ships, 0..) |ship, n| {
        if (ship.markedCurve() != curve) continue;
        if (ship.marker_at > after) {
            if (found.at == 0 or found.at > ship.marker_at) found.at = ship.marker_at;
        } else if (ship.marker_at == after) {
            found.passed = @intCast(n);
        }
    }
    return found;
}

/// A curve for the tests, from ship `start` at `from` to ship `end` at `to`, with no tangents.
pub fn testCurve(start: u16, end: u16, from: [3]f32, to: [3]f32) Curve {
    var curve = std.mem.zeroes(Curve);
    curve.start = .{ .index = start, .tag = .ship, ._unknown_24 = 0xFF };
    curve.end = .{ .index = end, .tag = .ship, ._unknown_24 = 0xFF };
    curve.from = from;
    curve.to = to;
    return curve;
}

test "a curve runs from its start to its end, bowed by its tangents" {
    var curve = testCurve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 1000 });
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, point(curve, 0));
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, point(curve, 1));
    // Without tangents, a straight line, eased at the ends: half way at the middle.
    try std.testing.expectEqual(Vector{ 0, 0, 500 }, point(curve, 0.5));
    try std.testing.expectApproxEqAbs(1000, length(curve), 1e-2);
    // Heading out to the side as it leaves and back as it arrives, the middle bows that way, by
    // the tangents' weight; heading out the same way at both ends, it swings through the middle.
    curve.leaving = .{ 100, 0, 0 };
    curve.arriving = .{ 100, 0, 0 };
    try std.testing.expectApproxEqAbs(250, point(curve, 0.5)[0], 1e-3);
    curve.arriving = .{ -100, 0, 0 };
    try std.testing.expectApproxEqAbs(0, point(curve, 0.5)[0], 1e-3);
    try std.testing.expect(point(curve, 0.25)[0] > 0 and point(curve, 0.75)[0] < 0);
    // Past its end the cubic runs on, turning back the way it came.
    try std.testing.expect(point(curve, 1.1)[2] < 1000);
}

test "a path runs on through the curves that carry it" {
    const curves = [_]Curve{
        testCurve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        testCurve(1, 2, .{ 0, 0, 1000 }, .{ 0, 0, 3000 }),
        testCurve(2, dte.Reference.unset, .{ 0, 0, 3000 }, .{ 0, 0, 3000 }),
    };
    try std.testing.expectEqual(1, starting(&curves, 1));
    try std.testing.expectEqual(null, starting(&curves, 7));
    try std.testing.expectEqual(1, next(&curves, 0, 1, true));
    // A curve that ends there carries it on too, unless only one that starts there may.
    try std.testing.expectEqual(0, next(&curves, 1, 1, false));
    try std.testing.expectEqual(null, next(&curves, 1, 1, true));
    try std.testing.expectEqual(null, next(&curves, 0, 7, false));
    try std.testing.expectApproxEqAbs(3000, pathLength(&curves, 0), 1e-1);
    // A path that comes round on itself ends once it has taken every curve.
    const round = [_]Curve{ testCurve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 10 }), testCurve(1, 0, .{ 0, 0, 10 }, .{ 0, 0, 0 }) };
    try std.testing.expectApproxEqAbs(20, pathLength(&round, 0), 1e-3);
}

test ride {
    // A ship placed at 100 that stood at 150 as the path began, and stands at 200 now: the point
    // rides along by 100, or by 50 without its move since.
    try std.testing.expectEqual(Vector{ 100, 0, 0 }, ride(@splat(0), .{ 100, 0, 0 }, .{ 150, 0, 0 }, .{ 200, 0, 0 }));
    try std.testing.expectEqual(Vector{ 50, 0, 0 }, ride(@splat(0), .{ 100, 0, 0 }, .{ 150, 0, 0 }, null));
}

test nextMarker {
    var ships: [4]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    for (ships[0..3], [_]f32{ 0.25, 0.75, 0.5 }) |*ship, at| {
        ship.kind = dte.Ship.point_kind;
        ship.marker_curve = 4;
        ship.marker_at = at;
    }
    // A ship of another kind marks nothing.
    ships[3].marker_curve = 4;
    ships[3].marker_at = 0.3;
    try std.testing.expectEqual(Marker{ .at = 0.25, .passed = null }, nextMarker(&ships, 4, 0));
    try std.testing.expectEqual(Marker{ .at = 0.75, .passed = 2 }, nextMarker(&ships, 4, 0.5));
    try std.testing.expectEqual(Marker{ .at = 0, .passed = 1 }, nextMarker(&ships, 4, 0.75));
    try std.testing.expectEqual(Marker{ .at = 0, .passed = null }, nextMarker(&ships, 5, 0));
}
