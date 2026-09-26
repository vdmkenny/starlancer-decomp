//! Ship Follow Curve and Ship Follow Curve Backwards, orders 17 and 119: a ship flies to where a
//! path of the mission's curves ([`executor/curves.zig`](../executor/curves.zig)) starts, turned
//! along it, then along the path by `motion_follow` ([`motion.zig`](../motion.zig)), over the
//! order's seconds; backwards, from the path's end to its start. The scripts give them with
//! `ShipFollowCurve`, `MovingShipFollowCurve` and `MovingShipBackupCurve`.
//!
//! **Unverified:** the source file. The code lies after `Ai.cpp`'s known code and before
//! `aidefend.cpp`'s, and does the orders' work, as `Ai.cpp`'s neighbours do.
//!
//! Not ported: a multiplayer game's wait for the other players before the path and after it
//! (`0x00401000`).

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Context = aigeneric.Context;
const curves = @import("../executor/curves.zig");
const events = @import("../mission/events.zig");
const gameobj = @import("../gameobj.zig");
const motion = @import("../motion.zig");

/// The order's data, as the command gives it (`aigeneric.Entry.data`).
pub const Data = extern struct {
    /// The curve the path starts along, by its index among the mission's curves, where the game
    /// holds its record's address.
    curve: u32 align(2),
    /// How long the path takes, in seconds.
    seconds: u32 align(2),
    /// The ship whose place carries the path, by its index among the mission's ships, or `none`:
    /// the path stands off from the curves as far as the ship stands, as the order starts, from
    /// where the mission placed it (`curves.ride`). The game holds its record's address, or null.
    offset: u32 align(2),

    pub const none: u32 = 0xFFFF_FFFF;

    comptime {
        assert(@offsetOf(Data, "seconds") == 0x4);
        assert(@offsetOf(Data, "offset") == 0x8);
    }
};

/// The order's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The path `motion_follow` follows, and its limit, the ship's top speed.
    follower: motion.Follower,
    /// The curve the ship follows now, by its index; the game holds its record's address.
    curve: u32,
    step: u8,
    _unknown_0d: [3]u8,
    /// The frame's tick the curve began (`frame_start`).
    since: u32,
    /// The curve's share of the order's seconds, in ticks.
    ticks: u16,
    _unknown_16: [2]u8,
    /// The path's length, from the order's curve (`curves.pathLength`).
    path_length: f32,
    _unknown_1c: [12]u8,
    /// Where the order's offset ship stood as the order began.
    start: [3]f32,
    /// The share of the way along the curve to the next place a point marks, 0 for none.
    next_marker: f32,

    comptime {
        assert(@offsetOf(State, "curve") == 0x08);
        assert(@offsetOf(State, "step") == 0x0C);
        assert(@offsetOf(State, "since") == 0x10);
        assert(@offsetOf(State, "ticks") == 0x14);
        assert(@offsetOf(State, "path_length") == 0x18);
        assert(@offsetOf(State, "start") == 0x28);
        assert(@offsetOf(State, "next_marker") == 0x34);
    }
};

/// The orders' steps.
pub const Step = enum(u8) {
    /// It flies to where the path starts, turned along it (`ai.arrive`).
    arriving = 0,
    /// It waits for the other players in a multiplayer game; in a game of one, it goes on at once.
    ready = 1,
    /// It follows the path, which moves on to `done` at its end.
    following = 2,
    done = 3,
    _,
};

/// How far along the path, in ticks, the ship looks from its start for the way to face as it
/// arrives there: a simulation step (`0x004DC424`).
const lead_ticks: f32 = 4;

/// Game ticks to a second (`0x004DC440`).
const ticks_per_second: f32 = 100;

/// `order_ship_follow_curve_init` (`0x00403340`): the ship in slot `index` follows the path from its
/// order's curve: its path is Ship Follow Curve's at its full speed, its length measured, where its
/// offset ship stands noted, and the order's curve begun (`beginCurve`).
pub fn init(ctx: Context, index: u16) void {
    start(ctx, index, .curve);
    const data = entryData(ctx.world.objects, index);
    beginCurve(ctx, index, data.curve);
}

/// `order_ship_follow_curve_backwards_init` (`0x004036C0`): `init` for the path backwards, which begins at the
/// path's last curve (`lastCurve`).
pub fn backwardsInit(ctx: Context, index: u16) void {
    start(ctx, index, .curve_backwards);
    lastCurve(ctx, index, null);
}

/// What the two orders' `init`s share: the path to follow, the step, the path's length, and where
/// the offset ship stands, as the object stands (`ship_object`).
fn start(ctx: Context, index: u16, path: motion.Follower.Path) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.follow;
    const data = entryData(all, index);
    state.follower = .{ .path = path, .limit = full_speed };
    state.step = @intFromEnum(Step.arriving);
    state.path_length = curves.pathLength(missionCurves(ctx.world), data.curve);
    if (offsetShip(data)) |ship| if (ship < all.slots.len) {
        state.start = gameobj.vector(all.slots[ship].object.root.position);
    };
}

/// The limit a path gives `motion_follow`: the ship's top speed (`0x004DC404`).
const full_speed: f32 = 1;

/// `follow_curve_begin` (`0x004031A0`): the ship in slot `index` begins curve `curve` of its path,
/// now, for the curve's share of the order's seconds, as its length is to the path's, and looks for
/// the first place a point marks on it.
///
/// **Fix:** the game divides by nothing for a path of no length, and takes a curve's ticks past
/// 65535 round from nothing; OpenReliant gives a curve of a path of no length all the order's
/// ticks, and holds them at 65535.
fn beginCurve(ctx: Context, index: u16, curve: u32) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.follow;
    const data = entryData(all, index);
    state.curve = curve;
    state.since = @bitCast(ctx.clock.frame_start);
    state.ticks = curveTicks(ctx.world, state.*, data, curve);
    state.next_marker = if (std.math.cast(u16, curve)) |at| curves.nextMarker(missionShips(ctx.world), at, 0).at else 0;
}

/// Curve `curve`'s share of `data`'s seconds, in ticks, for a path of `state.path_length`.
fn curveTicks(world: gameobj.World, state: State, data: Data, curve: u32) u16 {
    const list = missionCurves(world);
    const length = if (curve < list.len) curves.length(list[curve]) else 0;
    const seconds: f32 = @floatFromInt(data.seconds);
    const part = if (state.path_length == 0) 1 else length / state.path_length;
    return std.math.lossyCast(u16, part * seconds * ticks_per_second);
}

/// `follow_back_curve` (`0x00403580`): the ship in slot `index` begins the curve before `before` on
/// its path backwards, or the path's last where `before` is null: from the order's curve, each that
/// carries the path on from where the last ends (`curves.next`), up to one that ends at no ship, or
/// the one before `before`. Its share of the ticks is as `beginCurve` gives it; it looks for no
/// place a point marks.
///
/// **Fix:** the game follows a path that comes round to a curve it has taken for ever; OpenReliant
/// stops once it has taken as many curves as the mission has.
fn lastCurve(ctx: Context, index: u16, before: ?u32) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.follow;
    const data = entryData(all, index);
    const list = missionCurves(ctx.world);
    var at = data.curve;
    for (0..list.len) |_| {
        if (at >= list.len) break;
        const end = list[at].endShip() orelse break;
        const following = curves.next(list, at, end, false) orelse break;
        if (before) |stop| if (following == stop) break;
        at = @intCast(following);
    }
    state.curve = at;
    state.since = @bitCast(ctx.clock.frame_start);
    state.ticks = curveTicks(ctx.world, state.*, data, at);
}

/// `order_ship_follow_curve` (`0x004033A0`), a step at a time (`Step`). Arriving, the ship flies to the
/// path's start, turned toward its point a step on, at the pace the path keeps there (`ai.arrive`),
/// the curve's clock held at its start. Following, it flies `motion_follow`, or
/// `motion_follow_backwards` where it was flying tail first, and once the path is over the order
/// ends.
pub fn update(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.follow;
    switch (@as(Step, @enumFromInt(state.step))) {
        .arriving => {
            if (arriveAt(ctx, index, 0, lead_ticks)) state.step = @intFromEnum(Step.ready);
            state.since = @bitCast(ctx.clock.frame_start);
        },
        .ready => state.step = @intFromEnum(Step.following),
        .following => slot.motion = if (slot.motion == .backward or slot.motion == .follow_backwards) .follow_backwards else .follow,
        .done => _ = aigeneric.pop(ctx, index),
        _ => {},
    }
}

/// `order_ship_follow_curve_backwards` (`0x00403720`): `update` for the path backwards. Arriving, the ship
/// flies its own motion ahead (`motion_forward`) to the curve's end, turned toward its point a step
/// back; following, it flies `motion_follow`.
pub fn backwardsUpdate(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.follow;
    switch (@as(Step, @enumFromInt(state.step))) {
        .arriving => {
            slot.motion = .forward;
            if (arriveAt(ctx, index, 1, -lead_ticks)) state.step = @intFromEnum(Step.ready);
            state.since = @bitCast(ctx.clock.frame_start);
        },
        .ready => state.step = @intFromEnum(Step.following),
        .following => slot.motion = .follow,
        .done => _ = aigeneric.pop(ctx, index),
        _ => {},
    }
}

/// The ship in slot `index` flies to the point `from` of the way along its curve, turned toward the
/// point `lead` ticks on from there, arriving at the pace the path keeps between the two: the way
/// between them over the ship's cruise speed (`ai.arrive`). Whether it has arrived.
fn arriveAt(ctx: Context, index: u16, from: f32, lead: f32) bool {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = slot.state.follow;
    const list = missionCurves(world);
    if (state.curve >= list.len) return true;
    const curve = list[state.curve];
    const data = entryData(world.objects, index);
    const step = if (state.ticks == 0) std.math.sign(lead) else lead / @as(f32, @floatFromInt(state.ticks));
    const here = ride(world, data, state, curves.point(curve, from));
    const next = ride(world, data, state, curves.point(curve, from + step));
    const flight = slot.flight orelse return true;
    const pace = math.distance(here, next) / ai.cruiseSpeed(&slot.object, flight, world.view);
    return ai.arrive(world, index, here, math.lookAt(next - here), pace);
}

/// `order_ship_follow_curve_exit` (`0x00403550`): the ship flies its own motion again, ahead, or astern
/// where it followed the path tail first.
pub fn exit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.motion = if (slot.motion == .follow_backwards) .backward else .forward;
}

/// `order_ship_follow_curve_backwards_exit` (`0x004038C0`): the ship flies its own motion ahead again.
pub fn backwardsExit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].motion = .forward;
}

/// `follow_curve_way` (`0x00403200`), which `motion_follow` calls for Ship Follow Curve: the point
/// of the ship's curve as far along as the curve's ticks have gone, carried with the order's offset
/// ship. Past a place a point marks, the point has the ship's ShipReached, one place an update. At
/// the curve's end the ship it ends at has the ship's ShipReached, and the curve that carries the
/// path on begins; with none, the path is over.
///
/// **Fix:** at a curve that ends at no ship, the game carries the path on to a curve that starts or
/// ends at none; OpenReliant ends the path there, as its length has it (`curves.pathLength`).
pub fn curveWay(world: gameobj.World, index: u16) motion.Way {
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.follow;
    const data = entryData(all, index);
    const list = missionCurves(world);
    if (state.curve >= list.len) {
        state.step = @intFromEnum(Step.done);
        return .{ .point = gameobj.vector(slot.object.root.position) };
    }
    const curve = list[state.curve];
    const t = share(world, state.*);
    const point = ride(world, data, state.*, curves.point(curve, t));
    if (state.next_marker > 0 and t > state.next_marker) {
        const marker = curves.nextMarker(missionShips(world), @intCast(state.curve), state.next_marker);
        state.next_marker = marker.at;
        if (marker.passed) |ship| events.shipReached(world, ship, index);
    }
    if (t >= 1) {
        if (curve.endShip()) |end| {
            events.shipReached(world, end, index);
            if (curves.next(list, state.curve, end, false)) |following| {
                beginCurve(.{ .world = world, .clock = world.clock }, index, @intCast(following));
                return .{ .point = point };
            }
        }
        state.step +%= 1;
    }
    return .{ .point = point };
}

/// `follow_back_way` (`0x00403600`), which `motion_follow` calls for Ship Follow Curve Backwards:
/// the point of the ship's curve as far back from its end as the curve's ticks have gone, carried
/// with the order's offset ship. Past the curve's start, the curve before it begins (`lastCurve`),
/// or at the order's own curve the path is over.
pub fn backwardsWay(world: gameobj.World, index: u16) motion.Way {
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.follow;
    const data = entryData(all, index);
    const list = missionCurves(world);
    if (state.curve >= list.len) {
        state.step = @intFromEnum(Step.done);
        return .{ .point = gameobj.vector(slot.object.root.position) };
    }
    const t = 1 - share(world, state.*);
    const point = ride(world, data, state.*, curves.point(list[state.curve], t));
    if (t < 0) {
        if (state.curve == data.curve) {
            state.step +%= 1;
        } else {
            lastCurve(.{ .world = world, .clock = world.clock }, index, state.curve);
        }
    }
    return .{ .point = point };
}

/// How far along its curve the ship is: the ticks since the curve began over the curve's.
///
/// **Fix:** the game divides by nothing for a curve given no ticks; OpenReliant takes it to the
/// curve's end.
fn share(world: gameobj.World, state: State) f32 {
    if (state.ticks == 0) return 1;
    const since = world.clock.frame_start -% @as(i32, @bitCast(state.since));
    return @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(state.ticks));
}

/// `on`, a point of the path, carried with the order's offset ship where it has one: by how far the
/// ship stood from where the mission placed it as the order began (`curves.ride`).
fn ride(world: gameobj.World, data: Data, state: State, on: Vector) Vector {
    const ship = offsetShip(data) orelse return on;
    const ships = missionShips(world);
    if (ship >= ships.len) return on;
    return curves.ride(on, ships[ship].position, state.start, null);
}

fn offsetShip(data: Data) ?u16 {
    return if (data.offset == Data.none) null else std.math.cast(u16, data.offset);
}

fn entryData(all: anytype, index: u16) Data {
    return all.slots[index].orders[0].data.follow;
}

fn missionCurves(world: gameobj.World) []align(1) const dte.Curve {
    const bound = world.mission orelse return &.{};
    return bound.file.curves() catch &.{};
}

fn missionShips(world: gameobj.World) []align(1) const dte.Ship {
    const bound = world.mission orelse return &.{};
    return bound.file.ships() catch &.{};
}

/// A mission of four ships: the player's, a Predator that follows the path, and the two points
/// curve 0 runs between, 4000 apart along Z, each in the slot of its index.
const TestPath = struct {
    fixture: @import("../../vm.zig").machine.testing.Fixture,
    game: gameobj.testing.Mission,

    /// The follower's slot.
    const follower = 1;

    fn init(path: *TestPath) !void {
        const gpa = std.testing.allocator;
        var ships: [4]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
        for (&ships, 0..) |*ship, n| {
            ship.object_id = @intCast(n);
            ship.flight_group = dte.Ship.no_flight_group;
            ship.kind = if (n < 2) @intFromEnum(gameobj.Type.predator) else dte.Ship.curve_point_kind;
        }
        try path.fixture.init(gpa, &.{}, .{ .ships = &ships, .curves = &.{curves.testCurve(2, 3, .{ 0, 0, 0 }, .{ 0, 0, 4000 })} });
        errdefer path.fixture.deinit();
        try path.game.init(gpa);
        for ([_]Vector{ .{ 0, 50000, 0 }, .{ 0, 0, -100 }, .{ 0, 0, 0 }, .{ 0, 0, 4000 } }) |at| _ = try path.game.add(.predator, at);
    }

    fn deinit(path: *TestPath) void {
        path.game.deinit();
        path.fixture.deinit();
    }

    fn orders(path: *TestPath) Context {
        var ctx = path.game.orders();
        ctx.world.mission = &path.fixture.mission;
        return ctx;
    }

    /// The follower's orders and its move, at the frame's tick `at`.
    fn frame(path: *TestPath, at: i32) void {
        path.game.clock.frame_start = at;
        aigeneric.objectOrders(path.orders(), follower);
        motion.moveSlot(path.orders().world, follower);
    }

    /// Gives the follower `order` along curve 0 for four seconds.
    fn give(path: *TestPath, order: @import("orders.zig").Order) !*@import("../create.zig").Slot {
        const slot = path.game.slot(follower);
        slot.motion = .forward;
        try std.testing.expect(try aigeneric.push(path.orders(), follower, order, .none));
        slot.orders[0].data = .{ .follow = .{ .curve = 0, .seconds = 4, .offset = Data.none } };
        return slot;
    }
};

test "a ship follows the path from where it starts, for the order's seconds" {
    var path: TestPath = undefined;
    try path.init();
    defer path.deinit();
    const slot = try path.give(.ship_follow_curve);

    // It stands within reach of the path's start, so it is there at once, and then follows.
    path.frame(100);
    const state = &slot.state.follow;
    try std.testing.expectEqual(400, state.ticks);
    try std.testing.expectEqual(4000, state.path_length);
    try std.testing.expectEqual(@intFromEnum(Step.ready), state.step);
    path.frame(100);
    try std.testing.expectEqual(@intFromEnum(Step.following), state.step);
    path.frame(100);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    // Half way through the seconds, its way is the curve's middle, 2100 on: further than its top
    // speed takes it in a step, so it goes at its top speed, its throttle full.
    path.frame(300);
    try std.testing.expectApproxEqAbs(gameobj.testing.flight.max_speed, slot.object.velocity.z, 1e-2);
    try std.testing.expectEqual(1, slot.object.throttle);
    // At the curve's end, which carries the path on nowhere, the path is over, and so the order.
    path.frame(500);
    try std.testing.expectEqual(@intFromEnum(Step.done), state.step);
    path.frame(500);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(motion.Motion.forward, slot.motion.?);
}

test "a ship follows the path backwards, from its end" {
    var path: TestPath = undefined;
    try path.init();
    defer path.deinit();
    const slot = try path.give(.ship_follow_curve_backwards);

    // It stands far from the path's end, so it flies there first, its own motion ahead.
    path.frame(100);
    const state = &slot.state.follow;
    try std.testing.expectEqual(@intFromEnum(Step.arriving), state.step);
    try std.testing.expectEqual(motion.Motion.forward, slot.motion.?);
    try std.testing.expect(slot.object.throttle > 0);
    // Once there, it follows the path from its end back to its start.
    slot.object.root.next_position = .{ .x = 0, .y = 0, .z = 4000 };
    path.frame(100);
    try std.testing.expectEqual(@intFromEnum(Step.ready), state.step);
    path.frame(100);
    path.frame(100);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    const world = path.orders().world;
    try std.testing.expectApproxEqAbs(4000, backwardsWay(world, TestPath.follower).point[2], 1e-2);
    path.game.clock.frame_start = 300;
    try std.testing.expectApproxEqAbs(2000, backwardsWay(world, TestPath.follower).point[2], 1e-2);
    // Past the start of the path's first curve, it is over.
    path.game.clock.frame_start = 501;
    _ = backwardsWay(world, TestPath.follower);
    try std.testing.expectEqual(@intFromEnum(Step.done), state.step);
}
