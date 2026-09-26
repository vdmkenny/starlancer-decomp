//! `C:\lancer\game\launch.cpp`: order 104, Launch, by which a ship leaves the ship it launches
//! from, its carrier: `order_launch_init` (`0x00418EB0`) and `order_launch` (`0x004191C0`). A
//! carrier launches its ships in a style of its own (`Style`), each a pair of routines in the
//! table at `0x004E3C98`: the Reliant's ([`launch/reliant.zig`](launch/reliant.zig)) and the
//! torpedoes' ([`launch/torpedo.zig`](launch/torpedo.zig)). **Unverified:** that the code around
//! the file's known code is its own too: StartLaunch's start (`start`) and the search for a gate
//! before it, and the styles' routines, the placing at a launch point (`attach`) among them,
//! after it, before `tractor.cpp`'s. [Launches](../../../docs/engine/launch.md) describes them.
//!
//! Not ported: the other styles
//! ([#304](https://github.com/vdmkenny/openreliant/issues/304)). A ship that launches in one waits
//! for its launch riding its carrier, as every launching ship does, and is let go where it stands
//! as its style's steps would begin (`letGo`).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.launch);

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const models = @import("create/models.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");

pub const reliant = @import("launch/reliant.zig");
pub const torpedo = @import("launch/torpedo.zig");

/// How a ship launches (`launch_styles`, `0x004E3C98`): a record of two routines for each, the
/// first placing the ship for its launch and naming the node it rides (`State.node`,
/// `create.Slot.riding`), the second running its launch from step 2 on (`Step`).
pub const Style = enum(i32) {
    /// From a hangar bay (`0x0041A610`, `0x0041A9C0`): the Victorious's, the Endeavour's, the
    /// Mitchells', the Bremen's, the Ramases's, the Pukov's, the Kronstadt's, the Krasnaya's, the
    /// Varyag's and the Kiev's, and the rogue base's from its seventh gate on.
    bay = 0,
    /// From the Yamato (`0x004192C0`, `0x00419840`).
    yamato = 1,
    /// From the Badanov and the Krasny (`0x00419F60`, `0x0041A100`).
    badanov = 2,
    /// A torpedo from its tube (`0x0041A360`, `0x0041A390`), whatever it launches from.
    torpedo = 3,
    /// An escape pod (`0x0041A4B0`, `0x0041A4D0`).
    escape_pod = 4,
    /// From the Stork (`0x0041A4B0`, `0x0041AD10`).
    stork = 5,
    /// From the Reliant (`0x0041AE20`, `0x0041B240`).
    reliant = 6,
    /// The other escape pod (`0x0041A4B0`, `0x0041B690`).
    other_escape_pod = 7,
    /// From the rogue base's first six gates (`0x0041B770`, `0x0041B7F0`).
    rogue_base = 8,
    /// From the Zakov (`0x0041B8B0`, `0x0041B940`).
    zakov = 9,
    _,

    /// The style `order_launch_init` gives a ship of type `ship` launching from a carrier of type
    /// `carrier` through `gate`: a torpedo's or an escape pod's by its own type, any other's by
    /// its carrier's. Null for a carrier no ship launches from, which the game stops for with
    /// "Error: Trying to launch from %s".
    pub fn of(ship: gameobj.Type, carrier: gameobj.Type, gate: i16) ?Style {
        return switch (ship) {
            .torpedo, .russian_torpedo => .torpedo,
            .escape_pod => .escape_pod,
            .other_escape_pod => .other_escape_pod,
            else => switch (carrier) {
                .reliant => .reliant,
                .yamato => .yamato,
                .victorious, .endeavour, .mitchell, .bremen, .ramases, .pukov, .kronstadt, .krasnaya, .varyag, .other_ramases, .other_mitchell, .kiev => .bay,
                .stork => .stork,
                .badanov, .krasny => .badanov,
                .rogue_base => if (gate < rogue_base_gates) .rogue_base else .bay,
                .zakov => .zakov,
                else => null,
            },
        };
    }

    /// Whether OpenReliant runs the style's routines.
    pub fn ported(style: Style) bool {
        return switch (style) {
            .reliant, .torpedo => true,
            else => false,
        };
    }

    pub fn format(style: Style, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (style) {
            _ => writer.print("style {d}", .{@intFromEnum(style)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

/// The rogue base's gates that launch in its own style; those after launch from a bay.
const rogue_base_gates = 6;

/// A launch's steps as `order_launch` runs them: waiting for StartLaunch, then a moment more
/// (`most_delay`), then its style's own, numbered from `styled` on.
pub const Step = enum(i32) {
    waiting = 0,
    delaying = 1,
    _,

    /// The first of the style's own steps.
    pub const styled: Step = @enumFromInt(2);

    /// Whether the style's own steps have begun.
    pub fn isStyled(step: Step) bool {
        return @intFromEnum(step) >= @intFromEnum(styled);
    }
};

/// What Launch keeps in the object's order state.
pub const State = extern struct {
    style: Style,
    /// The frame's tick after which its next step runs.
    due: i32,
    step: Step,
    /// Where the ship stands in the frame of the node it rides, and how it is turned there.
    position: shp.Vec3,
    orientation: math.Matrix,
    /// Whether it rides its node, which each frame's pass places it on (`hold`).
    attached: bool,
    _unknown_3d: [3]u8,
    /// The node it rides, which its style names: the address OpenReliant keeps as
    /// `create.Slot.riding`.
    node: engine.Pointer(objects.Node),
    /// How many launch points the search for a gate passes over (`GateSearch`): its order's place
    /// among those its command gave (`aigeneric.Entry.sequence`).
    sequence: i32,
    /// The carrier, and the gate on it, the search found.
    carrier: i32,
    gate: i32,
    _unknown_50: [0x90 - 0x50]u8,

    comptime {
        assert(@offsetOf(State, "due") == 0x04);
        assert(@offsetOf(State, "step") == 0x08);
        assert(@offsetOf(State, "position") == 0x0C);
        assert(@offsetOf(State, "orientation") == 0x18);
        assert(@offsetOf(State, "attached") == 0x3C);
        assert(@offsetOf(State, "node") == 0x40);
        assert(@offsetOf(State, "sequence") == 0x44);
        assert(@offsetOf(State, "carrier") == 0x48);
        assert(@offsetOf(State, "gate") == 0x4C);
        assert(@sizeOf(State) == 0x90);
    }

    /// Moves on to step `next`, which runs once `wait` more ticks have passed from `now`.
    pub fn advance(state: *State, next: Step, now: i32, wait: i32) void {
        state.step = next;
        state.due = now + wait;
    }
};

/// What Launch keeps in its entry's data (`aigeneric.Entry.Data`).
pub const Data = extern struct {
    /// Set by StartLaunch (`start`): the launch goes.
    go: bool,
};

/// How long a launch waits after its start before its style's first step, at most, in ticks: a
/// random share of it (`order_launch`, `0x00419254`).
const most_delay = 200;

/// How long the init has a launch wait before its next step (`order_launch_init`, `0x00419023`),
/// which no step reads before the start sets its own.
const init_wait = 200;

/// `order_launch_init` (`0x00418EB0`): readies the launch of the ship in slot `index`. Where its
/// order is aimed at a flight group or a squad, or at a ship with no gate, the search for a gate
/// (`GateSearch`) walks the target's ships (`ai.eachShip`) and names the carrier and the gate it
/// finds in the order's target, whose kind stays as it was: from then on the launch takes the
/// target's index for its carrier's slot. The style follows from the ship's type and its
/// carrier's (`Style.of`), and its first routine places the ship and names the node it rides.
/// Then the ship rides the node, standing where it stands in it and turned as it is, it passes
/// through its carrier, and it can't be targeted.
///
/// **Fix:** the game stops with the assertion "Error: Trying to launch from %s" for a carrier no
/// ship launches from, and reads through a missing node for a style that named none. OpenReliant
/// logs the first and launches the ship as in a style it does not run; a ship with no node rides
/// nothing.
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const entry = &slot.orders[0];
    const state = &slot.state.launch;
    if (entry.target.kind != .ship or entry.target.component == aigeneric.Target.whole) {
        state.carrier = 0;
        state.gate = 0;
        state.sequence = entry.sequence;
        var search: GateSearch = .{ .all = all, .state = state };
        _ = ai.eachShip(ctx.world, entry.target, &search);
        entry.target.index = @truncate(state.carrier);
        entry.target.component = @truncate(state.gate);
    }
    const carrier = carrierOf(all, entry.target) orelse return;
    const carrier_type = all.slots[carrier].object.type;
    const style = Style.of(slot.object.type, carrier_type, entry.target.component);
    // The game leaves the style it cleared as the order started, the first.
    state.style = style orelse .bay;
    state.step = .waiting;
    slot.riding = null;
    if (style) |known| switch (known) {
        .reliant => reliant.init(ctx, index, carrier),
        .torpedo => torpedo.init(ctx, index, carrier),
        else => log.debug("slot {d} launches in the {f} style, not ported yet: it goes where it stands", .{ index, known }),
    } else log.warn("slot {d} can't launch from ship type {d}: it goes where it stands", .{ index, @intFromEnum(carrier_type) });
    if (!state.style.ported()) slot.riding = .{ .object = carrier };
    if (if (slot.riding) |riding| riding.place(all) else null) |node| {
        const relative = slot.drawn.relativeTo(node);
        state.position = gameobj.vec3(relative.position);
        state.orientation = relative.orientation;
        state.attached = true;
    }
    state.due = ctx.clock.frame_start + init_wait;
    slot.object.passes_through[0] = .of(carrier);
    ai.setTargetable(&slot.object, slot.combat, false);
}

/// The slot of the carrier `target` names by its index, whatever its kind, where it names one
/// within the objects.
fn carrierOf(all: *const create.Objects, target: aigeneric.Target) ?u16 {
    const carrier = target.slot() orelse return null;
    return if (carrier < all.slots.len) carrier else null;
}

/// `order_launch` (`0x004191C0`): the launch of the ship in slot `index`, an update at a time.
/// Before its style's steps, a carrier gone, a stand-in or exploding, ends the ship with it
/// (`ai.objectDestroyed`), save an escape pod leaving the Ulysses as it is lost. Once StartLaunch
/// has it go (`Data.go`), the launch waits a random moment of up to `most_delay` ticks, drawn from
/// the ship's own numbers (`xtrabits.objectRandom15`), then its style runs it from step 2.
///
/// Not ported: for the player's ship, the radio's line as the launch goes (`0x00456E50`), which is
/// the comms' ([#48](https://github.com/vdmkenny/openreliant/issues/48)).
///
/// **Fix:** the game reads the carrier of a Launch aimed at nothing from before its objects, with
/// the assertion "Launch Crash Imminent"; OpenReliant lets the ship go (`letGo`).
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const entry = &slot.orders[0];
    const state = &slot.state.launch;
    const now = ctx.clock.frame_start;
    if (!state.step.isStyled()) {
        const carrier = carrierOf(all, entry.target) orelse return letGo(ctx, index);
        const from = &all.slots[carrier].object;
        const gone = from.type == .stand_in or from.flags.exploding;
        if (gone and !(from.type == .ulysses and slot.object.type == .escape_pod)) {
            ai.objectDestroyed(ctx, index, false, false);
            return;
        }
        if (entry.data.launch.go and state.step == .waiting) {
            state.advance(.delaying, now, @intCast(xtrabits.objectRandom15(&slot.object) % most_delay));
        }
        if (state.step == .delaying and state.due < now) state.step = Step.styled;
    }
    switch (state.style) {
        .reliant => reliant.run(ctx, index),
        .torpedo => torpedo.run(ctx, index),
        else => if (state.step.isStyled()) letGo(ctx, index),
    }
}

/// OpenReliant's end of a launch it does not run, wherever the ship stands: it stops passing
/// through its carrier, as the Reliant's launch ends, and the launch ends (`finish`).
fn letGo(ctx: aigeneric.Context, index: u16) void {
    ctx.world.objects.slots[index].object.passes_through[0] = .none;
    finish(ctx, index);
}

/// A launch's end, as each style's last step has it: the ship's Launch order pops, and it can be
/// targeted again.
///
/// Not ported: the Launched event each style's end queues for the ship (`event_launched`,
/// `0x0045A9B0`, [#37](https://github.com/vdmkenny/openreliant/issues/37)).
pub fn finish(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.riding = null;
    _ = aigeneric.pop(ctx, index);
    ai.setTargetable(&slot.object, slot.combat, true);
}

/// `launch_start` (`0x00418DB0`): the first Launch among the orders of the ship in slot `index`
/// goes (`Data.go`), as StartLaunch has it; a ship with none is left as it is.
pub fn start(all: *create.Objects, index: u16) void {
    const slot = &all.slots[index];
    const count: usize = @intCast(@max(slot.object.order_count, 0));
    for (slot.orders[0..@min(count, slot.orders.len)]) |*entry| {
        if (entry.order != .launch) continue;
        entry.data.launch.go = true;
        return;
    }
}

/// Whether the ship in slot `index` drops out of its carrier's bay, or is about to: its current
/// order is Launch, in the Reliant's style, its tube's lower door opened (`reliant.Step.drop` and
/// on), as `camera_frame` reads the step for the bay's view.
pub fn dropping(all: *const create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    const entry = slot.current() orelse return false;
    if (entry.order != .launch) return false;
    const state = slot.state.launch;
    return state.style == .reliant and @intFromEnum(state.step) >= @intFromEnum(reliant.Step.drop);
}

/// `mission_frame`'s placing of a ship riding its node (`0x00492C14`), once a frame before the
/// ship's frame is drawn (`main.frameObjects`): where the current order of the ship in slot
/// `index` is Launch, its carrier is not exploding and the ship rides its node, it stands on the
/// node where its launch put it, turned as it was there.
pub fn hold(all: *create.Objects, index: u16) void {
    const slot = &all.slots[index];
    const entry = slot.current() orelse return;
    if (entry.order != .launch) return;
    const carrier = carrierOf(all, entry.target) orelse return;
    if (all.slots[carrier].object.flags.exploding) return;
    const state = &slot.state.launch;
    if (!state.attached) return;
    const node = (slot.riding orelse return).place(all) orelse return;
    const riding: math.Place = .{ .position = gameobj.vector(state.position), .orientation = state.orientation };
    const at = riding.within(node);
    objects.setPosition(&slot.object, &slot.drawn, at.position);
    objects.setOrientation(&slot.object, &slot.drawn, at.orientation);
}

// --- Launch points ------------------------------------------------------------------------------

/// A launch point, and the part that holds it.
pub const Point = struct {
    part: usize,
    attachment: *const shp.Attachment,
};

/// The launch points of a model (`launch_find_gate`, `launch_attach`): part by part as the root's
/// child list holds them, each part's attachments in order, of kind `launch_point`, or of kind
/// `pod` where the pod table holds no model at the part's own place.
///
/// **Quirk:** the game looks the pods up by the place of the part that holds the attachment,
/// rather than by the attachment's id, which names the pod it mounts.
pub const Points = struct {
    model: *const objects.Model,
    part: usize = 0,
    attachment: usize = 0,

    pub fn of(model: *const objects.Model) Points {
        return .{ .model = model };
    }

    pub fn next(points: *Points) ?Point {
        while (points.part < points.model.parts.len) : ({
            points.part += 1;
            points.attachment = 0;
        }) {
            const part = points.model.rootChild(points.part) orelse continue;
            while (points.attachment < part.attachments.len) {
                const at = &part.attachments[points.attachment];
                points.attachment += 1;
                if (isPoint(at.*, points.part)) return .{ .part = points.part, .attachment = at };
            }
        }
        return null;
    }

    fn isPoint(attachment: shp.Attachment, part: usize) bool {
        return switch (attachment.kind) {
            .launch_point => true,
            .pod => podless(part),
            else => false,
        };
    }

    /// Whether the pod table holds no model at `place` (`attachment_models`, kind 5), which past its
    /// ids reads on into the next kinds', none of which holds one.
    fn podless(place: usize) bool {
        const id = std.math.cast(u32, place) orelse return true;
        const entry = models.attachment(.pod, id) orelse return true;
        return entry.model == null;
    }
};

/// `launch_find_gate` (`0x00418DF0`), the search for a gate that `init` runs over each ship its
/// order's target names (`ai.eachShip`): each ship it visits becomes the carrier, its gate
/// starting again from 0, and each of the ship's launch points (`Points`) takes one off the
/// sequence, which counts on from ship to ship. The point that takes it below 0 ends the search,
/// its place among the ship's points the gate.
const GateSearch = struct {
    all: *const create.Objects,
    state: *State,

    pub fn visit(search: *GateSearch, carrier: aigeneric.Target) bool {
        const state = search.state;
        const index = carrierOf(search.all, carrier) orelse return false;
        state.carrier = index;
        state.gate = 0;
        const model = if (search.all.slots[index].model) |*held| held else return false;
        var points: Points = .of(model);
        while (points.next()) |_| {
            state.sequence -= 1;
            if (state.sequence < 0) return true;
            state.gate += 1;
        }
        return false;
    }
};

/// `launch_attach` (`0x0041B9F0`): places the ship in slot `index` at the launch point of the
/// object in slot `on` that its order's target names by its component, counting from 0 over the
/// object's points (`Points`): its centre of mass stands at the point, and it is turned as the
/// point is. The part holding the point becomes the node the ship rides (`State.node`,
/// `create.Slot.riding`). Where the object has no such point, the ship stays where it is.
pub fn attach(all: *create.Objects, index: u16, on: u16) void {
    const slot = &all.slots[index];
    const holder = &all.slots[on];
    const model = if (holder.model) |*held| held else return;
    var skip: i32 = slot.orders[0].target.component;
    var points: Points = .of(model);
    const point = while (points.next()) |found| {
        if (skip == 0) break found;
        skip -= 1;
    } else return;
    slot.riding = .{ .object = on, .part = point.part };
    const frame = model.frameAt(point.part, holder.drawn);
    const standing: math.Place = .{ .position = gameobj.vector(point.attachment.position), .orientation = point.attachment.orientation };
    const at = standing.within(frame);
    objects.setPosition(&slot.object, &slot.drawn, at.point(gameobj.vector(slot.object.centre)));
    objects.setOrientation(&slot.object, &slot.drawn, at.orientation);
}

test {
    std.testing.refAllDecls(@This());
}

test "Style.of" {
    // Torpedoes and escape pods go by their own type, whatever launches them.
    try std.testing.expectEqual(Style.torpedo, Style.of(.russian_torpedo, .reliant, 0));
    try std.testing.expectEqual(Style.other_escape_pod, Style.of(.other_escape_pod, .kamov, 0));
    // Any other ship by its carrier's.
    try std.testing.expectEqual(Style.reliant, Style.of(.predator, .reliant, 3));
    try std.testing.expectEqual(Style.badanov, Style.of(.sabre, .krasny, 0));
    try std.testing.expectEqual(Style.bay, Style.of(.sabre, .kiev, 0));
    // The rogue base's first six gates have a style of their own.
    try std.testing.expectEqual(Style.rogue_base, Style.of(.sabre, .rogue_base, 5));
    try std.testing.expectEqual(Style.bay, Style.of(.sabre, .rogue_base, 6));
    // Nothing launches from a fighter.
    try std.testing.expectEqual(null, Style.of(.sabre, .predator, 0));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("reliant", try std.fmt.bufPrint(&buffer, "{f}", .{Style.reliant}));
    try std.testing.expectEqualStrings("style 12", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Style, @enumFromInt(12))}));
}

/// Fixtures for the launches' tests.
pub const testing = struct {
    /// A carrier's model of three parts hanging from the root, 100 apart along X. The first holds
    /// no launch point, only a missile's hardpoint; the second two, 10 and 20 along Z, turned half a
    /// turn about Y, with a pod's between them, which the pod table has a model for at the second
    /// part's place; the third a pod's, which the table has none for at the third's. Set it up
    /// where it stays, as its records point into it.
    pub const Carrier = struct {
        attachments: [5]shp.Attachment,
        data: [3]shp.PartData,
        loaded_parts: [3]srofiles.LoadedPart,
        source: shp.Model,
        loaded: srofiles.Loaded,

        pub fn init(carrier: *Carrier) void {
            const kinds = [_]shp.Attachment.Kind{ .missile, .launch_point, .pod, .launch_point, .pod };
            const along = [_]f32{ 0, 10, 15, 20, 0 };
            for (&carrier.attachments, kinds, along) |*attachment, kind, z| {
                attachment.* = std.mem.zeroes(shp.Attachment);
                attachment.kind = kind;
                attachment.position = .{ .x = 0, .y = 0, .z = z };
                attachment.orientation = math.rotation(.y, std.math.pi);
            }
            carrier.data = @splat(objects.testing.part());
            for (&carrier.data, 0..) |*part, n| {
                part.part.parent = -1;
                part.part.position = .{ .x = @floatFromInt(100 * n), .y = 0, .z = 0 };
            }
            carrier.data[0].attachments = carrier.attachments[0..1];
            carrier.data[1].attachments = carrier.attachments[1..4];
            carrier.data[2].attachments = carrier.attachments[4..5];
            carrier.loaded_parts = @splat(.{ .flags = .{}, .levels = &.{}, .meshes = &.{} });
            carrier.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &carrier.data, .trailing_bytes = 0 };
            carrier.loaded = .{ .parts = &carrier.loaded_parts };
        }

        /// The carrier's model, its parts linked as `create_object` links them.
        pub fn model(carrier: *const Carrier, gpa: std.mem.Allocator) std.mem.Allocator.Error!objects.Model {
            var made: objects.Model = try .create(gpa, &carrier.source, &carrier.loaded, .{});
            for (0..made.parts.len) |index| gameobj.linkPart(&made, index);
            return made;
        }

        /// Gives the object in `slot` the carrier's model.
        pub fn fit(carrier: *const Carrier, gpa: std.mem.Allocator, slot: *create.Slot) std.mem.Allocator.Error!void {
            slot.model = try carrier.model(gpa);
        }
    };
};

test Points {
    var carrier: testing.Carrier = undefined;
    carrier.init();
    var model = try carrier.model(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    // The second part's two points, not the pod between them, which has a model at its place, and
    // the third's pod, which has none: a quirk of the game's.
    var points: Points = .of(&model);
    const expected = [_]struct { usize, f32 }{ .{ 1, 10 }, .{ 1, 20 }, .{ 2, 0 } };
    for (expected) |point| {
        const found = points.next().?;
        try std.testing.expectEqual(point[0], found.part);
        try std.testing.expectEqual(point[1], found.attachment.position.z);
    }
    try std.testing.expectEqual(null, points.next());
    // A part taken out of its model holds none.
    model.parts[1].removed = true;
    points = .of(&model);
    try std.testing.expectEqual(2, points.next().?.part);
}

test "a torpedo launches from its tube, riding it until it boosts away" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.kamov, .{ 1000, 0, 0 });
    try carrier_model.fit(gpa, mission.slot(carrier));
    mission.slot(carrier).object.velocity = .{ .x = 0, .y = 0, .z = 5 };
    const torpedo_slot = try mission.add(.torpedo, @splat(0));
    const ctx = mission.orders();

    // Through its second gate, the second part's second point: its centre there, turned as the
    // point is, riding the part, passing through the carrier and not to be targeted.
    _ = try aigeneric.pushShip(ctx, torpedo_slot, .launch, carrier, 1);
    mission.slot(torpedo_slot).object.flags.targetable = true;
    aigeneric.objectOrders(ctx, torpedo_slot);
    const slot = mission.slot(torpedo_slot);
    const state = &slot.state.launch;
    try std.testing.expectEqual(Style.torpedo, state.style);
    try std.testing.expectEqual(objects.NodeOf{ .object = carrier, .part = 1 }, slot.riding.?);
    try std.testing.expectEqual(math.Vector{ 1100, 0, 20 }, slot.drawn.position);
    try std.testing.expectApproxEqAbs(-1, math.forward(slot.drawn.orientation)[2], 1e-6);
    try std.testing.expect(state.attached and slot.object.flags.no_collisions);
    try std.testing.expectEqual(carrier, slot.object.passes_through[0].index());
    try std.testing.expect(!slot.object.flags.targetable);

    // It rides its node as the carrier moves.
    objects.setPosition(&mission.slot(carrier).object, &mission.slot(carrier).drawn, .{ 1000, 50, 0 });
    hold(mission.objects, torpedo_slot);
    try std.testing.expectEqual(math.Vector{ 1100, 50, 20 }, slot.drawn.position);

    // It waits until the launch starts, then a moment of up to two seconds.
    mission.clock.frame_start = 10;
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(Step.waiting, state.step);
    start(mission.objects, torpedo_slot);
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(Step.delaying, state.step);
    try std.testing.expect(state.due >= 10 and state.due < 10 + most_delay);

    // Past it, it leaves the tube, boosting at the carrier's velocity with nothing to ride.
    mission.clock.frame_start = state.due + 1;
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(@intFromEnum(torpedo.Step.boost), @intFromEnum(state.step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(2, slot.object.throttle);
    try std.testing.expectEqual(5, slot.object.velocity.z);

    // Once the boost is done, it flies itself, collides and can be targeted, its launch over.
    mission.clock.frame_start = state.due;
    aigeneric.objectOrders(ctx, torpedo_slot);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expect(!slot.object.flags.no_collisions);
    try std.testing.expectEqual(null, slot.riding);
    // It still passes through what launched it.
    try std.testing.expectEqual(carrier, slot.object.passes_through[0].index());
}

test "a launch's search for a gate counts the launch points on" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: testing.Carrier = undefined;
    carrier_model.init();
    const first = try mission.add(.kamov, @splat(0));
    const second = try mission.add(.kamov, .{ 5000, 0, 0 });
    for ([_]u16{ first, second }) |index| try carrier_model.fit(gpa, mission.slot(index));
    var state = std.mem.zeroes(State);
    var search: GateSearch = .{ .all = mission.objects, .state = &state };
    // The third order a command gave takes the first carrier's third point.
    state.sequence = 2;
    try std.testing.expect(search.visit(.at(first, null)));
    try std.testing.expectEqual(first, state.carrier);
    try std.testing.expectEqual(2, state.gate);
    // The fifth goes on to the second carrier's second, its count starting again there.
    state.sequence = 4;
    try std.testing.expect(!search.visit(.at(first, null)));
    try std.testing.expect(search.visit(.at(second, null)));
    try std.testing.expectEqual(second, state.carrier);
    try std.testing.expectEqual(1, state.gate);
}

test "a launch ends with its carrier, and a style not ported lets the ship go" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const yamato = try mission.add(.yamato, .{ 0, 0, 5000 });
    const ship = try mission.add(.sabre, .{ 0, 0, 5000 });
    const lost = try mission.add(.sabre, .{ 0, 0, 5000 });
    const ctx = mission.orders();
    for ([_]u16{ ship, lost }) |index| {
        _ = try aigeneric.pushShip(ctx, index, .launch, yamato, 0);
        aigeneric.objectOrders(ctx, index);
    }
    // The Yamato's style is not ported: the ship rides the Yamato's root until its launch begins,
    // then goes where it stands, through the Yamato no more.
    try std.testing.expectEqual(Style.yamato, mission.slot(ship).state.launch.style);
    try std.testing.expectEqual(objects.NodeOf{ .object = yamato }, mission.slot(ship).riding.?);
    start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    mission.clock.frame_start = mission.slot(ship).state.launch.due + 1;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.order_count);
    try std.testing.expectEqual(null, mission.slot(ship).object.passes_through[0].index());

    // A ship still waiting when its carrier explodes goes with it.
    mission.slot(yamato).object.flags.exploding = true;
    aigeneric.objectOrders(ctx, lost);
    try std.testing.expectEqual(ai.orders.Order.explode, mission.slot(lost).orders[0].order);
}

test dropping {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(!dropping(mission.objects, player));
    _ = try aigeneric.pushShip(mission.orders(), player, .launch, player, 0);
    const state = &mission.slot(player).state.launch;
    state.style = .reliant;
    state.step = @enumFromInt(@intFromEnum(reliant.Step.open));
    try std.testing.expect(!dropping(mission.objects, player));
    state.step = @enumFromInt(@intFromEnum(reliant.Step.drop));
    try std.testing.expect(dropping(mission.objects, player));
}
