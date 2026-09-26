//! `C:\lancer\game\aidock.cpp`: Dock, order 109, by which a ship docks at a port of another: a
//! freighter at a station's port, a fighter in a Nanny to take on missiles, a limpet car on a
//! ship. Its init picks one of five styles by what docks where; each style has its own init,
//! update and exit (`dock_styles`, `0x004E1618`). OpenReliant has the station's, which mission 1's
//! convoy docks at Fort Sherman by. `docs/engine/orders.md` describes it.
//!
//! Not ported: the Nanny's, the limpet car's, the limpet car's at the Czar and the limpet pod's
//! styles ([#320](https://github.com/vdmkenny/openreliant/issues/320)), which leave the ship
//! doing nothing.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const Matrix = math.Matrix;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");

/// How a ship docks, by what it is and what it docks at (`order_dock_init`).
pub const Style = enum(u8) {
    /// Any other ship at any other port: a freighter at a station.
    station = 0,
    /// A ship at a Nanny, which takes it aboard to rearm.
    nanny = 1,
    /// A limpet car at a ship.
    limpet_car = 2,
    /// A limpet car at the Czar, docked.
    limpet_car_czar = 3,
    /// A limpet pod.
    limpet_pod = 4,
    _,
};

/// The order's data (`aigeneric.Entry.data`).
pub const Data = extern struct {
    style: Style,
    _unknown_01: u8,
    /// The ship and the port the search for a free port found (`PortSearch`), before the order
    /// takes them for its target.
    found_ship: i16 align(1),
    found_port: u8,

    comptime {
        assert(@offsetOf(Data, "found_ship") == 0x2);
        assert(@offsetOf(Data, "found_port") == 0x4);
    }
};

/// The station style's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The docking path `motion_follow` follows as the ship slides in, at half its top speed.
    follower: motion.Follower,
    step: u32,
    /// The frame's tick the slide in ends at.
    until: i32,
    /// The part of the ship its docking point is on, by its place among the model's parts, and
    /// where the point stands on it; the game holds the part's node.
    own_part: u32,
    own_point: [3]f32,
    /// The part of the station its port is on, and where the port stands on it and how it is
    /// turned.
    port_part: u32,
    port_point: [3]f32,
    port_turn: [9]f32,
    /// Whether the ship came at the port from its right, which mirrors the way round.
    from_right: u32,
    /// Where the ship stood as the slide in began.
    slide_from: [3]f32,

    comptime {
        assert(@offsetOf(State, "step") == 0x08);
        assert(@offsetOf(State, "until") == 0x0C);
        assert(@offsetOf(State, "own_part") == 0x10);
        assert(@offsetOf(State, "own_point") == 0x14);
        assert(@offsetOf(State, "port_part") == 0x20);
        assert(@offsetOf(State, "port_point") == 0x24);
        assert(@offsetOf(State, "port_turn") == 0x30);
        assert(@offsetOf(State, "from_right") == 0x54);
        assert(@offsetOf(State, "slide_from") == 0x58);
    }
};

/// The station style's steps.
pub const Step = enum(u32) {
    /// Beside the port, `aside` out on the side the ship came from.
    beside = 0,
    /// Beside the port and `aside` behind it too.
    beside_behind = 1,
    /// Twice its turn's width out, and `aside` behind the port.
    turning_in = 2,
    /// On the port's line, `far_behind` behind it.
    far_behind = 3,
    /// On the port's line, `near_behind` behind it.
    near_behind = 4,
    /// It latches on, and starts to slide in.
    latching = 5,
    /// It slides in along the port's line (`way`).
    sliding = 6,
    /// It is in: set in place, and docked.
    docked = 7,
    /// OpenReliant's own: the ship or the port has no docking point, and the order ends.
    no_port = 8,
    _,
};

/// Where the station style steers, in the port's frame: out to its side and behind it
/// (`0x004DC4A0`, `0x004DC494`, and the immediates of `0x004070F0`).
const aside: f32 = 100000;
const far_behind: f32 = 50000;
const near_behind: f32 = 10000;

/// How near its point a step takes the ship before the next: the square of 2000 (`0x004DC490`).
const reach_squared: f32 = 4000000;

/// How far aside the turn in starts, in the ship's cruise speeds over its yaw rate (`0x004DC4A4`).
const turn_widths: f32 = -2;

/// Where a step aims, from where the ship is along the port's line, as the station style's init
/// picks its first: far behind it, and further aside than this share of the way behind
/// (`0x004DC3F8`).
const behind_share: f32 = 0.2;

/// How long the slide in lasts, in ticks, and each tick's share of it (`0x004DC49C`).
const slide_ticks = 1000;
const slide_share: f32 = 0.001;

/// The share of its top speed a ship slides in at (`0x00407303`).
const slide_limit: f32 = 0.5;

/// How the station style rolls the ship to stand as the port stands: its roll input is the roll
/// between them less twice its roll rate, the angle in degrees over forty (`0x004DC428`), within
/// 1 either way.
///
/// **Improvement:** the game holds the turn rounded to 1.4323944.
const roll_input: f32 = std.math.deg_per_rad / 40.0;
const roll_damping: f32 = 2;

/// The animation a port plays as a ship docks at it.
const port_track = "deploy";

/// How fast the port's animation plays (`0x00406E15`).
const port_speed: f32 = 4;

/// The types that pick the styles: the limpet car and the limpet pod, and what the car docks at,
/// the Czar docked, and the Nanny.
const limpet_car: gameobj.Type = @enumFromInt(0x1D);
const limpet_pod: gameobj.Type = @enumFromInt(0xBC);
const czar_docked: gameobj.Type = @enumFromInt(0x84);
const nanny: gameobj.Type = @enumFromInt(0x18);

/// `order_dock_init` (`0x00406B80`): where the order names no port, or a flight group or a squad
/// rather than a ship, the first free port of the ships it names (`PortSearch`) becomes its
/// target. Then the style, by what the ship is and what it docks at, and the style's init.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const entry = &all.slots[index].orders[0];
    if (entry.target.kind != .ship or entry.target.component == aigeneric.Target.whole) {
        entry.data.dock.found_ship = 0;
        entry.data.dock.found_port = 0;
        var search: PortSearch = .{ .all = all, .searcher = index };
        _ = ai.eachShip(ctx.world, entry.target, &search);
        entry.target.index = entry.data.dock.found_ship;
        entry.target.component = entry.data.dock.found_port;
    }
    const target = entry.target.slotIn(all) orelse return;
    const own_type = all.slots[index].object.type;
    const at_type = all.slots[target].object.type;
    entry.data.dock.style = if (own_type == limpet_car)
        if (at_type == czar_docked) .limpet_car_czar else .limpet_car
    else if (own_type == limpet_pod)
        .limpet_pod
    else if (at_type == nanny) .nanny else .station;
    switch (entry.data.dock.style) {
        .station => stationInit(ctx, index),
        else => {},
    }
}

/// `0x00406A90`, the search `init` runs over each ship its target names (`ai.eachShip`): the first
/// of the ship's ports, counting its docking points part by part, at which no other object's
/// current order is Dock.
const PortSearch = struct {
    all: *create.Objects,
    searcher: u16,

    pub fn visit(search: *PortSearch, ship: aigeneric.Target) bool {
        const at = ship.slotIn(search.all) orelse return false;
        const model = if (search.all.slots[at].model) |*held| held else return false;
        var ports: DockPoints = .of(model);
        var port: u8 = 0;
        while (ports.next()) |_| : (port +%= 1) {
            if (taken(search.all, search.searcher, at, port)) continue;
            const entry = &search.all.slots[search.searcher].orders[0];
            entry.data.dock.found_ship = @intCast(at);
            entry.data.dock.found_port = port;
            return true;
        }
        return false;
    }

    /// Whether an object other than `searcher` has Dock on at port `port` of the ship in slot `at`.
    fn taken(all: *const create.Objects, searcher: u16, at: u16, port: u8) bool {
        for (all.slots[0..all.count], 0..) |*slot, index| {
            if (index == searcher or slot.object.order_count == 0) continue;
            const entry = slot.orders[0];
            if (entry.order == .dock and entry.target.index == at and entry.target.component == port) return true;
        }
        return false;
    }
};

/// A model's docking points (`shp.Attachment.Kind.dock_point`), part by part as the root's child
/// list holds them, each part's attachments in order.
pub const DockPoints = struct {
    model: *const objects.Model,
    part: usize = 0,
    attachment: usize = 0,

    pub const Point = struct { part: usize, attachment: *const shp.Attachment };

    pub fn of(model: *const objects.Model) DockPoints {
        return .{ .model = model };
    }

    pub fn next(points: *DockPoints) ?Point {
        while (points.part < points.model.parts.len) : ({
            points.part += 1;
            points.attachment = 0;
        }) {
            const part = points.model.rootChild(points.part) orelse continue;
            while (points.attachment < part.attachments.len) {
                const at = &part.attachments[points.attachment];
                points.attachment += 1;
                if (at.kind == .dock_point) return .{ .part = points.part, .attachment = at };
            }
        }
        return null;
    }

    /// The `n`th, counting from 0.
    pub fn nth(model: *const objects.Model, n: usize) ?Point {
        var points: DockPoints = .of(model);
        var left = n;
        while (points.next()) |point| {
            if (left == 0) return point;
            left -= 1;
        }
        return null;
    }
};

/// `order_dock` (`0x00406C30`): the style's update.
pub fn update(ctx: Context, index: u16) void {
    switch (ctx.world.objects.slots[index].orders[0].data.dock.style) {
        .station => stationUpdate(ctx, index),
        else => {},
    }
}

/// `order_dock_exit` (`0x00406C50`): the style's exit; the station's and the Nanny's
/// (`0x00407D10`) have the ship pass through nothing more at the first place.
pub fn exit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    switch (slot.orders[0].data.dock.style) {
        .station => slot.object.passes_through[0] = .none,
        else => {},
    }
}

/// `dock_find_points` (`0x00406C80`): the ship's own docking point, its first, and the port of the
/// station its target names by the component, which starts the port's animation (`port_track`).
/// Whether both were found.
///
/// **Fix:** the game stops with "Docking information not defined on %s" where either has none;
/// OpenReliant logs it, and the order ends, as it does where the station has gone.
fn findPoints(ctx: Context, index: u16) bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.dock;
    const entry = slot.orders[0];
    const own_model = if (slot.model) |*held| held else return missing(index);
    const own = DockPoints.nth(own_model, 0) orelse return missing(index);
    state.own_part = @intCast(own.part);
    state.own_point = gameobj.vector(own.attachment.position);
    const at = entry.target.slotIn(all) orelse return missing(index);
    const model = if (all.slots[at].model) |*held| held else return missing(at);
    const port = DockPoints.nth(model, std.math.cast(usize, entry.target.component) orelse 0) orelse return missing(at);
    state.port_part = @intCast(port.part);
    state.port_point = gameobj.vector(port.attachment.position);
    state.port_turn = port.attachment.orientation;
    model.playNamed(port.part, port_track, 0, null, port_speed);
    return true;
}

fn missing(index: u16) bool {
    log.warn("the object in slot {d} has no docking point", .{index});
    return false;
}

/// Where a ship stands docked: the place of its own origin that brings its docking point onto the
/// port, turned as the port is.
pub const Berth = struct { position: Vector, orientation: Matrix };

/// `dock_berth` (`0x00406E70`): the berth at the port, as the station is drawn: the port's frame in
/// the world, less the ship's own docking point turned into it.
fn berth(world: gameobj.World, index: u16) ?Berth {
    const all = world.objects;
    const slot = &all.slots[index];
    const state = slot.state.dock;
    const at = slot.orders[0].target.slotIn(all) orelse return null;
    const station = &all.slots[at];
    const model = if (station.model) |*held| held else return null;
    const own_model = if (slot.model) |*held| held else return null;
    if (state.port_part >= model.parts.len or state.own_part >= own_model.parts.len) return null;
    const own = own_model.frameAt(state.own_part, .{ .position = @splat(0), .orientation = math.identity });
    const own_point = own.point(state.own_point);
    const port = model.frameAt(state.port_part, station.drawn);
    const local = @as(Vector, state.port_point) - math.transform(state.port_turn, own_point);
    return .{
        .position = port.point(local),
        .orientation = math.product(port.orientation, state.port_turn),
    };
}

/// The station style's init (`0x00407010`): it finds the docking points (`findPoints`), and picks
/// its first step by where the ship stands from the berth, in the port's frame: far behind the
/// port, it turns in, or comes straight along the line where it stands near it; nearer, behind it
/// or ahead of it, it goes round beside the port first. It notes which side it came from.
fn stationInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.dock;
    if (!findPoints(ctx, index)) {
        state.step = @intFromEnum(Step.no_port);
        return;
    }
    const at = berth(ctx.world, index) orelse return;
    const off = math.transformTransposed(at.orientation, gameobj.vector(slot.object.root.next_position) - at.position);
    state.from_right = @intFromBool(off[0] > 0);
    const step: Step = if (off[2] < -aside)
        if (@abs(off[0] / off[2]) > behind_share) .turning_in else .far_behind
    else if (off[2] < 0) .beside_behind else .beside;
    state.step = @intFromEnum(step);
}

/// The station style's update (`0x004070F0`), a step at a time (`Step`). Going round, the ship
/// steers at full throttle for the step's point (`ai.steer`), mirrored to the side it came from,
/// rolling to stand as the port stands, on to the next step within `reach_squared` of it. Latching
/// on, it flies `motion_follow` down the port's line (`way`), at `slide_limit` of its top speed,
/// the station stopped dead where it is. Once it is in, it is set in its berth, stopped, heard
/// docking, and has its Docked; the order ends.
///
/// **Fix:** the game goes on reading the frames of a station that has gone; OpenReliant ends the
/// order.
fn stationUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.dock;
    const at = berth(world, index) orelse {
        _ = aigeneric.pop(ctx, index);
        return;
    };
    const offset: Vector = switch (@as(Step, @enumFromInt(state.step))) {
        .beside => .{ -aside, 0, 0 },
        .beside_behind => .{ -aside, 0, -aside },
        .turning_in => turning: {
            const flight = slot.flight orelse return;
            break :turning .{ ai.cruiseSpeed(object, flight, world.view) * turn_widths / flight.yaw_rate, 0, -aside };
        },
        .far_behind => .{ 0, 0, -far_behind },
        .near_behind => .{ 0, 0, -near_behind },
        .latching => {
            object.flags.attached = true;
            slot.motion = .follow;
            state.follower = .{ .path = .dock, .limit = slide_limit };
            state.step = @intFromEnum(Step.sliding);
            state.until = ctx.clock.frame_start + slide_ticks;
            state.slide_from = gameobj.vector(object.root.next_position);
            if (slot.orders[0].target.slotIn(all)) |station| all.slots[station].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
            return;
        },
        .sliding => return,
        .docked => {
            ai.stop(object);
            objects.setPosition(object, &slot.drawn, at.position);
            objects.setOrientation(object, &slot.drawn, at.orientation);
            sound3d.playIn(world, null, null, index, .dock, 1, .not_reserved);
            events.docked(world, index);
            _ = aigeneric.pop(ctx, index);
            return;
        },
        .no_port, _ => {
            _ = aigeneric.pop(ctx, index);
            return;
        },
    };
    const side: Vector = if (state.from_right != 0) .{ -1, 1, 1 } else .{ 1, 1, 1 };
    const point = math.transform(at.orientation, offset * side) + at.position;
    _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
    object.throttle = ai.full_throttle;
    const left = point - gameobj.vector(object.root.next_position);
    if (math.lengthSquared(left) < reach_squared) state.step += 1;
    const up = math.transformTransposed(slot.drawn.orientation, math.yAxis(at.orientation));
    const roll = -std.math.atan2(up[0], up[1]);
    object.roll_input = std.math.clamp((roll - roll_damping * object.roll_rate) * roll_input, -1, 1);
}

/// `dock_way` (`0x00406F20`), which `motion_follow` calls as the ship slides in: a point on the
/// port's line behind the berth, as far back as the ship stood from it as it latched on, times the
/// square of the share of the slide left, and the port's way up. Once the slide is over, the ship's
/// motion is `motion_backward`, and it is in.
pub fn way(world: gameobj.World, index: u16) motion.Way {
    const slot = &world.objects.slots[index];
    const state = &slot.state.dock;
    const at = berth(world, index) orelse return .{ .point = gameobj.vector(slot.object.root.position) };
    const left = @max(@as(f32, @floatFromInt(state.until -% world.clock.frame_start)) * slide_share, 0);
    const back = math.distance(at.position, state.slide_from) * left * left;
    const point = at.position - math.forward(at.orientation) * @as(Vector, @splat(back));
    if (state.until < world.clock.frame_start) {
        slot.motion = .backward;
        state.step += 1;
    }
    return .{ .point = point, .up = math.yAxis(at.orientation) };
}

/// A model of one part hanging from the root, holding a docking point, unturned, at each of up to
/// two places. Set it up where it stays, as its records point into it.
const TestModel = struct {
    attachments: [2]shp.Attachment,
    data: [1]shp.PartData,
    loaded_parts: [1]@import("srofiles.zig").LoadedPart,
    source: shp.Model,
    loaded: @import("srofiles.zig").Loaded,

    fn init(model: *TestModel, points: []const Vector) void {
        for (&model.attachments, 0..) |*attachment, n| {
            attachment.* = std.mem.zeroes(shp.Attachment);
            attachment.kind = if (n < points.len) .dock_point else .missile;
            attachment.position = gameobj.vec3(if (n < points.len) points[n] else @splat(0));
            attachment.orientation = math.identity;
        }
        model.data = .{objects.testing.part()};
        model.data[0].part.parent = -1;
        model.data[0].attachments = &model.attachments;
        model.loaded_parts = .{.{ .flags = .{}, .levels = &.{}, .meshes = &.{} }};
        model.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &model.data, .trailing_bytes = 0 };
        model.loaded = .{ .parts = &model.loaded_parts };
    }

    fn fit(model: *const TestModel, slot: *create.Slot) !void {
        slot.model = try .create(std.testing.allocator, &model.source, &model.loaded, .{});
        gameobj.linkPart(&slot.model.?, 0);
    }
};

/// A station at 10000 along Z, its two ports 1000 behind it and 1000 to its right, and two
/// freighters, each with its docking point at its nose, 500 ahead.
const TestDock = struct {
    game: gameobj.testing.Mission,
    station_model: TestModel,
    freighter_model: TestModel,
    station: u16,
    freighters: [2]u16,

    fn init(dock: *TestDock) !void {
        try dock.game.init(std.testing.allocator);
        errdefer dock.game.deinit();
        dock.station_model.init(&.{ .{ 0, 0, -1000 }, .{ 1000, 0, 0 } });
        dock.freighter_model.init(&.{.{ 0, 0, 500 }});
        _ = try dock.game.add(.predator, .{ 0, 50000, 0 });
        dock.station = try dock.game.add(.predator, .{ 0, 0, 10000 });
        try dock.station_model.fit(dock.game.slot(dock.station));
        dock.game.slot(dock.station).drawn = .{ .position = .{ 0, 0, 10000 } };
        for (&dock.freighters) |*freighter| {
            freighter.* = try dock.game.add(.predator, .{ 0, 0, -200000 });
            try dock.freighter_model.fit(dock.game.slot(freighter.*));
            dock.place(freighter.*, .{ 0, 0, -200000 });
        }
    }

    fn deinit(dock: *TestDock) void {
        for ([_]u16{ dock.station, dock.freighters[0], dock.freighters[1] }) |index| {
            if (dock.game.slot(index).model) |*model| model.deinit(std.testing.allocator);
            dock.game.slot(index).model = null;
        }
        dock.game.deinit();
    }

    fn place(dock: *TestDock, index: u16, at: Vector) void {
        const slot = dock.game.slot(index);
        slot.object.root.next_position = gameobj.vec3(at);
        slot.object.root.position = gameobj.vec3(at);
        slot.drawn = .{ .position = at };
    }

    fn orders(dock: *TestDock) Context {
        return dock.game.orders();
    }
};

test "a freighter docks at a station's port, from far behind it" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    const slot = dock.game.slot(index);
    slot.motion = .forward;
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));

    // Far behind the port, on its line, it comes straight along it, full ahead.
    aigeneric.objectOrders(dock.orders(), index);
    const state = &slot.state.dock;
    try std.testing.expectEqual(Style.station, slot.orders[0].data.dock.style);
    try std.testing.expectEqual(@intFromEnum(Step.far_behind), state.step);
    try std.testing.expectEqual(1, slot.object.throttle);
    // Its berth brings its nose onto the port.
    const at = berth(dock.orders().world, index).?;
    try std.testing.expectEqual(Vector{ 0, 0, 8500 }, at.position);
    // Near each point, on to the next, and then it latches on.
    dock.place(index, .{ 0, 0, 8500 - far_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.near_behind), state.step);
    dock.place(index, .{ 0, 0, 8500 - near_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.latching), state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.sliding), state.step);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    try std.testing.expect(slot.object.flags.attached);
    // Half way through the slide, a quarter of the way back along the port's line.
    dock.game.clock.frame_start += slide_ticks / 2;
    const half = way(dock.orders().world, index);
    try std.testing.expectApproxEqAbs(8500 - near_behind / 4, half.point[2], 1e-2);
    // Past its end, it is in: set in its berth, and its order over.
    dock.game.clock.frame_start += slide_ticks;
    _ = way(dock.orders().world, index);
    try std.testing.expectEqual(@intFromEnum(Step.docked), state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(8500, slot.object.root.position.z);
    try std.testing.expectEqual(gameobj.Slot.none, slot.object.passes_through[0]);
}

test "a ship without a port given takes the first free one" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    for (dock.freighters) |index| {
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .{ .kind = .ship, .index = @intCast(dock.station), .component = aigeneric.Target.whole }));
        aigeneric.objectOrders(dock.orders(), index);
    }
    try std.testing.expectEqual(0, dock.game.slot(dock.freighters[0]).orders[0].target.component);
    try std.testing.expectEqual(1, dock.game.slot(dock.freighters[1]).orders[0].target.component);
}

test "a ship docks nowhere at a ship with no docking point" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    // The player's ship, in the first slot, has no model, and so no port.
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(0, 0)));
    aigeneric.objectOrders(dock.orders(), index);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, dock.game.slot(index).object.order_count);
}
