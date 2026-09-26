//! A torpedo's launch from its tube (`launch_torpedo_init`, `0x0041A360`, and `launch_torpedo_run`,
//! `0x0041A390`), whatever launches it: it waits at one of its carrier's launch points, then boosts
//! away at twice its speed, trailing, before it flies itself.

const std = @import("std");
const log = std.log.scoped(.launch);

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const missiles = @import("../missiles.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");

/// A torpedo's launch steps, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// It leaves the tube.
    fire = 2,
    /// It boosts away, until its boost has lasted `boost_ticks`.
    boost = 3,
    _,
};

/// How long the boost lasts, in ticks (`0x0041A400`).
const boost_ticks = 200;

/// The throttle it boosts at (`0x0041A454`).
const boost_throttle: f32 = 2;

/// The sound it leaves the tube with, as loud as it goes (`0x0041A410`).
const fire_sound: sound3d.sounds.Sound = .missile10;

/// The look of its trail, a torpedo's (`0x0041A49C`).
const trail_look: missiles.Type = .torpedo;

/// `launch_torpedo_init` (`0x0041A360`): the torpedo in slot `index` collides with nothing, and
/// stands at the launch point of its carrier, in slot `carrier`, that its gate names
/// (`launch.attach`), riding the part that holds it.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const all = ctx.world.objects;
    all.slots[index].object.flags.no_collisions = true;
    launch.attach(all, index, carrier);
}

/// `launch_torpedo_run` (`0x0041A390`): as its launch reaches step 2, the torpedo in slot `index`
/// lets go of its tube, heard, and boosts away along its nose at `boost_throttle`
/// (`motion.Motion.plain`), steering nothing, from its carrier's velocity, trailing smoke as a
/// torpedo does. Once the boost has lasted `boost_ticks`, it flies itself, collides again, and
/// its launch ends (`launch.finish`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.clock.frame_start;
    switch (@as(Step, @enumFromInt(@intFromEnum(state.step)))) {
        .fire => {
            state.advance(@enumFromInt(@intFromEnum(Step.boost)), now, boost_ticks);
            state.attached = false;
            sound3d.playIn(world, null, null, index, fire_sound, 1, .not_reserved);
            const object = &slot.object;
            object.yaw_input = 0;
            object.pitch_input = 0;
            object.roll_input = 0;
            object.throttle = boost_throttle;
            slot.motion = .plain;
            if (slot.orders[0].target.slot()) |carrier| {
                if (carrier < all.slots.len) object.velocity = all.slots[carrier].object.velocity;
            }
            if (world.trails) |trails| _ = trails.start(world, .{ .object = index }, trail_look) catch |err| {
                log.warn("a torpedo's trail is left out: {s}", .{@errorName(err)});
            };
        },
        .boost => if (state.due <= now) {
            slot.motion = .forward;
            launch.finish(ctx, index);
            slot.object.flags.no_collisions = false;
        },
        _ => {},
    }
}
