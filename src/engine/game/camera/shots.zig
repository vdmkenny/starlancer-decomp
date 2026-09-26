//! The director's shots (`camera.cpp`): the shots a mission's script stacks for the director's
//! camera ([`director.zig`](../executor/director.zig)), which the camera shows one after another in
//! its view (`camera.View.director`), and the ships each holds still while it is on screen.
//!
//! **Unverified:** `0x0045EAD0` to `0x0045F170` lie before this file's known code, and `0x00461D30`
//! after it; they keep its globals.

const std = @import("std");

const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const director = @import("../executor/director.zig");
const gameobj = @import("../gameobj.zig");

/// A shot of the director's camera, as a script stacks it (`camera_shots`, 24 bytes each).
pub const Shot = struct {
    /// What the camera flies along or stands at (`+0x00`); null for neither.
    path: ?Path,
    /// The mission's ship the camera looks at, or null to turn by the path's angles (`+0x04`).
    tracked: ?u16 = null,
    /// How long it lasts, in seconds, which the director takes whole (`+0x08`).
    seconds: f32,
    /// The mission's ship the path rides along with (`+0x0C`); null for none.
    pace: ?u16 = null,
    /// The ships it holds still while it is on screen: a ship, a flight group or a squad (`+0x10`,
    /// `+0x14`); null for none.
    held: ?aigeneric.Target = null,

    pub const Path = union(enum) {
        /// A curve, by its index among the mission's curves, which the path starts along.
        curve: u16,
        /// A ship of the mission, where the camera stands.
        ship: u16,
    };
};

/// The shots waiting, the first on screen (`camera_shots`, `0x00539940`), `count` of them
/// (`camera_shot_count`, `0x00539A58`).
pub const Shots = struct {
    waiting: [capacity]Shot = undefined,
    count: usize = 0,

    /// The shots the table holds.
    pub const capacity = 10;

    /// The first shot, where one waits.
    pub fn first(shots: *const Shots) ?Shot {
        return if (shots.count > 0) shots.waiting[0] else null;
    }

    /// The first shot is over (`camera_frame`): the rest move up.
    pub fn pop(shots: *Shots) void {
        if (shots.count == 0) return;
        std.mem.copyForwards(Shot, shots.waiting[0 .. shots.count - 1], shots.waiting[1..shots.count]);
        shots.count -= 1;
    }
};

/// `camera_shot_stack` (`0x00461D30`): `shot` waits after the others, and where none waited begins
/// at once (`start`), in `world`, whose camera is `view`.
///
/// **Fix:** the game stacks a shot past the table's last over the globals after it; OpenReliant
/// passes over the shot.
pub fn stack(world: gameobj.World, view: *camera.Camera, shot: Shot) void {
    const shots = &view.shots;
    if (shots.count >= Shots.capacity) return;
    shots.waiting[shots.count] = shot;
    shots.count += 1;
    if (shots.count == 1) start(world, view);
}

/// `camera_shot_start` (`0x0045F170`): the first shot begins. The ships it holds wait for the
/// director's view to hold them (`camera_shot_hold_kind`, `0x00539A5C`, and
/// `camera_shot_hold_index`, `0x00539938`), and the director takes it (`director.begin`).
pub fn start(world: gameobj.World, view: *camera.Camera) void {
    const shot = view.shots.first() orelse return;
    view.holding = if (shot.held) |target| .of(world, target) else null;
    director.begin(world, view, shot);
}

/// The ships a shot holds still, and the objects they are in.
pub const Held = struct {
    objects: *create.Objects,
    ships: std.StaticBitSet(gameobj.max_objects) = .initEmpty(),

    /// The ships `target` names (`ai.eachShip`), as `camera_hold_ships` walks them: a ship, each
    /// ship of a flight group, and each of a squad's.
    pub fn of(world: gameobj.World, target: aigeneric.Target) Held {
        var held: Held = .{ .objects = world.objects };
        const Collect = struct {
            held: *Held,

            pub fn visit(collect: @This(), ship: aigeneric.Target) bool {
                const index = ship.ship() orelse return false;
                if (index < gameobj.max_objects) collect.held.ships.set(index);
                return false;
            }
        };
        _ = ai.eachShip(world, target, Collect{ .held = &held });
        return held;
    }

    /// `camera_hold_ships` (`0x0045EC40`, a squad's in `0x0045EAD0`): each ship is marked jumping,
    /// which holds it still and keeps it from firing, or is let go.
    pub fn hold(held: Held, on: bool) void {
        var ships = held.ships.iterator(.{});
        while (ships.next()) |index| held.objects.slots[index].object.flags.jumping = on;
    }
};

test Shots {
    var shots: Shots = .{};
    try std.testing.expectEqual(null, shots.first());
    for (0..3) |n| {
        shots.waiting[shots.count] = .{ .path = .{ .curve = @intCast(n) }, .seconds = 1 };
        shots.count += 1;
    }
    // The first shot over, the next is first.
    shots.pop();
    try std.testing.expectEqual(2, shots.count);
    try std.testing.expectEqual(Shot.Path{ .curve = 1 }, shots.first().?.path.?);
    shots.pop();
    shots.pop();
    shots.pop();
    try std.testing.expectEqual(0, shots.count);
}

test "a shot holds its ships still while it is on screen" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.addOther(@splat(0));
    const other = try mission.add(.predator, @splat(0));
    const held: Held = .of(mission.world(), .at(ship, null));
    held.hold(true);
    try std.testing.expect(mission.slot(ship).object.flags.jumping);
    try std.testing.expect(!mission.slot(other).object.flags.jumping);
    held.hold(false);
    try std.testing.expect(!mission.slot(ship).object.flags.jumping);
}
