//! `C:\lancer\game\collision.cpp`: what becomes of two objects that meet. `objects_update` finds
//! the pairs whose spheres overlap ([`create.zig`](create.zig)) and hands each to
//! `objects_collide`, which pushes them apart. `docs/engine/loop.md` describes the sweep.
//!
//! **Unverified:** this file's known code lies before `objects_collide`; what is ported here lies
//! between it and `Create.cpp`'s, which no string places.

const std = @import("std");

const dte = @import("../../formats/dte.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const events = @import("mission/events.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const main = @import("main.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const shield = @import("shield.zig");
const hud = @import("hud.zig");
const input = @import("../input.zig");
const camera = @import("camera.zig");

/// How far apart a collision sets two objects, as a share of each one's radius from the point
/// between them (`0x004DC7C0` and `0x004DC7C4`): a tenth further than touching, so that the next
/// step does not find them overlapping again.
pub const push_apart: f32 = 1.1;

/// `objects_collide` (`0x00466170`): what two objects whose spheres overlap do about it, and
/// whether they were moved, which has `objects_update` look again.
///
/// Two of one type never collide while a torpedo is one of them, nor do two torpedoes, two pieces
/// of debris or two satellites. A torpedo goes off against what it meets and a mine against a
/// fighter, instead of being pushed (`goOff`), and a ship that meets something which lists
/// components is tested against its parts. Anything else is pushed apart along the line between the
/// two, each to `push_apart` of its radius from the point between them, after both have moved
/// again.
///
/// Not ported: what a mine does in a multiplayer game, 5000 and the kill to its owner, and what the
/// destruction tells the other players, which are multiplayer's
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn collide(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    var near = first;
    var far = second;
    const near_class = className(all, near) orelse return false;
    const far_class = className(all, far) orelse return false;
    var classes: [2]create.ShipCombat.Class = .{ near_class, far_class };

    // A torpedo comes first, and never meets another object of its own type or one that is already
    // going off.
    if (classes[0] == .torpedo or classes[1] == .torpedo) {
        if (all.slots[near].object.type == all.slots[far].object.type) return false;
        if (classes[1] == .torpedo) {
            std.mem.swap(u16, &near, &far);
            std.mem.swap(create.ShipCombat.Class, &classes[0], &classes[1]);
        }
        if (all.slots[near].object.flags.exploding) return false;
    }

    const lists_components = all.slots[near].object.flags.components or all.slots[far].object.flags.components;
    if (lists_components) return parts(world, near, far, pass);

    // Two torpedoes and two pieces of debris pass through each other, as do two satellites.
    if (classes[0] == classes[1] and (classes[0] == .torpedo or classes[0] == .debris)) return false;
    // Two satellites never collide, whatever their class.
    if (all.slots[near].object.type == .satellite and all.slots[far].object.type == .satellite) return false;

    // A mine goes off against a fighter, and a torpedo against whatever it met.
    if (classes[0] == .mine or classes[1] == .mine) {
        if (classes[0] != .fighter and classes[1] != .fighter) return false;
        const mine, const fighter = if (classes[0] == .mine) .{ near, far } else .{ far, near };
        goOff(world, mine, fighter, mine_blow, .collision, false);
        return false;
    }
    if (classes[0] == .torpedo) {
        goOff(world, near, far, torpedo_blow, .crash, true);
        return true;
    }

    return push(world, near, far, pass);
}

/// What a torpedo does to what it meets, and a mine to a fighter.
const torpedo_blow: f32 = 5001;
const mine_blow: f32 = 500;

/// A torpedo or a mine in slot `from` going off against what it met in slot `struck`: `blow` to the
/// fore quadrant of what it met as `kind`, which is named its own attacker, and the torpedo or the
/// mine destroyed (`object_destroyed_net`, `0x00402100`), never spinning; a torpedo ejects no
/// pilot.
fn goOff(world: gameobj.World, from: u16, struck: u16, blow: f32, kind: Kind, no_eject: bool) void {
    damage(world, struck, .fore, blow, 1, struck, kind);
    ai.objectDestroyed(.{ .world = world, .clock = world.clock }, from, false, no_eject);
}

/// The class of the ship type in a slot, or null for an object with no stats, which the game would
/// follow a null pointer for.
fn className(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
    const combat = all.slots[index].combat orelse return null;
    return combat.class;
}

/// How hard the two come off each other (`0x004DC4A4`): the impulse carries twice the speed they
/// meet at, so the bounce keeps it.
const bounce: f32 = -2;

/// The speed a pair whose contact points are not closing is pushed apart at, for each pass the
/// sweep has already made (`0x004DC56C`), so a pair that keeps meeting is parted harder each time.
const resting_speed: f32 = 5;

/// `0x00464E80`: the shove two objects give each other where their spheres touch. The contact
/// point lies on the line between their centres, so neither is turned by it.
fn shove(world: gameobj.World, first: u16, second: u16, pass: u8) void {
    const all = world.objects;
    const near = all.slots[first].object.placeAt(.now);
    const far = all.slots[second].object.placeAt(.now);
    const apart = near.position - far.position;
    if (math.lengthSquared(apart) == 0) return;
    const toward = math.normalize(apart);
    const contact = far.position + toward * @as(Vector, @splat(all.slots[second].object.radius));
    const impulse = shoveAt(world, first, second, -toward, .{ near.inverse(contact), far.inverse(contact) }, pass) orelse return;
    impact(world, first, second, impulse, contact);
}

/// `0x00464E80` itself: the impulse where two objects meet. `normal` points from the first to the
/// second, and `levers` gives the contact point in each object's own frame. The impulse follows
/// how fast those points close between this step and the next, each object's mass and its
/// `angular_response`, and both take it through `knock`, equal and opposite. An object held to
/// another, and the Ripper carrying something, take none.
///
/// The move that follows applies the knocks, which is why a colliding pair moves again.
fn shoveAt(world: gameobj.World, first: u16, second: u16, normal: Vector, levers: [2]Vector, pass: u8) ?Vector {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;

    // Where each contact point stands now and where the step is taking it.
    const now: [2]Vector = .{ near.placeAt(.now).point(levers[0]), far.placeAt(.now).point(levers[1]) };
    const next: [2]Vector = .{ near.placeAt(.next).point(levers[0]), far.placeAt(.next).point(levers[1]) };
    var closing = (next[0] - now[0]) - (next[1] - now[1]);
    if (math.lengthSquared(closing) == 0 and far.flags.components) {
        closing = normal * @as(Vector, @splat(near.radius - math.distance(now[0], next[0])));
    }
    const speed = math.length(closing);
    if (math.dot(closing, normal) < 0 and speed > 0) {
        closing *= @as(Vector, @splat(-(1 + @as(f32, @floatFromInt(pass))) * resting_speed / speed));
    }

    var give: f32 = 0;
    for ([_]u16{ first, second }, now) |index, at| {
        if (!shoved(all, index)) continue;
        const object = &all.slots[index].object;
        const lever = at - gameobj.vector(object.root.position);
        const turn = math.transform(
            object.root.orientation,
            math.transform(object.angular_response, math.transformTransposed(object.root.orientation, math.cross(lever, normal))),
        );
        give += 1 / object.mass + math.dot(math.cross(turn, lever), normal);
    }
    // A tensor or a mass the arithmetic cannot hold would throw the pair across the sky.
    if (!(give > 0) or !std.math.isFinite(give)) return null;
    var force = normal * @as(Vector, @splat(math.dot(closing, normal) * bounce / give));
    if (@reduce(.And, force == @as(Vector, @splat(0)))) force = normal;
    if (!@reduce(.And, @abs(force) < @as(Vector, @splat(std.math.floatMax(f32))))) return null;
    for ([_]u16{ first, second }, now, 0..) |index, at, which| {
        if (!shoved(all, index)) continue;
        gameobj.knock(&all.slots[index].object, if (which == 0) force else -force, at);
    }
    return force;
}

/// Whether the object takes a shove at all: one held to another does not, nor does the Ripper while
/// it is carrying something.
///
/// **Improvement:** neither does an object of no mass, which the game would divide by, since a
/// model whose parts hold no volume leaves one.
fn shoved(all: *const create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.object.flags.attached or slot.object.mass <= 0) return false;
    if (slot.object.type != .ripper) return true;
    return slot.object.order_count == 0 or slot.orders[0].order != .ripper_grabs_target_object;
}

/// Both objects shove each other, move again, and are then set apart along the line between them
/// where they still overlap. The move applies the knocks the shove handed them, which is why it
/// runs again here.
fn push(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    shove(world, first, second, pass);
    for ([_]u16{ first, second }) |index| motion.moveSlot(world, index);
    const near = &all.slots[first];
    const far = &all.slots[second];
    if (!near.object.overlaps(&far.object, 0)) return true;

    const here = near.object.nextPosition();
    const there = far.object.nextPosition();
    const apart = math.normalize(here - there);
    const between = (here + there) * @as(Vector, @splat(0.5));
    objects.setPosition(&near.object, &near.drawn, between + apart * @as(Vector, @splat(near.object.radius * push_apart)));
    objects.setPosition(&far.object, &far.drawn, between - apart * @as(Vector, @splat(far.object.radius * push_apart)));
    return true;
}

/// What damage counts as (`0x00463EE0`'s last argument). Kinds 0, 1 and 5 count toward
/// `recent_damage` (`counted`); 3 and 4 wreck a component with armour to spare (`heavyKind`).
pub const Kind = enum(i32) {
    /// A shot from a gun (`guns.bulletHit`).
    bullet = 0,
    /// A missile's hit, but a Screamer's (`missiles.collide`), and what an Imp's shockwave does to
    /// the shields (`shockwave.Shockwave.strike`).
    missile = 1,
    collision = 2,
    /// What a torpedo does to what it meets, 5001 (`objects_collide`), and a ship to the component
    /// of a hull it dies crashing into, 5001 (`collision_test_hull`).
    crash = 3,
    /// **Unknown.** Also 5001 from a ship dying against a hull, to another part of the component's
    /// assembly (`collision_test_hull`).
    _unknown_4 = 4,
    /// A Screamer's hit.
    screamer = 5,
    _,
};

/// The quadrants an object's shields and armour are kept in, as `object_armor_conditions` reads
/// them.
pub const Quadrant = enum(u2) {
    left = 0,
    right = 1,
    fore = 2,
    aft = 3,
};

/// `0x00463CA0`: the quadrant a hit falls in, from where it lies in the object's frame as a share
/// of the object's bounds: whichever of along and across is the larger share decides.
pub fn quadrant(object: *const gameobj.GameObject, at: Vector) Quadrant {
    const across = at[0] / (object.bounds_max.x - object.bounds_min.x);
    const along = at[2] / (object.bounds_max.z - object.bounds_min.z);
    if (@abs(across) <= @abs(along)) return if (along <= 0) .aft else .fore;
    return if (across > 0) .right else .left;
}

/// How much of a collision's impulse becomes damage, over the lighter of the two masses
/// (`0x004DC3F8`), and the share of that an object takes (`0x004DC408`).
const impulse_share: f32 = 0.2;
const taken_share: f32 = 0.5;
const damage_share: f32 = impulse_share * taken_share;

/// What the damage is scaled by while either object is held to another (`0x004DC4AC`).
const attached_damage: f32 = 0.02;

/// What a player's ship does to a friendly one (`0x004DC3D4`).
const friendly_damage: f32 = 0.25;

/// `collision_damage` (`0x00465CA0`): the damage two objects do each other as they meet. It
/// follows the impulse the shove handed them, over the lighter of the two masses, and lands on the
/// quadrant each was struck in (`knockDamage`). The Ripper takes none.
fn impact(world: gameobj.World, first: u16, second: u16, impulse: Vector, contact: Vector) void {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;
    var value = math.length(impulse) * damage_share / @min(near.mass, far.mass);
    if (near.flags.attached or far.flags.attached) value *= attached_damage;

    for ([_]u16{ first, second }, [_]u16{ second, first }, [_]Flare{ .before, .after }) |index, other, flare| {
        const object = &all.slots[index].object;
        if (object.type == .ripper) continue;
        const struck = quadrant(object, object.placeAt(.now).inverse(contact));
        var share = value;
        // A player's ship is gentler with its own side.
        if (other == all.player and object.side == .friendly and index >= all.players) share *= friendly_damage;
        knockDamage(world, index, struck, share, share, other, contact, flare);
    }
}

/// When a knock's shield flares, as `shield.flare` checks the shields left: the game flares the
/// first of two objects that meet before its damage, and the second, and a ship meeting a hull,
/// after.
const Flare = enum { before, after };

/// What a knock does to one object (`collision_damage`, `collision_test_hull`): the player's shield
/// reserve in the quadrant struck is drawn by `drain` first, and while it holds, that is all. A
/// shield that is down leaves the armour to take `value`; one that is up takes it
/// (`object_damage`), and flares at `contact`.
fn knockDamage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, drain: f32, attacker: u16, contact: Vector, flare: Flare) void {
    const all = world.objects;
    const object = &all.slots[index].object;
    if (index == all.player and world.player.shield_reserves.spare(struck, drain)) return;
    if (object.shields.get(struck) < 0) return armorDamage(world, index, struck, value, attacker, .collision);
    if (flare == .before) shield.flare(world, index, contact);
    damage(world, index, struck, value, 1, attacker, .collision);
    if (flare == .after) shield.flare(world, index, contact);
}

/// The game's difficulty (`0x00562F14`), which SET GAME DIFFICULTY starts at medium and steps
/// through. It scales damage (`byDifficulty`).
pub const Difficulty = enum(i16) {
    easy = 0,
    medium = 1,
    hard = 2,
    _,

    /// How much harder a shot lands on a hostile object (`0x004DC4E0`, `0x004DC550`).
    fn onHostile(difficulty: Difficulty) f32 {
        return switch (difficulty) {
            .easy => 1.5,
            .hard => 0.75,
            else => 1,
        };
    }

    /// How much harder a hit lands on the player's ship, before `player_share`.
    fn onPlayer(difficulty: Difficulty) f32 {
        return switch (difficulty) {
            .easy => 0.75,
            .hard => 1.5,
            else => 1,
        };
    }
};

/// The share of a hit the player's ship takes, whatever the difficulty (`0x004DC408`).
const player_share: f32 = 0.5;

/// `damage_by_difficulty` (`0x00463D70`): damage as the difficulty scales it. A shot lands on a
/// hostile object harder the easier the game is, and anything that hits the player's ship lands
/// at half, then harder or softer by the difficulty: at medium, half as hard.
///
/// The game compares the damage's kind with the player's slot, which in a single-player game is 0,
/// a shot's kind; OpenReliant asks for a shot.
///
/// Not ported: multiplayer, where nothing is scaled.
pub fn byDifficulty(world: gameobj.World, index: u16, kind: Kind, value: f32) f32 {
    const all = world.objects;
    var scaled = value;
    if (kind == .bullet and all.slots[index].object.side == .hostile) scaled *= world.difficulty.onHostile();
    if (index == all.player) scaled *= world.difficulty.onPlayer() * player_share;
    return scaled;
}

/// `object_damage` (`0x00463EE0`): damage to an object, which its shields take first, as the
/// difficulty scales it. What passes through wears the armour instead, times `factor`, which every
/// caller here gives as 1; it is reckoned from the damage before the scaling, which the armour's
/// damage then does. A shield that is already down adds its own deficit to what passes through, and
/// an object in its last state (`Invulnerability._unknown_4`) keeps its shields. Damage of kinds 0,
/// 1 and 5 counts toward what the object has taken lately, which is what sends a ship after its
/// attacker.
///
/// With smart targeting on, a blow the player's ship deals, but by colliding, makes what it
/// struck the player's target (`input.setPlayerTarget`). A blow the player's ship takes shakes it
/// and its controller (`feedback`), and the display (`hud.Interference.start`). Last, the object's
/// ShotAt is posted (`shotAt`).
///
/// Not ported: the score a player's hit is worth, and what multiplayer makes of it.
pub fn damage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, factor: f32, attacker: u16, kind: Kind) void {
    const all = world.objects;
    const object = &all.slots[index].object;
    const held = object.shields.at(struck);
    const scaled = scaledBlow(world, index, struck, value, kind, held.* >= 0) orelse return;
    const through = @max(value - held.*, 0);
    if (held.* >= 0 and object.invulnerable != ._unknown_4) held.* -= scaled;
    if (held.* < 0) armorDamage(world, index, struck, through * factor, attacker, kind);
    object.last_attacker = .of(attacker);
    if (smartTargeting(world, attacker, kind)) |display| input.setPlayerTarget(display, all, @intCast(index), aigeneric.Target.whole, false);
    shotAt(world, index, attacker);
}

/// The ShotAt of a blow to the object in slot `index` by `attacker`, on the object itself
/// (`events.shotAt`), unless a collision's test against a hull runs again
/// (`events.Events.shots_held`).
fn shotAt(world: gameobj.World, index: u16, attacker: u16) void {
    if (world.events) |waiting| if (waiting.shots_held) return;
    events.shotAt(world, index, attacker, dte.Trigger.whole_object);
}

/// Holds back the ShotAt of the blows a collision deals, or lets it go again (`0x00545860`).
fn holdShots(world: gameobj.World, held: bool) void {
    if (world.events) |waiting| waiting.shots_held = held;
}

/// What `object_damage` and `object_armor_damage` both do first: a jumping object takes nothing,
/// and nor does debris, though a blow to the player's ship starts the display's interference
/// (`hud.Interference.start`) before that is known. Otherwise the blow, `value` as the difficulty
/// scales it, shakes the player's ship and its controller (`feedback`, where `shielded` says whether
/// the shields took it), and counts toward what the object has taken lately where its kind does.
/// Returns the scaled blow, or null where the object takes nothing.
fn scaledBlow(world: gameobj.World, index: u16, struck: Quadrant, value: f32, kind: Kind, shielded: bool) ?f32 {
    const all = world.objects;
    const slot = &all.slots[index];
    if (slot.object.flags.jumping) return null;
    if (index == all.player) if (world.display) |display| display.interference.start(world);
    if (slot.combat) |combat| if (combat.class == .debris) return null;
    const scaled = byDifficulty(world, index, kind, value);
    if (index == all.player) feedback(world, struck, kind, scaled, shielded);
    if (counted(kind)) slot.object.recent_damage += scaled;
    return scaled;
}

/// The display, while smart targeting is on and the blow is the player's ship's but for a
/// collision; null otherwise.
fn smartTargeting(world: gameobj.World, attacker: u16, kind: Kind) ?*hud.State {
    const display = world.display orelse return null;
    if (attacker != world.objects.player or !display.smart_targeting or kind == .collision) return null;
    return display;
}

/// `object_armor_damage` (`0x004641F0`): damage to an object's armour, once its shields are down.
/// The game scales it by the difficulty twice: once for what the object has taken lately, and that
/// again for the armour, so at medium the player's armour takes a quarter. An exploding object
/// takes no more, and a shot's damage to an object listing components goes to the component
/// instead (`componentDamage`). An invulnerable object takes it only while it leaves armour to
/// spare, and one in its last state (`Invulnerability._unknown_4`) not at all. The armour's
/// conditions follow it (`object_armor_conditions`), and armour below zero destroys the object
/// (`ai.objectDestroyed`), which may spin out; a blow heavier than `heavy_blow` leaves the player
/// no time to eject. Smart targeting makes what the player's ship struck, but by colliding, the
/// target of its current order. A hit on that target brings up its form of the target display,
/// and a hit on it or on the player's ship marks the quadrant struck for the ship status indicator
/// to flash (`hud.State.target_hits`, `ship_hits`). A blow the player's ship takes shakes it and
/// its controller (`feedback`), and the display (`hud.Interference.start`). Last, the object's
/// ShotAt is posted (`shotAt`); a shot's on an object listing components, at once, and even while a
/// collision's test against a hull runs again.
///
/// Not ported: what the player's hits on a friend tell the mission.
pub fn armorDamage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, attacker: u16, kind: Kind) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const scaled = scaledBlow(world, index, struck, value, kind, false) orelse return;
    if (object.flags.exploding) return;
    if (kind == .bullet and object.flags.components) return events.shotAt(world, index, attacker, dte.Trigger.whole_object);

    const shielded = object.invulnerable.protects(attacker < all.players);
    const worn = byDifficulty(world, index, kind, scaled);
    const armor = object.armor.at(struck);
    const left = armor.* - worn;
    const blocked = (left < 0 and shielded) or object.invulnerable == ._unknown_4;
    if (!blocked) armor.* = left;
    const taken = if (blocked) 0 else worn;
    if (slot.combat) |combat| {
        main.armorConditions(object, combat);
        if (index == all.player) if (world.hearing) |hearing| main.armorWarning(hearing, object, combat);
    }
    object.last_attacker = .of(attacker);
    if (armor.* < 0) ai.objectDestroyed(.{ .world = world, .clock = world.clock }, index, true, taken > heavy_blow);
    const current = &all.slots[all.player].orders[0].target;
    if (smartTargeting(world, attacker, kind) != null) current.index = @intCast(index);
    if (world.display) |display| {
        if (current.slot() == index) {
            _ = display.bringUp(hud.targetWindow(slot), false);
            display.target_hits.insert(struck);
        }
        if (index == all.player) display.ship_hits.insert(struck);
    }
    shotAt(world, index, attacker);
}

/// A blow to the armour heavier than this leaves the player's ship no time to eject (`0x004DC44C`).
const heavy_blow: f32 = 1000;

/// How much each point of a hit's damage shakes the camera (`0x004DC500`), and the most a shot
/// shakes it to.
const shake_per_damage: f32 = 0.05;
const shot_shake_most: f32 = 1;

/// `damage_feedback` (`0x00463E10`): a blow of `value` on the `struck` side of the player's ship,
/// after the difficulty's scaling, where the shields took it or not, while the controller rumbles.
/// A shot's starts the shake from hits on the controller (`input.force.Forces.startUnlessPlaying`)
/// and, while the camera shakes less than `shot_shake_most`, shakes it more by `shake_per_damage`
/// of the damage, up to that. Any other pushes the ship (`input.force.Forces.hit`) and shakes the
/// camera as much more, up to `camera.Cockpit.shake_most`.
///
/// **Improvement** (`input.force.HitShake.always`): the camera shakes whatever the controller.
///
/// **Improvement** (`input.force.Unread.played`): a collision plays `landhard`, any other blow the
/// shields take `Shield`, and one on the hull the `Hullshock` of the side struck.
fn feedback(world: gameobj.World, struck: Quadrant, kind: Kind, value: f32, shielded: bool) void {
    const forces = world.forces;
    const settings = if (forces) |playing| playing.settings else input.force.Settings{};
    const rumbles = if (forces) |playing| playing.feedback else false;
    if (rumbles or settings.hit_shake == .always) {
        const shake = world.shake;
        const more = value * shake_per_damage;
        if (kind == .bullet) {
            if (shake.* < shot_shake_most) shake.* = @min(shake.* + more, shot_shake_most);
        } else {
            shake.* = @min(shake.* + more, camera.Cockpit.shake_most);
        }
    }
    const playing = forces orelse return;
    const now = world.clock.frame_start;
    if (kind == .bullet) playing.startUnlessPlaying(.shake, now) else playing.hit(struck, value);
    const unread: input.force.Effect = switch (kind) {
        .collision, .crash => .landhard,
        else => if (shielded) .shield else switch (struck) {
            .left => .hullshock,
            .right => .hullshock1,
            .fore => .hullshock2,
            .aft => .hullshock3,
        },
    };
    playing.start(unread, now);
}

/// The damage kinds that hurt a component with armour to spare, whatever its flags.
fn heavyKind(kind: Kind) bool {
    return switch (kind) {
        .crash, ._unknown_4 => true,
        else => false,
    };
}

/// The armour past which a component takes only a heavy hit, and how heavy that is (`0x9C3` and
/// `0x004DC4A8`).
const heavy_component: i32 = 0x9C3;
const heavy_hit: f32 = 500;

/// What a shield generator leaves of a hit below `shielded_hit` (`0x004DC3D4` and `0x004DC44C`).
const shielded_damage: f32 = 0.25;
const shielded_hit: f32 = 1000;

/// `component_damage` (`0x004645C0`): damage to one of an object's components, as the difficulty
/// scales it. A collision does none; guns, missiles and explosions do. Where the component belongs
/// to an assembly, such as a turret and its barrels, the damage goes to the first part of it that
/// still has armour, and a component whose armour runs out marks its model's root as destroyed,
/// for `objects.loseComponents` to act on.
///
/// With smart targeting on, the player's hit on a hostile ship makes the component struck, if it
/// is one the ship lists, the player's target and subtarget, or else the ship alone, unless it is
/// already the target of the player's current order.
///
/// The part struck may be one of a model mounted on the object's: its assembly and its root are
/// that model's.
///
/// Last, whether or not the part took the hit, come the ShotAt events (`componentShotAt`).
///
/// Not ported: the invulnerability a component may carry, the score a player's hit is worth, and
/// what multiplayer makes of it.
pub fn componentDamage(world: gameobj.World, index: u16, struck_part: objects.PartRef, value: f32, attacker: u16, kind: Kind) void {
    const object = &world.objects.slots[index].object;
    if (object.flags.jumping or kind == .collision or struck_part.part().flags.damaged) return;
    wearComponent(world, index, struck_part, value, attacker, kind);
    componentShotAt(world, index, struck_part, attacker, kind);
}

/// `component_damage` (`0x00464A0A`)'s events for a hit on `struck_part`: the object's own ShotAt,
/// but for a hit of kind `_unknown_4`, then the ShotAt of the component the part counts against
/// (`objects.Model.countedAgainst`), where the object lists it (`create.Slot.componentIndex`), both
/// even while a collision's test against a hull runs again.
fn componentShotAt(world: gameobj.World, index: u16, struck_part: objects.PartRef, attacker: u16, kind: Kind) void {
    if (kind != ._unknown_4) events.shotAt(world, index, attacker, dte.Trigger.whole_object);
    const against = struck_part.model.countedAgainst(struck_part.index);
    const component = world.objects.slots[index].componentIndex(against) orelse return;
    events.shotAt(world, index, attacker, component);
}

/// What `component_damage` does to the component `struck_part` belongs to, as `componentDamage`
/// describes it.
fn wearComponent(world: gameobj.World, index: u16, struck_part: objects.PartRef, value: f32, attacker: u16, kind: Kind) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const model = struck_part.model;
    const component = struck_part.part();
    var share = byDifficulty(world, index, kind, value);

    // The assembly's first part that still has armour takes the hit.
    var struck = component;
    if (component.link_id != 0) {
        var each = model.assembly(component.link_id);
        while (each.next()) |at| {
            if (model.parts[at].component_armor <= 0) continue;
            struck = &model.parts[at];
            break;
        }
    }
    if (struck.component_armor == 0) return;
    // A part with armour to spare takes only a heavy hit, and only from what can hurt it.
    if (struck.component_armor > heavy_component) {
        if (share < heavy_hit) return;
        if (!struck.flags.lightmap and !heavyKind(kind)) return;
    }

    if (object.invulnerable != ._unknown_5 and object.flags.shield_generator and share < shielded_hit) share *= shielded_damage;
    const protected = object.invulnerable.protects(attacker < all.players);

    const left = struck.armor - share;
    if (left >= 0 or !protected) struck.armor = left;
    object.last_attacker = .of(attacker);
    if (struck.armor < 0) {
        model.destroyed = true;
    }
    const display = smartTargeting(world, attacker, kind) orelse return;
    if (object.side != .hostile) return;
    if (std.mem.indexOfScalar(?*objects.Model.Part, slot.listed(), struck)) |n| {
        input.setPlayerTarget(display, all, @intCast(index), @intCast(n), false);
    } else if (all.slots[all.player].orders[0].target.slot() != index) {
        input.setPlayerTarget(display, all, @intCast(index), aigeneric.Target.whole, false);
    }
}

/// Whether the damage counts toward what an object has taken lately, which `order_retaliate` reads.
fn counted(kind: Kind) bool {
    return switch (kind) {
        .bullet, .missile, .screamer => true,
        else => false,
    };
}

/// `0x00465C50`: a ship that meets an object listing components is tested against that object's
/// parts, not its sphere. The two are moved apart and tested again, up to nine times, the tests
/// after the first holding back the ShotAt of the knocks they deal (`holdShots`). Two objects that
/// both list components pass through each other, as does anything meeting the limpet pod.
fn parts(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    if (all.slots[first].object.flags.components and all.slots[second].object.flags.components) return false;
    if (all.slots[first].object.type == .limpet_pod or all.slots[second].object.type == .limpet_pod) return false;
    const hull = if (all.slots[first].object.flags.components) first else second;
    const ship = if (hull == first) second else first;

    var tries: u8 = 0;
    while (tries < hull_passes) : (tries += 1) {
        if (!hullHit(world, ship, hull, pass)) break;
        holdShots(world, false);
        for ([_]u16{ ship, hull }) |index| motion.moveSlot(world, index);
        holdShots(world, true);
    }
    holdShots(world, false);
    return tries > 0 and tries < hull_passes;
}

/// How many times a pair is tested against a hull before the sweep gives up on it.
const hull_passes = 9;

/// What a ship's shield reserve is drawn by for each point of damage a hull does it: the game draws
/// the reserve by the damage before the ship takes its share of it (`taken_share`).
const reserve_drain: f32 = 1 / taken_share;

/// `collision_test_hull` (`0x00465380`): the nearest face of the hull to the ship's sphere. The
/// ship is shoved at its own centre and the hull at the face, so the hull turns about the hit and
/// the ship does not. The ship takes the damage on the quadrant it was struck in
/// (`knockDamage`); its shield reserve is drawn by twice that, as the game halves the damage only
/// once it has drawn the reserve. A force field the ship hits glows whole (`shield.flareCapital`).
///
/// Not ported: what the hit destroys ([#42](https://github.com/vdmkenny/openreliant/issues/42)),
/// and a torpedo's hit, which damages the hull's own parts
/// ([#239](https://github.com/vdmkenny/openreliant/issues/239)). The game also tests the player's
/// ship against each part's trigger polygons first, which one shipped model carries.
fn hullHit(world: gameobj.World, ship: u16, hull: u16, pass: u8) bool {
    const all = world.objects;
    const model = if (all.slots[hull].model) |*live| live else return false;
    const object = &all.slots[hull].object;

    // The hull stands where this step is taking it, as the ship's sphere does.
    const at = all.slots[ship].object.nextPosition();
    const found = objects.hitSphere(model, object.placeAt(.next), at, all.slots[ship].object.radius) orelse return false;

    const contact = found.place.point(found.point);
    const normal = math.transform(found.place.orientation, found.normal);
    // The ship takes the shove at its own centre, the hull at the face it was hit on. The game
    // works the hull's lever out in the part's frame; OpenReliant uses the object's, which differs
    // only for a part its model animates.
    const lever = object.placeAt(.now).inverse(contact);
    const impulse = shoveAt(world, ship, hull, -normal, .{ @splat(0), lever }, pass) orelse return true;

    const hit = &all.slots[ship].object;
    const value = math.length(impulse) * damage_share / hit.mass;
    const struck = quadrant(hit, hit.placeAt(.now).inverse(contact));
    knockDamage(world, ship, struck, value, value * reserve_drain, hull, contact, .after);
    if (found.part.part().force_field) shield.flareCapital(world, hull, found.part, null);
    return true;
}

const testing = struct {
    /// An object at `at`, with a radius of its own and nothing flying it.
    fn ship(mission: *gameobj.testing.Mission, at: Vector, radius: f32) !u16 {
        const index = try mission.add(.predator, at);
        mission.slot(index).object.radius = radius;
        mission.slot(index).motion = null;
        return index;
    }
};

test collide {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // Two ships of 1000 units, 400 apart: each ends 1100 from the point between them.
    const near = try testing.ship(&mission, .{ -200, 0, 0 }, 1000);
    const far = try testing.ship(&mission, .{ 200, 0, 0 }, 1000);
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].object.root.position.x, 0.01);
    try std.testing.expectApproxEqAbs(1100, all.slots[far].object.root.position.x, 0.01);
    // What is drawn moves with them.
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].drawn.position[0], 0.01);

    // Once they are clear of each other, nothing moves them.
    const held = all.slots[near].object.root.position.x;
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(held, all.slots[near].object.root.position.x);
}

test "a collision shoves both ships" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // Two ships of the same mass, the first flying into the second.
    const near = try testing.ship(&mission, .{ -900, 0, 0 }, 1000);
    const far = try testing.ship(&mission, .{ 900, 0, 0 }, 1000);
    for ([_]u16{ near, far }) |index| {
        all.slots[index].object.mass = 1000;
        all.slots[index].object.angular_response = math.identity;
    }
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    all.slots[near].object.root.next_position = .{ .x = -800, .y = 0, .z = 0 };

    try std.testing.expect(collide(world, near, far, 0));
    // The one that ran in is thrown back, and the one it struck is pushed on.
    try std.testing.expect(all.slots[near].object.velocity.x < 100);
    try std.testing.expect(all.slots[far].object.velocity.x > 0);
    // What one takes, the other gives: the two shares of the momentum match.
    const given = 100 - all.slots[near].object.velocity.x;
    try std.testing.expectApproxEqAbs(given, all.slots[far].object.velocity.x, 1e-3);
    // Neither is set spinning: the point two spheres meet at lies on the line between their
    // centres, so the shove has no lever to turn them by. A hull's own faces do (#143).
    try std.testing.expectEqual(0, all.slots[near].object.rotation[1]);
    try std.testing.expectEqual(0, all.slots[far].object.rotation[1]);

    // An object held to another takes no shove.
    all.slots[far].object.flags.attached = true;
    all.slots[far].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    objects.setPosition(&all.slots[near].object, &all.slots[near].drawn, .{ -900, 0, 0 });
    objects.setPosition(&all.slots[far].object, &all.slots[far].drawn, .{ 900, 0, 0 });
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[far].object.velocity.x);
}

test "a ship that meets a hull is shoved off the face it hit" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();
    const world = mission.world();

    // A hull of one square part, and a ship flying into its face.
    // The inverse inertia of a body of this mass, about 6 / (mass * size squared), which is what
    // `recentre` works out from a model's parts.
    const hull_turn: math.Matrix = @splat(0);
    const hull = try create.createObject(all, &mission.tables, model.types(), null, .predator, 0, @splat(0), &mission.random);
    all.slots[hull].object.flags.components = true;
    all.slots[hull].object.mass = 100000;
    all.slots[hull].object.angular_response = hull_turn;
    all.slots[hull].object.angular_response[0] = 6e-9;
    all.slots[hull].object.angular_response[4] = 6e-9;
    all.slots[hull].object.angular_response[8] = 6e-9;
    all.slots[hull].motion = null;
    // The ship meets the face off to one side, so the hit has a lever on the hull.
    const ship = try mission.add(.predator, .{ 60, 0, -60 });
    all.slots[ship].object.radius = 100;
    all.slots[ship].object.mass = 1000;
    all.slots[ship].object.angular_response = .{ 6e-7, 0, 0, 0, 6e-7, 0, 0, 0, 6e-7 };
    all.slots[ship].motion = null;
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    all.slots[ship].object.root.next_position = .{ .x = 60, .y = 0, .z = -20 };

    try std.testing.expect(collide(world, ship, hull, 0));
    // It is thrown back off the face, which faces along -Z, and the hull is pushed the other way.
    try std.testing.expect(all.slots[ship].object.velocity.z < 40);
    try std.testing.expect(all.slots[hull].object.velocity.z > 0);
    // The hull turns about the hit, which the ship does not: it is shoved at its own centre.
    try std.testing.expect(all.slots[hull].object.yaw_rate != 0 or all.slots[hull].object.pitch_rate != 0);
    try std.testing.expectEqual(0, all.slots[ship].object.yaw_rate);

    // A ship nowhere near the hull meets nothing.
    objects.setPosition(&all.slots[ship].object, &all.slots[ship].drawn, .{ 0, 0, -5000 });
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    try std.testing.expect(!collide(world, ship, hull, 0));

    // Two hulls pass through each other.
    all.slots[ship].object.flags.components = true;
    try std.testing.expect(!collide(world, ship, hull, 0));
}

test damage {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    // The player's ship, in the first slot, and another, which the difficulty leaves alone.
    _ = try mission.add(.predator, @splat(0));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.shields = .{ .left = 10, .right = 10, .fore = 10, .aft = 10 };
    object.armor = .{ .left = 20, .right = 20, .fore = 20, .aft = 20 };

    // The shield takes it first.
    damage(world, index, .fore, 4, 1, 1, .collision);
    try std.testing.expectEqual(6, object.shields.fore);
    try std.testing.expectEqual(20, object.armor.fore);
    try std.testing.expectEqual(1, object.last_attacker.index());

    // Past the shield, the rest wears the armour, and the armour's conditions follow.
    damage(world, index, .fore, 10, 1, 1, .collision);
    try std.testing.expect(object.shields.fore < 0);
    try std.testing.expectEqual(16, object.armor.fore);
    try std.testing.expect(object.gun_condition < 1);

    // A collision is not what sends a ship after its attacker; a shot is. What passes a shield
    // that is already down carries the shield's deficit with it, so the armour takes both.
    try std.testing.expectEqual(0, object.recent_damage);
    damage(world, index, .fore, 1, 1, 1, .bullet);
    try std.testing.expectEqual(6, object.recent_damage);

    // Debris takes none, and neither does a ship that is jumping.
    const left = object.armor.fore;
    mission.tables.combat[0].class = .debris;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor.fore);
    mission.tables.combat[0].class = .fighter;
    object.flags.jumping = true;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor.fore);
}

test "smart targeting takes what the player's ship hits" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try @import("aigeneric.zig").push(mission.orders(), player, .player_control, .none));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.flags.targetable = true;
    object.shields = .all(100);
    var display: hud.State = .{};
    var world = mission.world();
    world.display = &display;
    const target = &all.slots[player].orders[0].target;

    // Off, a shot takes nothing.
    damage(world, index, .fore, 1, 1, player, .bullet);
    try std.testing.expectEqual(-1, target.index);
    // On, a collision takes nothing either, and another's shot nothing.
    display.smart_targeting = true;
    damage(world, index, .fore, 1, 1, player, .collision);
    damage(world, index, .fore, 1, 1, index, .bullet);
    try std.testing.expectEqual(-1, target.index);
    // The player's shot makes it the target, and brings up the target display.
    damage(world, index, .fore, 1, 1, player, .bullet);
    try std.testing.expectEqual(@as(i32, index), target.index);
    try std.testing.expectEqual(index, display.target.?);
    try std.testing.expect(display.windows.up(.target));

    // Past its shields, a hit on the target marks the quadrant it wore, for the target display;
    // one on the player's ship marks the player's.
    armorDamage(world, index, .left, 1, player, .bullet);
    try std.testing.expect(display.target_hits.contains(.left));
    try std.testing.expect(!display.target_hits.contains(.fore));
    all.slots[player].object.armor = .all(100);
    armorDamage(world, player, .aft, 1, index, .bullet);
    try std.testing.expect(display.ship_hits.contains(.aft));
}

test knockDamage {
    const gpa = std.testing.allocator;
    var built: shield.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shields = &built.shields;
    const player = try testing.ship(&mission, @splat(0), 100);
    const other = try testing.ship(&mission, .{ 0, 0, 1000 }, 100);
    const object = &mission.slot(player).object;
    const bubble = mission.slot(player).shield.?;
    object.shields = .all(50);
    object.armor = .all(50);
    mission.player.shield_reserves = .{ .fore = 20, .aft = 0 };

    // The fore reserve takes the knock while it holds, and nothing else happens.
    knockDamage(world, player, .fore, 10, 10, other, .{ 0, 0, 100 }, .after);
    try std.testing.expectEqual(10, mission.player.shield_reserves.fore);
    try std.testing.expectEqual(50, object.shields.fore);
    try std.testing.expectEqual(null, bubble.struck);
    // Once it runs out, the shield takes the whole knock, halved at medium, and flares.
    knockDamage(world, player, .fore, 30, 30, other, .{ 0, 0, 100 }, .after);
    try std.testing.expectEqual(0, mission.player.shield_reserves.fore);
    try std.testing.expectEqual(35, object.shields.fore);
    try std.testing.expectEqual(mission.clock.frame_start, bubble.struck);
    // With the shield down the armour takes it, twice halved, and nothing flares.
    bubble.struck = null;
    object.shields.aft = -1;
    knockDamage(world, player, .aft, 40, 40, other, .{ 0, 0, -100 }, .after);
    try std.testing.expectEqual(40, object.armor.aft);
    try std.testing.expectEqual(null, bubble.struck);
}

test armorDamage {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    // The player's ship, in the first slot, and another.
    _ = try mission.add(.predator, @splat(0));
    const index = try testing.ship(&mission, .{ 0, 0, 1000 }, 1000);
    const object = &all.slots[index].object;
    object.armor = .{ .left = 20, .right = 20, .fore = 20, .aft = 20 };

    // An invulnerable ship takes what it has armour to spare for, and no more.
    object.invulnerable = .full;
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expectEqual(5, object.armor.fore);
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expectEqual(5, object.armor.fore);
    try std.testing.expect(!object.flags.exploding);

    // Armour below zero destroys it.
    object.invulnerable = .none;
    armorDamage(world, index, .fore, 15, 0, .bullet);
    try std.testing.expect(object.flags.exploding);
    try std.testing.expectEqual(.explode, all.slots[index].orders[0].order);
    try std.testing.expect(all.slots[index].orders[0].data.destroyed.may_spin);
}

test byDifficulty {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    var world = mission.world();
    const player = try mission.add(.predator, @splat(0));
    const enemy = try mission.add(.sabre, .{ 0, 0, 1000 });
    try std.testing.expectEqual(.hostile, all.slots[enemy].object.side);

    // At medium, the player's ship takes half, and nothing else changes.
    try std.testing.expectEqual(50, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(50, byDifficulty(world, player, .collision, 100));
    try std.testing.expectEqual(100, byDifficulty(world, enemy, .bullet, 100));
    // Easy: the player's ship takes three eighths, and a shot lands harder on the enemy.
    world.difficulty = .easy;
    try std.testing.expectEqual(37.5, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(150, byDifficulty(world, enemy, .bullet, 100));
    try std.testing.expectEqual(100, byDifficulty(world, enemy, .collision, 100));
    // Hard: three quarters on the player's ship, and a shot lands softer on the enemy.
    world.difficulty = .hard;
    try std.testing.expectEqual(75, byDifficulty(world, player, .bullet, 100));
    try std.testing.expectEqual(75, byDifficulty(world, enemy, .bullet, 100));

    // The armour's damage scales it twice: at medium the player's armour takes a quarter, and what
    // it has taken lately counts half.
    world.difficulty = .medium;
    const object = &all.slots[player].object;
    object.armor = .all(100);
    armorDamage(world, player, .fore, 40, enemy, .bullet);
    try std.testing.expectEqual(90, object.armor.fore);
    try std.testing.expectEqual(20, object.recent_damage);
}

test quadrant {
    var object = gameobj.testing.object();
    object.bounds_min = .{ .x = -100, .y = -50, .z = -400 };
    object.bounds_max = .{ .x = 100, .y = 50, .z = 400 };
    // Along the ship counts for more than across it, so the nose and tail win the middle ground.
    try std.testing.expectEqual(.fore, quadrant(&object, .{ 0, 0, 300 }));
    try std.testing.expectEqual(.aft, quadrant(&object, .{ 0, 0, -300 }));
    try std.testing.expectEqual(.right, quadrant(&object, .{ 90, 0, 10 }));
    try std.testing.expectEqual(.left, quadrant(&object, .{ -90, 0, 10 }));
}

test componentDamage {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.data[0].part.flags.component = true;
    model.data[0].part.component_armor = 100;
    const world = mission.world();

    // The player's ship, in the first slot, and another, which the difficulty leaves alone. The
    // player's is of another type, whose model the test's types don't give.
    _ = try mission.add(.kamov, @splat(0));
    const index = try create.createObject(all, &mission.tables, model.types(), null, .predator, 0, @splat(0), &mission.random);
    const part = &all.slots[index].model.?.parts[0];
    const struck: objects.PartRef = .{ .model = &all.slots[index].model.?, .index = 0 };
    try std.testing.expectEqual(100, part.armor);

    // A collision does none, whatever it lands on.
    componentDamage(world, index, struck, 40, 1, .collision);
    try std.testing.expectEqual(100, part.armor);

    // A shot wears it down, and the attacker is recorded.
    componentDamage(world, index, struck, 40, 1, .bullet);
    try std.testing.expectEqual(60, part.armor);
    try std.testing.expectEqual(1, all.slots[index].object.last_attacker.index());

    // Past its armour, its model's root is marked destroyed.
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expect(part.armor < 0);
    try std.testing.expect(all.slots[index].model.?.destroyed);

    // A part with armour to spare takes only a heavy hit of a kind that can hurt it.
    part.component_armor = 20000;
    part.armor = 20000;
    componentDamage(world, index, struck, 100, 1, .bullet);
    try std.testing.expectEqual(20000, part.armor);
    componentDamage(world, index, struck, 600, 1, .crash);
    try std.testing.expectEqual(19400, part.armor);
}

test goOff {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();
    _ = try mission.add(.predator, .{ 0, 0, -100000 });

    // The test's stats make every type a fighter; a torpedo, of a type of its own, strikes one's
    // fore quadrant and goes off itself.
    const ship = try testing.ship(&mission, @splat(0), 1000);
    const torpedo = try testing.ship(&mission, .{ 100, 0, 0 }, 1000);
    mission.tables.combat[1].class = .torpedo;
    all.slots[torpedo].object.type = @enumFromInt(1);
    all.slots[torpedo].combat = &mission.tables.combat[1];
    const shielded = all.slots[ship].object.shields.fore;
    try std.testing.expect(collide(world, ship, torpedo, 0));
    try std.testing.expect(all.slots[ship].object.shields.fore < shielded);
    try std.testing.expectEqual(ship, all.slots[ship].object.last_attacker.index());
    try std.testing.expectEqual(.explode, aigeneric.current(all, torpedo).?.order);

    // A mine goes off against a fighter, which is not pushed.
    const mine = try testing.ship(&mission, .{ 0, 100, 0 }, 1000);
    mission.tables.combat[2].class = .mine;
    all.slots[mine].object.type = @enumFromInt(2);
    all.slots[mine].combat = &mission.tables.combat[2];
    all.slots[ship].object.shields.fore = 1000;
    try std.testing.expect(!collide(world, ship, mine, 0));
    try std.testing.expectApproxEqAbs(1000 - mine_blow, all.slots[ship].object.shields.fore, 1);
    try std.testing.expectEqual(.explode, aigeneric.current(all, mine).?.order);
    try std.testing.expectEqual(0, all.slots[ship].object.root.position.x);
}

test "what never collides" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // The test's stats make every type a fighter; two pieces of debris pass through each other.
    const near = try testing.ship(&mission, @splat(0), 1000);
    const far = try testing.ship(&mission, .{ 100, 0, 0 }, 1000);
    mission.tables.combat[0].class = .debris;
    try std.testing.expect(!collide(world, near, far, 0));

    // So do a torpedo and another object of its own type.
    mission.tables.combat[0].class = .torpedo;
    try std.testing.expect(!collide(world, near, far, 0));

    // A torpedo of another type goes off against it instead of pushing it.
    mission.tables.combat[1].class = .fighter;
    all.slots[far].object.type = @enumFromInt(1);
    all.slots[far].combat = &mission.tables.combat[1];
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);

    // An object that lists components is met by its parts, which aren't ported, so nothing comes
    // of it.
    mission.tables.combat[0].class = .fighter;
    all.slots[far].object.flags.components = true;
    try std.testing.expect(!collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);
}
