//! `C:\lancer\game\objects.cpp`: the hierarchy of nodes each live object embeds, one for each part
//! of its model.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const Frame = srapiext.Frame;
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;
const srofiles = @import("srofiles.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("matmanager.zig");
const create = @import("create.zig");
const environfx = @import("environfx.zig");
const libcmt = @import("../libcmt.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;
const aigeneric = @import("aigeneric.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const sound3d = @import("sound3d.zig");
const shield = @import("shield.zig");
const flash = @import("guns/flash.zig");
const cloak = @import("cloak.zig");
const Vector = math.Vector;

/// A node of an object's model hierarchy (`objects.cpp`), allocated at `0x004991D0`: the object's
/// root, then a node for each part of its model.
pub const Node = extern struct {
    /// What the node draws.
    kind: Kind,
    flags: Flags,
    /// The node's transform for the renderer, which holds the same place as `position` and
    /// `orientation`.
    frame: Pointer(Frame),
    _unknown_0c: u32,
    /// The capital shield showing on it, a slot of `capshields` (`capshield_create`); -1 for none,
    /// as allocated.
    capshield: i32,
    /// Relative to the node it hangs from: a part's origin in its parent part. An object's root
    /// holds the object's place in the world.
    position: shp.Vec3,
    /// Row-major 3x3, relative like `position`.
    orientation: [9]f32,
    /// The pose `node_place` placed a part's node by, committed with its place.
    pose: Pose,
    /// Where `position` goes next: `object_move` puts the position plus the velocity here, and
    /// placing an object sets both. `node_tree_update` (`updateTree`) and `object_link_part` copy
    /// it into `position`, and `node_place` works it out for a part's node.
    next_position: shp.Vec3,
    /// Likewise for `orientation`: `object_move` puts the orientation times the rotation here.
    next_orientation: [9]f32,
    /// The pose `node_place` worked the next place of a part's node out from: the animation's
    /// angles plus the turret's, and the animation's offset.
    next_pose: Pose,
    /// The model part the node stands for, as loaded.
    part: Pointer(shp.Part),
    /// The object the node belongs to.
    owner: Pointer(GameObject),
    _unknown_ac: [8]u8,
    /// How the node plays its animation track.
    mode: Model.Mode,
    /// Which of the part's animation tracks the node runs, and where `node_animate` reads its
    /// keyframes; past the part's tracks, the node is not animated.
    animation: i32,
    /// Where the node is in its track, and how far it moves on each simulation step.
    time: f32,
    speed: f32,
    /// Where the animation has the node turned, added to the part's own angles (`node_animate`).
    animated_angles: shp.Vec3,
    /// Where the animation has the node moved, added to its part's origin.
    animated_offset: shp.Vec3,
    /// The angles a turret turns the node by besides the animation's (`node_turn`), which
    /// `node_place` adds to them.
    angles: shp.Vec3,
    /// A component's counterpart of `GameObject.armor`, which `ship_damage_value` reads for it.
    armor: f32,
    /// The node it hangs from; null for a root. The root's `owner` is the object's.
    parent: Pointer(Node),
    _unknown_f0: u32,
    /// Children the list at `children` can hold: 100 once allocated.
    child_capacity: i32,
    child_count: i32,
    /// Its number among the object's part nodes (`object_number_parts`), for an object that lists
    /// components; -1 when allocated.
    number: i32,
    children: Pointer(Pointer(Node)),

    /// What a node draws, which `node_draw` (`0x0049A8C0`) switches on, as the routine that makes
    /// it gives it (`node_alloc`, `0x004991D0`).
    pub const Kind = enum(u32) {
        /// A model part (`node_add_part`).
        part = 1,
        /// An engine glow, which brightens with the throttle (`node_mount_glow`, `0x00499540`).
        glow = 2,
        /// A light's two sprites (`node_mount_light`, `Model.Light`).
        light_sprites = 3,
        /// A gun muzzle's flash (`node_mount_muzzle`, `0x00499680`; `muzzle_flash_draw`,
        /// `0x0047BA80`).
        muzzle = 4,
        /// The point light a blinking light casts (`node_mount_light`, `Model.Light`).
        point_light = 5,
        /// What a hit leaves where it struck (`node_add_effect`, `0x004992D0`; `shieldfx.zig`).
        hit = 6,
        _,

        pub fn format(kind: Kind, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return switch (kind) {
                _ => writer.print("node kind {d}", .{@intFromEnum(kind)}),
                inline else => |named| writer.writeAll(@tagName(named)),
            };
        }
    };

    pub const Flags = packed struct(u32) {
        /// Set while the node's next place is waiting to be committed. `object_move` sets it on an
        /// object's root; `node_tree_update` commits the place and clears it (`commitNext`), and
        /// `object_link_part` clears it along with the next three bits.
        next_pending: bool,
        /// Set when `node_tree_update` commits a new place for the node, and cleared the next time
        /// it visits the node. While it's set, `node_frame_update` draws the node between that
        /// place and the next.
        committed: bool,
        /// Set with `committed`, and cleared by `node_frame_update`.
        unframed: bool,
        /// Set by `node_place`, and cleared each time `node_tree_update` visits the node: the next
        /// place comes from a pose, which `node_frame_update` draws the node between the poses by.
        posed: bool,
        /// **Unknown.** Set by `node_draw` (`0x0049A8C0`). Cycling subtargets passes over a
        /// component with it.
        _unknown_4: bool,
        /// Hidden, as a component's damaged parts are while it is intact.
        hidden: bool,
        /// Set on a component's holder once `component_damage` takes the component's armor below
        /// zero.
        destroyed: bool,
        /// **Unknown.** Set on the nodes that `0x004992D0`, `0x00499540`, `0x00499680` and
        /// `0x00499730` make.
        _unknown_7: bool,
        /// Listed among the object's components.
        component: bool,
        /// **Unknown.** `create_object` sets it on the root.
        _unknown_9: bool,
        /// The base of a turret, which the turret fits mark (`turret_fit_aimed`); destroying the
        /// node stops the turret's gun for good (`node_forget`, `0x00499BB0`).
        turret: bool,
        /// Set while the node or one hanging from it plays an animation track: `node_play` sets it
        /// up to the root, and `node_tree_update` descends only into children that have it.
        animating: bool,
        _unknown_12: bool,
        /// A component the player can pick as a subtarget: set for parts with the `targetable`
        /// flag, and by `SetTargetable`.
        targetable: bool,
        _unknown_14: u18,
    };

    /// The first step of `node_tree_update` for a node: clears flag bits 1 and 3, and if the
    /// node's next place is pending, commits it. The game copies the whole block from
    /// `next_position` to the end of `next_pose` over the block from `position` to the end of
    /// `pose`, then clears `next_pending` and sets `committed` and `unframed`.
    pub fn commitNext(node: *Node) void {
        node.flags.committed = false;
        node.flags.posed = false;
        if (!node.flags.next_pending) return;
        node.position = node.next_position;
        node.orientation = node.next_orientation;
        node.pose = node.next_pose;
        node.flags.next_pending = false;
        node.flags.committed = true;
        node.flags.unframed = true;
    }

    /// A part node's pose: the animation's angles plus the turret's, and its offset.
    pub const Pose = extern struct {
        angles: shp.Vec3,
        offset: shp.Vec3,

        comptime {
            assert(@offsetOf(Pose, "angles") == 0x00);
            assert(@offsetOf(Pose, "offset") == 0x0C);
            assert(@sizeOf(Pose) == 0x18);
        }
    };

    /// `node_frame_update` (`0x0049A460`) for an object's root, once a frame before it is drawn,
    /// `fraction` of the way through the simulation's step: where the object is drawn and what
    /// the camera follows. Once a step has committed a new place, the root is drawn between that
    /// place and the next, along the straight line between them and turned by that share of the
    /// turn between; at the start of a step, at the committed place. Null where the frame stays
    /// where it was, until the first step moves the object. A root is never posed, since
    /// `node_place` places part nodes alone.
    ///
    /// Not ported: in a multiplayer game, another player's ship, whose root has flag bit 9, is
    /// drawn between the places its last two messages gave it (`+0x768`, `+0x798`).
    pub fn framePlace(node: *Node, fraction: f32) ?Model.Local {
        if (!node.flags.committed and !node.flags.unframed) return null;
        node.flags.unframed = false;
        const now: Model.Local = .{ .position = gameobj.vector(node.position), .orientation = node.orientation };
        if (fraction == 0) return now;
        const next: Model.Local = .{ .position = gameobj.vector(node.next_position), .orientation = node.next_orientation };
        return between(now, next, fraction);
    }

    comptime {
        assert(@offsetOf(Node, "next_position") - @offsetOf(Node, "position") == 0x48);
        assert(@offsetOf(Node, "part") - @offsetOf(Node, "next_position") == 0x48);
        assert(@bitOffsetOf(Flags, "hidden") == 5);
        assert(@bitOffsetOf(Flags, "component") == 8);
        assert(@bitOffsetOf(Flags, "targetable") == 13);
        assert(@bitOffsetOf(Flags, "posed") == 3);
        assert(@bitOffsetOf(Flags, "animating") == 11);
        assert(@bitOffsetOf(Flags, "turret") == 10);
        assert(@offsetOf(Node, "kind") == 0x00);
        assert(@offsetOf(Node, "position") == 0x14);
        assert(@offsetOf(Node, "pose") == 0x44);
        assert(@offsetOf(Node, "next_pose") == 0x8C);
        assert(@offsetOf(Node, "mode") == 0xB4);
        assert(@offsetOf(Node, "time") == 0xBC);
        assert(@offsetOf(Node, "speed") == 0xC0);
        assert(@offsetOf(Node, "animated_angles") == 0xC4);
        assert(@offsetOf(Node, "angles") == 0xDC);
        assert(@offsetOf(Node, "orientation") == 0x20);
        assert(@offsetOf(Node, "part") == 0xA4);
        assert(@offsetOf(Node, "armor") == 0xE8);
        assert(@offsetOf(Node, "child_count") == 0xF8);
        assert(@offsetOf(Node, "children") == 0x100);
        assert(@sizeOf(Node) == 0x104);
    }
};

/// `object_set_position` (`0x0049B600`): places the object's root at `at`: its frame, which the
/// port keeps as `frame` (`frameTree`), where it is and where it goes next, so that it doesn't
/// move from where it was. The game also sets the two places a multiplayer game draws another
/// player's ship between (`+0x768`, `+0x798`), which OpenReliant doesn't keep (#55).
/// **Unverified:** it and the functions after it lie after this file's known code, before
/// `particles.cpp`'s.
pub fn setPosition(object: *GameObject, frame: *Model.Local, at: Vector) void {
    const position = gameobj.vec3(at);
    frame.position = at;
    object.root.next_position = position;
    object.root.position = position;
}

/// `object_set_orientation` (`0x0049B650`): turns the object's root to `orientation`, as
/// `setPosition` places it.
pub fn setOrientation(object: *GameObject, frame: *Model.Local, orientation: math.Matrix) void {
    frame.orientation = orientation;
    object.root.next_orientation = orientation;
    object.root.orientation = orientation;
}

/// The file of a model made from none, as in a test.
const no_source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &.{}, .trailing_bytes = 0 };

/// A box: its centre, how it is turned, and how far it reaches from its centre along each of its
/// own axes.
pub const Box = struct {
    centre: Vector,
    orientation: math.Matrix = math.identity,
    half: Vector,

    /// A box of a part's collision tree, in the part's frame.
    fn ofNode(node: shp.TreeNode) Box {
        return .{ .centre = gameobj.vector(node.centre), .orientation = node.orientation, .half = gameobj.vector(node.half_size) };
    }

    /// The box `model` stands in, its bounding box, with its root at `root` (`node_hit_test` for a
    /// root node, by its object's bounds).
    pub fn ofBounds(model: *const Model, root: math.Place) Box {
        const half = (model.bounds[1] - model.bounds[0]) * @as(Vector, @splat(0.5));
        const middle = (model.bounds[1] + model.bounds[0]) * @as(Vector, @splat(0.5));
        return .{ .centre = root.point(middle), .orientation = root.orientation, .half = half };
    }

    /// `point` in the box's own frame, from its centre.
    fn local(box: Box, point: Vector) Vector {
        return math.transformTransposed(box.orientation, point - box.centre);
    }

    /// Whether the segment from `from` to `to` meets it (`segment_meets_box`).
    pub fn meetsSegment(box: Box, from: Vector, to: Vector) bool {
        return boxEntry(box.local(from), box.local(to), .{ -box.half, box.half }) != null;
    }

    /// Whether a sphere at `at` of `radius` meets it, as far as the box widened by the radius
    /// along each axis goes (`collision_hull_test`).
    pub fn meetsSphere(box: Box, at: Vector, radius: f32) bool {
        return @reduce(.And, @abs(box.local(at)) <= box.half + @as(Vector, @splat(radius)));
    }
};

/// A part of an object's model, or of a model mounted on it however deep: one of the object's part
/// nodes, which the game numbers from the root down (`object_number_parts`, `0x00466BA0`).
pub const PartRef = struct {
    model: *Model,
    index: usize,

    pub fn part(ref: PartRef) *Model.Part {
        return &ref.model.parts[ref.index];
    }

    /// Its part's record as the file holds it, with its collision tree; null for a model with no
    /// file behind it, as in a test.
    pub fn data(ref: PartRef) ?shp.PartData {
        const parts = ref.model.source.parts;
        return if (ref.index < parts.len) parts[ref.index] else null;
    }

    /// The root box of its part's collision tree, in the part's frame; null for a part with none.
    pub fn rootBox(ref: PartRef) ?Box {
        const found = ref.data() orelse return null;
        return if (found.nodes.len > 0) .ofNode(found.nodes[0]) else null;
    }

    /// The polygon of its part's finest mesh that face `face` of its record goes into
    /// (`srofiles.polygonOf`); the face's own number for a model with no file behind it. The game's
    /// collision trees list the polygons themselves (`mesh_build`).
    pub fn polygon(ref: PartRef, face: usize) ?usize {
        const found = ref.data() orelse return face;
        if (found.meshes.len == 0) return null;
        return srofiles.polygonOf(found.meshes[0].faces, face);
    }

    /// Whether it still names a part of the model of the object in `slot`, or of a model that
    /// model carries. The models it may name go with their object, so only then may it be read.
    pub fn livesIn(ref: PartRef, slot: *const create.Slot) bool {
        const model = if (slot.model) |*live| live else return false;
        return model.holds(ref.model) and ref.index < ref.model.parts.len;
    }

    /// Its part's record where it has a collision tree over a mesh to test.
    fn tree(ref: PartRef) ?shp.PartData {
        const found = ref.data() orelse return null;
        return if (found.nodes.len > 0 and found.meshes.len > 0) found else null;
    }
};

/// A node of the model tree of the object in slot `object`: its root, or one of its model's parts,
/// as the root's child list holds them. The game keeps the node's address where something rides
/// it (`launch.State.node`).
pub const NodeOf = struct {
    object: u16,
    /// The part, or null for the root.
    part: ?usize = null,

    /// Where the node's frame stands in the world, brought up to date with the frames it hangs
    /// from (`SR_object_concate_parents`, `0x004C3570`): the root's as its frame has it drawn, a
    /// part's as its model places it (`Model.frameAt`). Null for a part the object's model does not
    /// have.
    pub fn place(node: NodeOf, all: *const create.Objects) ?math.Place {
        if (node.object >= all.slots.len) return null;
        const slot = &all.slots[node.object];
        const part = node.part orelse return slot.drawn;
        const model = if (slot.model) |*held| held else return null;
        if (part >= model.parts.len) return null;
        return model.frameAt(part, slot.drawn);
    }
};

/// A part of the model of the object in slot `object`, or of a model that model carries: what an
/// effect hangs from.
pub const PartOf = struct {
    object: u16,
    part: PartRef,

    /// The part, while it still belongs to its object (`PartRef.livesIn`).
    pub fn live(on: PartOf, all: *const create.Objects) ?*Model.Part {
        return if (on.part.livesIn(&all.slots[on.object])) on.part.part() else null;
    }
};

/// `object_hit_test` (`0x0049BEF0`), with `node_hit_test` (`0x0049BD30`) for the roots: where
/// `query.meets` the box `model` stands in with its root at `root`, it hands each of its shown
/// parts to `query.part`, with where the part stands as the next step has it and whether it or a
/// part it hangs from, however far up, plays a track, and then walks each model the part carries in
/// turn. A hidden part is passed over with all it carries.
pub fn hitWalk(model: *Model, root: math.Place, query: anytype) void {
    walkHits(model, root, query, false);
}

fn walkHits(model: *Model, root: math.Place, query: anytype, carried_moving: bool) void {
    if (!query.meets(Box.ofBounds(model, root))) return;
    for (model.parts, 0..) |*part, index| {
        if (part.hidden) continue;
        const moving = carried_moving or model.moving(index);
        query.part(.{ .model = model, .index = index }, model.partPlace(index, .next).within(root), moving);
        var each = model.carriedBy(index);
        while (each.next()) |mount| walkHits(&mount.model, model.mountRoot(mount, root, .next), query, moving);
    }
}

/// How many boxes of a part's tree wait to be tested at once. The trees the game ships are far
/// shallower than this; a node past it is passed over rather than tested.
const hit_stack = 100;

/// What a sphere meets on a model: the part and the face, the part's place as tested, and the
/// nearest point of the face and its normal, both in the part's frame.
pub const Hit = struct {
    part: PartRef,
    place: math.Place,
    face: usize,
    point: Vector,
    normal: Vector,
    /// How far the sphere's centre stands from that point.
    distance: f32,
};

/// `object_hit_test` with `collision_hull_test` (`0x00465240`): the nearest face of `model`, with
/// its root at `root`, or of a model it carries, to a sphere, or null where it meets none. Each
/// part's collision tree is descended through the boxes the sphere reaches, and the faces of a leaf
/// it reaches are tested.
pub fn hitSphere(model: *Model, root: math.Place, at: Vector, radius: f32) ?Hit {
    const Nearest = struct {
        at: Vector,
        radius: f32,
        best: f32,
        /// The part being tested, and the sphere's centre in its frame, which its tree's boxes and
        /// faces are given in.
        ref: PartRef = undefined,
        place: math.Place = .{},
        local: Vector = undefined,
        hit: ?Hit = null,

        pub fn meets(sphere: *@This(), box: Box) bool {
            return box.meetsSphere(sphere.at, sphere.radius);
        }

        pub fn part(sphere: *@This(), ref: PartRef, place: math.Place, _: bool) void {
            const found = ref.tree() orelse return;
            sphere.ref = ref;
            sphere.place = place;
            sphere.local = place.inverse(sphere.at);
            descend(found, ref.index, sphere);
        }

        fn reaches(sphere: @This(), node: shp.TreeNode) bool {
            return Box.ofNode(node).meetsSphere(sphere.local, sphere.radius);
        }

        fn face(sphere: *@This(), _: usize, index: usize, triangle: [3]Vector, normal: Vector) void {
            // Only a sphere in front of the face, and near enough, is worth the triangle.
            const ahead = math.dot(sphere.local - triangle[0], normal);
            if (ahead < 0 or ahead * ahead > sphere.best) return;
            const point = closestOnTriangle(sphere.local, triangle);
            const away = math.lengthSquared(sphere.local - point);
            if (away >= sphere.best) return;
            sphere.best = away;
            sphere.hit = .{ .part = sphere.ref, .place = sphere.place, .face = index, .point = point, .normal = normal, .distance = @sqrt(away) };
        }
    };
    var sphere: Nearest = .{ .at = at, .radius = radius, .best = radius * radius };
    hitWalk(model, root, &sphere);
    return sphere.hit;
}

/// What a segment crosses of a model: the part and the face, and where, in the part's frame.
pub const Crossing = struct {
    part: PartRef,
    face: usize,
    point: Vector,
    normal: Vector,

    /// Where it crosses in the world, as the part stands drawn.
    pub fn inWorld(crossing: Crossing) Vector {
        return crossing.part.part().drawn().point(crossing.point);
    }
};

/// `missile_hull_test` (`0x004959A0`) with `tree_leaf_segment_test` (`0x0049BAE0`): what crosses
/// the faces of parts' collision trees with a segment. A part's tree is descended through the boxes
/// the segment meets, and at a leaf each face the segment starts in front of, no further off than
/// the segment is long, is tested. The last face crossed counts, not the nearest.
const Crosser = struct {
    from: Vector,
    to: Vector,
    reach: f32,
    /// The part being tested, and the segment's ends in its frame.
    ref: PartRef = undefined,
    local_from: Vector = undefined,
    local_to: Vector = undefined,
    hit: ?Crossing = null,

    fn init(from: Vector, to: Vector) Crosser {
        return .{ .from = from, .to = to, .reach = math.lengthSquared(to - from) };
    }

    pub fn meets(segment: *Crosser, box: Box) bool {
        return box.meetsSegment(segment.from, segment.to);
    }

    pub fn part(segment: *Crosser, ref: PartRef, place: math.Place, _: bool) void {
        const found = ref.tree() orelse return;
        segment.ref = ref;
        segment.local_from = place.inverse(segment.from);
        segment.local_to = place.inverse(segment.to);
        descend(found, ref.index, segment);
    }

    fn reaches(segment: Crosser, node: shp.TreeNode) bool {
        return Box.ofNode(node).meetsSegment(segment.local_from, segment.local_to);
    }

    fn face(segment: *Crosser, _: usize, index: usize, triangle: [3]Vector, normal: Vector) void {
        const ahead = math.dot(segment.local_from - triangle[0], normal);
        if (ahead < 0 or ahead * ahead > segment.reach) return;
        const point = segmentMeetsTriangle(segment.local_from, segment.local_to, triangle) orelse return;
        segment.hit = .{ .part = segment.ref, .face = index, .point = point, .normal = normal };
    }
};

/// `node_hit_test` with `missile_hull_test` for one part, `ref`, standing at `place`: the face of
/// it the segment crosses (`Crosser`), or null where it crosses none.
pub fn crossPart(ref: PartRef, place: math.Place, from: Vector, to: Vector) ?Crossing {
    var segment: Crosser = .init(from, to);
    segment.part(ref, place, false);
    return segment.hit;
}

/// `object_hit_test` with `missile_hull_test`: the face of `model`, with its root at `root`, or of
/// a model it carries, that the segment crosses (`Crosser`), or null where it crosses none. The
/// last face crossed counts.
pub fn hitSegment(model: *Model, root: math.Place, from: Vector, to: Vector) ?Crossing {
    var segment: Crosser = .init(from, to);
    hitWalk(model, root, &segment);
    return segment.hit;
}

/// `node_hit_test` for one part: its collision tree descended from the root box, passing over the
/// boxes `query.reaches` does not, with each triangle of a leaf it reaches handed to `query.face`,
/// in the leaf's order. The children of a box are tested last first.
fn descend(data: shp.PartData, part: usize, query: anytype) void {
    const level = data.meshes[0];
    var stack: [hit_stack]u32 = undefined;
    var top: usize = 1;
    stack[0] = 0;
    // A well formed tree holds each node once, so a file that names one twice cannot keep the
    // descent going.
    var left = data.nodes.len;
    while (top > 0 and left > 0) {
        left -= 1;
        top -= 1;
        const at_node = stack[top];
        if (at_node >= data.nodes.len) continue;
        const node = data.nodes[at_node];
        if (!query.reaches(node)) continue;

        const faces = data.node_faces[at_node];
        if (faces.len == 0) {
            for (node.children) |child| {
                if (child < 0 or top >= stack.len) continue;
                stack[top] = @intCast(child);
                top += 1;
            }
            continue;
        }
        visitFaces(level, faces, part, query);
    }
}

/// Hands `query` each of a leaf's `faces` of `level`, as a triangle with its normal.
fn visitFaces(level: shp.Mesh, faces: []const u32, part: usize, query: anytype) void {
    for (faces) |face| {
        if (face >= level.faces.len) continue;
        const record = level.faces[face];
        const triangle: [3]Vector = .{
            corner(level, record.vertices[0]) orelse continue,
            corner(level, record.vertices[1]) orelse continue,
            corner(level, record.vertices[2]) orelse continue,
        };
        query.face(part, face, triangle, gameobj.vector(record.normal));
    }
}

/// `tree_leaf_segment_test` (`0x0049BAE0`) over every leaf of part `ref`'s collision tree, the
/// part standing at `place`: for each leaf whose box the segment from `from` to `to` meets, the
/// last of its faces the segment crosses (`Crosser`), into `out` as far as it has room.
pub fn leafCrossings(ref: PartRef, place: math.Place, from: Vector, to: Vector, out: []Crossing) []Crossing {
    const data = ref.tree() orelse return out[0..0];
    var segment: Crosser = .init(from, to);
    segment.ref = ref;
    segment.local_from = place.inverse(from);
    segment.local_to = place.inverse(to);
    var count: usize = 0;
    for (data.nodes, data.node_faces) |node, faces| {
        if (count == out.len) break;
        if (faces.len == 0 or !segment.reaches(node)) continue;
        segment.hit = null;
        visitFaces(data.meshes[0], faces, ref.index, &segment);
        if (segment.hit) |hit| {
            out[count] = hit;
            count += 1;
        }
    }
    return out[0..count];
}

/// Where the segment from `from` to `to` crosses a triangle, or null where it misses it
/// (`0x004AD700`): solved for how far along the segment and across the triangle's two edges from
/// its last corner, each within 0 and 1 and the two edges' together too. A segment in the
/// triangle's plane misses it.
fn segmentMeetsTriangle(from: Vector, to: Vector, triangle: [3]Vector) ?Vector {
    const span = to - from;
    const first = triangle[0] - triangle[2];
    const second = triangle[1] - triangle[2];
    const across = math.cross(span, second);
    const determinant = math.dot(first, across);
    if (determinant == 0) return null;
    const start = from - triangle[2];
    const u = math.dot(start, across) / determinant;
    const turned = math.cross(start, first);
    const v = math.dot(span, turned) / determinant;
    const t = math.dot(second, turned) / determinant;
    if (t < 0 or t > 1 or u < 0 or v < 0 or u + v > 1) return null;
    return from + span * @as(Vector, @splat(t));
}

/// A segment from `from` to `to`, for what it passes.
pub const Segment = struct {
    from: Vector,
    span: Vector,

    pub fn between(from: Vector, to: Vector) Segment {
        return .{ .from = from, .span = to - from };
    }

    /// How far along it passes nearest `at`, as a share of its length within 0 and 1.
    pub fn nearest(segment: Segment, at: Vector) f32 {
        return std.math.clamp(math.dot(segment.span, at - segment.from) / math.dot(segment.span, segment.span), 0, 1);
    }

    /// How far from `at` it passes at `along`, squared.
    pub fn missSquared(segment: Segment, at: Vector, along: f32) f32 {
        return math.lengthSquared(segment.point(along) - at);
    }

    /// How far along it first meets the sphere of `radius` about `at`, as a share of its length.
    pub fn sphereEntry(segment: Segment, at: Vector, radius: f32) f32 {
        const to = at - segment.from;
        const a = math.dot(segment.span, segment.span);
        const b = math.dot(segment.span, to) * -2;
        const c = math.dot(to, to) - radius * radius;
        const root = @sqrt(@max(b * b - 4 * a * c, 0));
        return (-b - root) / (a + a);
    }

    /// The point `along` of the way from its start.
    pub fn point(segment: Segment, along: f32) Vector {
        return segment.from + segment.span * @as(Vector, @splat(along));
    }
};

/// Which of a model's parts a segment's box test walks, and which of those it meets counts.
pub const PartWalk = enum {
    /// Every shown part; the last met (`bullet_hull_hit`, `0x00479940`).
    last_shown,
    /// Every part, the root's child list, hidden or not; the first met (`missile_hit_hull`,
    /// `0x00495BB0`, which walks on with the segment cut short in the frame of the part met, not
    /// the world's, so no part after it is truly tested).
    first,
};

/// How far along the segment from `from` to `to` it enters the box a part of the model stands in,
/// the part `walk` picks, by its first level's mesh: how a shot or a missile finds what it has hit
/// of a hull. Null where it enters none.
pub fn partEntry(model: *const Model, from: Vector, to: Vector, walk: PartWalk) ?f32 {
    var entry: ?f32 = null;
    for (model.parts) |*part| {
        switch (walk) {
            .last_shown => if (part.hidden) continue,
            .first => if (part.removed) continue,
        }
        if (part.object.levels.len == 0) continue;
        const mesh = part.object.levels[0].mesh;
        // The segment in the part's own frame, where its mesh's box stands.
        const drawn = part.drawn();
        const start = drawn.inverse(from);
        const end = drawn.inverse(to);
        if (boxEntry(start, end, mesh.bounds)) |along| {
            entry = along;
            if (walk == .first) break;
        }
    }
    return entry;
}

/// How far along a segment it enters a box (`segment_meets_box`, `0x0049B6A0`), by the slab test:
/// 0 where it starts inside; null where it misses.
pub fn boxEntry(from: Vector, to: Vector, bounds: [2]Vector) ?f32 {
    var near: f32 = 0;
    var far: f32 = 1;
    const span = to - from;
    inline for (0..3) |axis| {
        if (span[axis] == 0) {
            if (from[axis] < bounds[0][axis] or from[axis] > bounds[1][axis]) return null;
        } else {
            const first = (bounds[0][axis] - from[axis]) / span[axis];
            const second = (bounds[1][axis] - from[axis]) / span[axis];
            near = @max(near, @min(first, second));
            far = @min(far, @max(first, second));
            if (near > far) return null;
        }
    }
    return near;
}

/// A face's corner, or null where the file names a vertex the level does not hold.
fn corner(level: shp.Mesh, vertex: u32) ?Vector {
    if (vertex >= level.vertices.len) return null;
    return gameobj.vector(level.vertices[vertex].position);
}

/// The point of a triangle nearest `from`.
///
/// **Improvement:** the game reaches the same point through a general routine for the nearest point
/// of a simplex (`0x00478360`), which also serves points, lines and tetrahedra.
fn closestOnTriangle(from: Vector, triangle: [3]Vector) Vector {
    const ab = triangle[1] - triangle[0];
    const ac = triangle[2] - triangle[0];
    const ap = from - triangle[0];
    const d1 = math.dot(ab, ap);
    const d2 = math.dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return triangle[0];

    const bp = from - triangle[1];
    const d3 = math.dot(ab, bp);
    const d4 = math.dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return triangle[1];

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return triangle[0] + ab * @as(Vector, @splat(d1 / (d1 - d3)));

    const cp = from - triangle[2];
    const d5 = math.dot(ab, cp);
    const d6 = math.dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return triangle[2];

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return triangle[0] + ac * @as(Vector, @splat(d2 / (d2 - d6)));

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
        const along = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return triangle[1] + (triangle[2] - triangle[1]) * @as(Vector, @splat(along));
    }

    const denominator = 1 / (va + vb + vc);
    return triangle[0] + ab * @as(Vector, @splat(vb * denominator)) + ac * @as(Vector, @splat(vc * denominator));
}

test boxEntry {
    const bounds: [2]Vector = .{ .{ -10, -10, -10 }, .{ 10, 10, 10 } };
    // Through the middle, entering 40 of 100 in; from a corner; ending inside; and from inside.
    try std.testing.expectEqual(0.4, boxEntry(.{ 0, 0, -50 }, .{ 0, 0, 50 }, bounds));
    try std.testing.expect(boxEntry(.{ -50, -50, -50 }, .{ 50, 50, 50 }, bounds) != null);
    try std.testing.expect(boxEntry(.{ 0, 0, -50 }, .{ 0, 0, 0 }, bounds) != null);
    try std.testing.expectEqual(0, boxEntry(.{ 0, 0, 0 }, .{ 0, 0, 50 }, bounds));
    // Past it, short of it, and alongside it.
    try std.testing.expectEqual(null, boxEntry(.{ 50, 0, -50 }, .{ 50, 0, 50 }, bounds));
    try std.testing.expectEqual(null, boxEntry(.{ 0, 0, -50 }, .{ 0, 0, -20 }, bounds));
    try std.testing.expectEqual(null, boxEntry(.{ 0, 20, -50 }, .{ 0, 20, 50 }, bounds));
}

test segmentMeetsTriangle {
    const triangle: [3]Vector = .{ .{ -10, -10, 0 }, .{ 10, -10, 0 }, .{ 0, 10, 0 } };
    // Through it, a quarter of the way along, and where.
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, segmentMeetsTriangle(.{ 0, 0, -25 }, .{ 0, 0, 75 }, triangle).?);
    // Short of it, beside it, and along its plane.
    try std.testing.expectEqual(null, segmentMeetsTriangle(.{ 0, 0, -25 }, .{ 0, 0, -5 }, triangle));
    try std.testing.expectEqual(null, segmentMeetsTriangle(.{ 20, 0, -25 }, .{ 20, 0, 75 }, triangle));
    try std.testing.expectEqual(null, segmentMeetsTriangle(.{ -20, 0, 0 }, .{ 20, 0, 0 }, triangle));
}

test Segment {
    const segment: Segment = .between(.{ 0, 0, -100 }, .{ 0, 0, 100 });
    // Nearest a point off its middle, and one past its end.
    try std.testing.expectEqual(0.5, segment.nearest(.{ 30, 0, 0 }));
    try std.testing.expectEqual(1, segment.nearest(.{ 0, 0, 500 }));
    try std.testing.expectEqual(900, segment.missSquared(.{ 30, 0, 0 }, 0.5));
    // Into a sphere of 50 about the middle a quarter of the way along.
    try std.testing.expectEqual(0.25, segment.sphereEntry(@splat(0), 50));
    try std.testing.expectEqual(Vector{ 0, 0, -50 }, segment.point(0.25));
}

test hitSphere {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();

    var live = try Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    gameobj.linkParts(&live, &model.source);
    const root: math.Place = .{};

    // The part is a square in the XY plane facing -Z; a sphere in front of it meets it.
    const hit = hitSphere(&live, root, .{ 0, 0, -60 }, 100) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(0, hit.part.index);
    try std.testing.expectApproxEqAbs(60, hit.distance, 1e-3);
    try std.testing.expectEqual(math.Vector{ 0, 0, -1 }, hit.normal);

    // Behind the face, and too far off to the side, it meets nothing.
    try std.testing.expectEqual(null, hitSphere(&live, root, .{ 0, 0, 60 }, 100));
    try std.testing.expectEqual(null, hitSphere(&live, root, .{ 900, 0, -60 }, 100));
    // Its root box widened by the sphere's radius takes in a sphere near its corner, not one past.
    try std.testing.expect(Box.ofBounds(&live, root).meetsSphere(.{ 150, 150, 0 }, 100));
    try std.testing.expect(!Box.ofBounds(&live, root).meetsSphere(.{ 250, 0, 0 }, 100));
}

test hitSegment {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();

    var live = try Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    gameobj.linkParts(&live, &model.source);
    const root: math.Place = .{};

    // The part is a square in the XY plane facing -Z; a segment through it from in front crosses
    // it where it passes.
    const hit = hitSegment(&live, root, .{ 5, 5, -60 }, .{ 5, 5, 60 }) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(&live, hit.part.model);
    try std.testing.expectEqual(0, hit.part.index);
    try std.testing.expectEqual(math.Vector{ 5, 5, 0 }, hit.point);
    try std.testing.expectEqual(math.Vector{ 0, 0, -1 }, hit.normal);

    // From behind, short of it, and beside it, it crosses nothing.
    try std.testing.expectEqual(null, hitSegment(&live, root, .{ 5, 5, 60 }, .{ 5, 5, -60 }));
    try std.testing.expectEqual(null, hitSegment(&live, root, .{ 5, 5, -60 }, .{ 5, 5, -30 }));
    try std.testing.expectEqual(null, hitSegment(&live, root, .{ 900, 0, -60 }, .{ 900, 0, 60 }));
    // Moved, it is struck where it stands at the next step.
    try std.testing.expect(hitSegment(&live, .{ .position = .{ 1000, 0, 0 } }, .{ 1005, 5, -60 }, .{ 1005, 5, 60 }) != null);
    try std.testing.expectEqual(null, hitSegment(&live, .{ .position = .{ 1000, 0, 0 } }, .{ 5, 5, -60 }, .{ 5, 5, 60 }));
    // Its root box and its tree's root box meet the segment; one beside them doesn't.
    try std.testing.expect(Box.ofBounds(&live, root).meetsSegment(.{ 5, 5, -60 }, .{ 5, 5, 60 }));
    const tree = (PartRef{ .model = &live, .index = 0 }).rootBox().?;
    try std.testing.expect(tree.meetsSegment(root.inverse(.{ 5, 5, -60 }), root.inverse(.{ 5, 5, 60 })));
    try std.testing.expect(!tree.meetsSegment(root.inverse(.{ 900, 0, -60 }), root.inverse(.{ 900, 0, 60 })));
}

test leafCrossings {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();

    var live = try Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    gameobj.linkParts(&live, &model.source);
    const ref: PartRef = .{ .model = &live, .index = 0 };

    // The part's tree is one leaf over the square; a segment through it crosses it where it
    // passes, in the part's frame, wherever the part stands.
    var out: [4]Crossing = undefined;
    const through = leafCrossings(ref, .{}, .{ 20, 5, -60 }, .{ 20, 5, 60 }, &out);
    try std.testing.expectEqual(1, through.len);
    try std.testing.expectEqual(math.Vector{ 20, 5, 0 }, through[0].point);
    try std.testing.expectEqual(math.Vector{ 0, 0, -1 }, through[0].normal);
    const moved = leafCrossings(ref, .{ .position = .{ 1000, 0, 0 } }, .{ 1020, 5, -60 }, .{ 1020, 5, 60 }, &out);
    try std.testing.expectEqual(math.Vector{ 20, 5, 0 }, moved[0].point);
    // Beside it, or with no room, it crosses nothing.
    try std.testing.expectEqual(0, leafCrossings(ref, .{}, .{ 900, 0, -60 }, .{ 900, 0, 60 }, &out).len);
    try std.testing.expectEqual(0, leafCrossings(ref, .{}, .{ 20, 5, -60 }, .{ 20, 5, 60 }, out[0..0]).len);
}

/// `node_tree_frames` (`0x0049A880`) for an object, once a frame before it is drawn and before the
/// camera's frame: its root's frame (`Node.framePlace`), which `drawn` keeps, then each of its
/// part nodes' (`Model.frame`), and the model placed where the root's frame has it.
///
/// **Improvement:** an object the orders place from tick to tick, rather than move, goes on by
/// `glide` from where they placed it (`create.Slot.glide`), so it moves on every frame as what
/// flies does. The game draws it where it was placed. Null leaves an object that no step has moved
/// where it was drawn.
pub fn frameTree(root: *Node, model: ?*Model, drawn: *Model.Local, fraction: f32, glide: ?Vector) void {
    if (root.framePlace(fraction)) |place| {
        drawn.* = place;
        if (glide) |on| drawn.position += on;
    } else if (glide) |on| {
        drawn.position = gameobj.vector(root.position) + on;
    }
    const parts = model orelse return;
    parts.frame(fraction);
    parts.place(drawn.position, drawn.orientation);
}

/// `node_draw` (`0x0049A8C0`) for the roots flagged `destroyed`, as `mission_frame`'s pass that
/// draws the objects reaches the object in slot `index`, in sight or not: its model's root, then,
/// depth first, those of the models mounted on its shown parts. For each part of such a root that
/// has run out of armour and is not yet spent, in part order:
///
/// - It is spent.
/// - An engine takes its share off the object's `engines_intact`.
/// - A shield generator, while the object still has one, is heard going down, and the object has
///   none after. Any other part goes to the routine the object's type has
///   (`explode.ComponentLoss`), which may end the pass over this root, its flag left set.
/// - Its destruction sets its assembly off (`explode.componentLost`).
/// - Each part of its assembly that is shown is taken out (`destroyPart`), a component the object
///   lists posting its Destroyed event first (`events.destroyed`), and a part of the hull ending
///   the ship; each hidden one, its damaged model, is shown.
///
/// Then the root's flag is cleared.
///
/// Not ported: the subtarget's parts picked out in red again where the object is the player's
/// target (`hud_subtarget_clear`, `hud_subtarget`,
/// [#45](https://github.com/vdmkenny/openreliant/issues/45)).
pub fn loseComponents(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const model = if (slot.model) |*live| live else return;
    loseIn(ctx, index, model, slot.drawn);
}

fn loseIn(ctx: aigeneric.Context, index: u16, model: *Model, root: math.Place) void {
    if (model.destroyed) loseRoot(ctx, index, model, root);
    for (model.parts, 0..) |*part, at| {
        if (part.hidden) continue;
        var each = model.carriedBy(at);
        while (each.next()) |mount| loseIn(ctx, index, &mount.model, mount.rootAt(part.drawn()));
    }
}

fn loseRoot(ctx: aigeneric.Context, index: u16, model: *Model, root: math.Place) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    for (model.parts) |*part| {
        if (part.removed or part.spent or !(part.armor < 0)) continue;
        part.spent = true;
        if (part.class == .engine) object.engines_intact -= 1 / @as(f32, @floatFromInt(object.engines));
        if (part.class == .shield_generator) {
            if (object.flags.shield_generator) shieldsDown(world, part.drawn());
            object.flags.shield_generator = false;
        } else if (explode.ComponentLoss.of(object.type)) |routine| {
            if (!explode.loseComponent(ctx, index, routine, part)) return;
        }
        const link = part.link_id;
        explode.componentLost(world, index, model, root, link);
        var each = model.assembly(link);
        while (each.next()) |at| {
            const piece = &model.parts[at];
            if (piece.hidden) {
                piece.hidden = false;
                continue;
            }
            if (slot.componentIndex(piece)) |component| events.destroyed(world, index, component);
            if (piece.class == .hull) explode.loseHull(ctx, index);
            destroyPart(slot, .{ .model = model, .index = at });
        }
    }
    model.destroyed = false;
}

/// A shield generator going down: `SHLDDOWN` from where it stands, facing its way.
fn shieldsDown(world: gameobj.World, at: math.Place) void {
    sound3d.playIn(world, at.position, math.forward(at.orientation), -1, .shlddown, 1, .not_reserved);
}

/// `node_destroy` (`0x00499E30`) with `node_forget` (`0x00499BB0`): takes part `ref` out of the
/// object in `slot`, and with it each part linked to it however deep and every model mounted on
/// any of them. Each is hidden for good (`Model.Part.removed`), a turret whose base it is stops
/// for good (`guns.Turret.gone`), and a component leaves the object's list.
pub fn destroyPart(slot: *create.Slot, ref: PartRef) void {
    const part = ref.part();
    if (part.removed) return;
    part.removed = true;
    part.hidden = true;
    for (ref.model.parts, 0..) |*linked, at| {
        if (linked.parent == ref.index) destroyPart(slot, .{ .model = ref.model, .index = at });
    }
    if (part.turret) for (slot.guns) |*gun| {
        const base = gun.turret.base() orelse continue;
        if (base.model == ref.model and base.index == ref.index) gun.turret = .gone;
    };
    for (&slot.components) |*entry| {
        if (entry.* == part) entry.* = null;
    }
    var each = ref.model.carriedBy(ref.index);
    while (each.next()) |mount| {
        for (0..mount.model.parts.len) |at| destroyPart(slot, .{ .model = &mount.model, .index = at });
    }
}

/// The light mask `node_add_part` gives a part's Surrender object: a light reaches the object
/// unless their masks share a bit (`docs/engine/rendering.md`).
pub fn lightMask(model_lists_components: bool) u32 {
    return if (model_lists_components) components_light_mask else whole_light_mask;
}

/// The light masks of `node_add_part` (`0x00499430`): a model that lists components keeps out the
/// backdrop's lights `0x08` and `0x10`, and any other `0x01` and `0x02`.
const components_light_mask: u32 = 0x18;
const whole_light_mask: u32 = 0x03;

/// A live object's model as OpenReliant holds it: its root's place in the world, and a node for
/// each part of its model, each with its part's scene object. A part hangs from the part it names
/// (`object_link_parts`, `0x00476130`), so a part carries what stands on it; a part naming none
/// hangs from the root.
///
/// Not yet ported: the moment of inertia `object_bounds` sums, which nothing reads yet; the
/// animation a node's track holds (`node_animate`).
pub const Model = struct {
    /// The file the model was made from, which its parts' collision trees are read from.
    source: *const shp.Model = &no_source,
    /// The root's place (`object_set_position`, `object_set_orientation`).
    position: Vector = @splat(0),
    orientation: math.Matrix = math.identity,
    parts: []Part,
    /// The parts in the order `place` walks them: each after the one it hangs from.
    order: []const usize,
    lights: []Light,
    glows: []Glow,
    mounts: []Mount,
    /// A flash for each gun muzzle its parts carry (`node_mount_muzzle`).
    flashes: []flash.Flash = &.{},
    /// What its missile hardpoints hold, a rack each, as `object_fit_missiles` hangs it: a pod, or
    /// a missile on its rail, which a launch takes its model from. Empty until the racks are
    /// fitted.
    hung: []?Mount = &.{},
    /// Where the model's origin lies from the object's, less (`GameObject + 0x524`): the centres
    /// of mass `recentre` moved the origin to.
    centre: Vector = @splat(0),
    /// The sum of its shown parts' masses (`GameObject.mass`), as `recentre` leaves it.
    mass: f32 = 0,
    /// The root node's `destroyed` flag, which `component_damage` sets where one of its parts, a
    /// component, runs out of armour, and `loseComponents` acts on and clears. Every part's node
    /// stays in its root's child list, whatever part it is linked to, so the root holds them all
    /// (`node_holder`, `0x00499EE0`).
    destroyed: bool = false,
    /// Its farthest vertex from its origin, and its bounding box (`GameObject.radius`,
    /// `bounds_min`, `bounds_max`), as `recentre` leaves them.
    radius: f32 = 0,
    /// The inverse of the inertia tensor its parts sum to, which turns an angular impulse into the
    /// turn it gives the object (`GameObject.angular_response`), as `recentre` leaves it. Zero for
    /// a model whose parts have no volume, which nothing can turn.
    angular_response: math.Matrix = @splat(0),
    /// How far off it stays worth drawing, over what its radius alone gives it
    /// (`GameObject.visibility`): 1, but for an asteroid's fragments (`create.Slot.shrink`).
    visibility: f32 = 1,
    bounds: [2]Vector = .{ @splat(0), @splat(0) },

    /// A light a model carries: what `node_mount_light` (`0x00499730`) makes of an attachment of
    /// kind `light`, which `node_draw` draws for node kinds 3 and 5. Its sprites are a flare that
    /// grows with how far off it is and a small lamp at its heart, and a light that blinks casts a
    /// point light on what stands near it as well. All three blink by the attachment's timing.
    ///
    /// Not ported: in the software renderer, `node_mount_light` makes no point light for an
    /// object of type 13, the Yamato. OpenReliant draws as the hardware renderer does.
    pub const Light = struct {
        /// The part that carries it, whose node `node_draw` walks to reach it.
        part: usize,
        /// Its place on that part, which is where the model's attachment point stands.
        origin: Vector,
        blink: Blink,
        /// Its sprites (node kind 3), for an attachment with a width (`size[0]`).
        sprites: ?Sprites,
        /// The point light it casts (node kind 5): its id's colour, its brightness and its range,
        /// reaching every object that takes lights. Only a light that blinks, with a brightness,
        /// casts one: the loader bakes a steady light into the meshes instead
        /// (`static_lights_bake`). Its place is set as it is drawn.
        cast: ?srlight.Light,

        /// A light's sprites and what they are drawn with.
        pub const Sprites = struct {
            /// The flare's colour, which the attachment's id picks, and the lamp's paler one.
            colour: [3]f32,
            lamp_colour: [3]f32,
            /// The attachment's height (`size[1]`), which both sprites are sized by.
            size: f32,
            set: srapiext.SpriteSet,
            /// The flare, then the lamp: the set's two sprites.
            sprite: [2]srapiext.Sprite,
            /// The lamp's own material: lit, added and textured with the sprite attachment kind 4
            /// id 1 names. The flare takes the set's.
            lamp: srapiext.Surface,

            pub const flare = 0;
            pub const lamp_sprite = 1;

            /// Sizes and colours the sprites for a light `blink` bright in its blink, seen from
            /// `away` (`node_draw`).
            fn show(sprites: *Sprites, blink: f32, away: f32) void {
                // The lamp goes out as soon as the light starts to fade.
                sprites.sprite[lamp_sprite].colour = if (blink < lamp_least) @splat(0) else sprites.lamp_colour;
                var shown = blink;
                if (away <= faded_at) {
                    if (full_at < away) shown = math.lerp(1, faded, (away - full_at) * (1.0 / (faded_at - full_at))) * blink;
                } else {
                    shown = blink * faded;
                }
                // The flare grows up to `grown_at` off: `lerp(0, 1, ...)`, which is the share
                // alone.
                const grown = if (grown_at <= away) sprites.size else away * (1.0 / grown_at) * sprites.size;
                sprites.sprite[flare].half_size = @splat(grown * flare_scale);
                sprites.sprite[lamp_sprite].half_size = @splat(sprites.size * lamp_scale);
                // Held between 0 and 1, where anything short of 0, or no number, is 0.
                if (shown >= 0) {
                    if (shown > 1) shown = 1;
                } else {
                    shown = 0;
                }
                for (&sprites.sprite[flare].colour, sprites.colour) |*channel, c| {
                    channel.* = shown * c * flare_share;
                }
            }
        };
    };

    /// How a light blinks (`node_draw`): the attachment's `blink`, ticks on and then off, and its
    /// `blink_phase`, where in that it starts.
    pub const Blink = struct {
        times: [2]i32 = .{ 0, 0 },
        phase: i32 = 0,

        /// How bright the light stands in its blink at the object's own `tick`, the mission's clock
        /// plus its `blink_offset`: 1 while it is on, then falling away over `blink_fade` of its
        /// clock, which runs ten to the tick, and nothing or less once out. The clock wraps as the
        /// game's unsigned arithmetic does. A light with no blink is always on.
        pub fn brightness(blink: Blink, tick: i32) f32 {
            const period = blink.times[0] +% blink.times[1];
            if (period == 0) return 1;
            const clock: u32 = @bitCast(tick *% blink_clock_per_tick -% blink.phase);
            const at: i32 = @bitCast(clock % @as(u32, @bitCast(period)));
            var shown: f32 = 1;
            if (blink.times[0] < at) shown = @as(f32, @floatFromInt(blink.times[0] -% at +% blink_fade)) * (1.0 / @as(f32, blink_fade));
            if (period < at) shown = @as(f32, @floatFromInt(at -% period +% blink_fade)) * (1.0 / @as(f32, blink_fade));
            return shown;
        }
    };

    /// An engine glow a model carries, which `node_draw` draws for node kind 2: an attachment of
    /// kind `engine_glow`, drawn as the mesh its id names (`node_mount_glow`, `0x00499540`), scaled
    /// by the attachment's size and stretched along the plume by the throttle.
    ///
    /// Not ported: the Ripper's own rule, which draws its thrusters only while it flies forward and
    /// its back pincers only while it backs up, their plumes burning the other way. It knows them
    /// by their parts' names, and needs the motion it is not ported to tell apart.
    pub const Glow = struct {
        /// The part that carries it, whose node `node_draw` walks to reach it.
        part: usize,
        /// Its place on that part, which is where the model's attachment point stands.
        origin: Vector,
        /// How the attachment stands on the part: the plume burns along its Z axis.
        orientation: math.Matrix,
        /// How far the plume reaches across, up, and along, before the throttle stretches its
        /// length.
        size: Vector,
        /// Burning against the way the throttle pushes: its plume points the way the model faces,
        /// so it is a retro thruster, lit by reverse thrust alone.
        retro: bool,
        /// Burning at its full length whatever the throttle, as the last of the glows does.
        steady: bool,
        /// The one mesh it draws, which every glow of its kind shares.
        level: [1]srapiext.Level,
        object: srapiext.MeshObject,

        /// How far along its length the plume burns, or null while it burns nothing. Every glow but
        /// a steady one flickers a little each frame (`node_draw`).
        pub fn plume(glow: Glow, throttle: f32, random: ?*libcmt.Rand) ?f32 {
            if (glow.steady) return 1;
            const lit = if (glow.retro) -throttle else throttle;
            if (!(lit > 0)) return null;
            return lit * flicker(random);
        }
    };

    /// A model an attachment point holds: a gun or a pod, which `node_mount` (`0x00499A10`) mounts
    /// as an object of its own, hung from the node of the part that carries the attachment. Its own
    /// parts, lights, glows and mounts come with it.
    pub const Mount = struct {
        /// The part that carries the attachment, and which of the part's attachments it is.
        part: usize,
        attachment: usize,
        /// Where the attachment stands on that part, and how it is turned there.
        origin: Vector,
        orientation: math.Matrix,
        model: Model,

        /// Where the attachment stands in the world, for its part standing at `carrier`.
        pub fn within(mount: Mount, carrier: math.Place) math.Place {
            return (math.Place{ .position = mount.origin, .orientation = mount.orientation }).within(carrier);
        }

        /// Where the mounted model's root stands, for its part standing at `carrier`: at the
        /// attachment, gone back by the model's centre of mass, which it stands on.
        pub fn rootAt(mount: Mount, carrier: math.Place) math.Place {
            const on = mount.within(carrier);
            return .{ .position = on.point(mount.model.centre), .orientation = on.orientation };
        }
    };

    pub const Part = struct {
        /// The node's `hidden` flag.
        hidden: bool,
        /// What its part's record says of it, which the components are collected by.
        flags: shp.Part.Flags = std.mem.zeroes(shp.Part.Flags),
        /// Its part's attachment points, which the guns are fitted from. The model they belong to
        /// outlives the object.
        attachments: []const shp.Attachment = &.{},
        /// Its node's `component` flag: the object lists the part among its components
        /// (`create.collectComponents`).
        component: bool = false,
        /// What it has left before it is destroyed, from its part's `component_armor`
        /// (`node_add_part`). Only a component's is read.
        armor: f32 = 0,
        /// What its part's record holds for a component: how much armour it starts with, and the
        /// assembly it belongs to, such as a turret and its barrels.
        component_armor: i32 = 0,
        link_id: u32 = 0,
        /// Its part's `component_group`: the parts whose hits count against one component.
        component_group: u32 = 0,
        /// Its node's flag `0x10`: a component whose destruction `loseComponents` has dealt with,
        /// which is no longer aimed at.
        spent: bool = false,
        /// Taken out of its model (`node_destroy`, `destroyPart`): hidden for good, and passed
        /// over where the game finds its node gone from its root's child list.
        removed: bool = false,
        /// Its node's `targetable` flag, which cycling subtargets requires and `SetTargetable`
        /// changes.
        targetable: bool = false,
        /// What its part is (part `+0x40`), which the target display names a subtarget by.
        class: shp.Part.Class = @enumFromInt(0),
        /// The turret its part makes of its assembly, and which of the turret's parts it is (part
        /// `+0xF4`, `+0xF8`).
        turret_kind: shp.Part.TurretKind = .fixed,
        turret_slot: i32 = -1,
        /// Its node's `turret` flag: the base of a turret, which the turret fits mark.
        turret: bool = false,
        /// Its part's name holds `FORCEFIELD` (`shield.isForceField`): the field round a capital
        /// ship, which glows whole where it is struck and goes dark as the ship is lost.
        force_field: bool = false,
        /// Its node's `capshield`: the capital shield showing on it.
        capshield: ?shield.CapitalSlot = null,
        /// The part its node hangs from (`object_link_part`), or null for one hanging from the
        /// root. A part names its parent by index, or -1 for none.
        parent: ?usize,
        /// Where its frame stands in the frame of the part it hangs from, or in the model's for one
        /// hanging from the root, and how it's turned there. A model gives every part its origin in
        /// the model whatever its parent, so hanging one from another takes the parent's origin
        /// off it and leaves it where it stood: linking the part places it so (`node_place`), in
        /// the pose its first track has at its start, and an animated part moves on from there
        /// (`frame`).
        origin: Vector,
        turn: math.Matrix = math.identity,
        /// The node's frame: a scene object showing the part's meshes. `place` fills it in.
        object: srapiext.MeshObject,
        /// What its cloak draws it with, where its model can cloak (`srofiles.Cloaking`).
        cloak: ?cloak.PartCloak = null,
        /// Its node's animation, and what `node_place` reads of its part.
        animation: Animation = .{},

        /// Whether it is there to be aimed at: neither hidden nor spent (node flags `0x20` and
        /// `0x10`).
        pub fn standing(part: *const Part) bool {
            return !part.hidden and !part.spent;
        }

        /// Where it stands as it was last drawn: its node's frame.
        pub fn drawn(part: *const Part) math.Place {
            return .{ .position = part.object.position, .orientation = part.object.orientation };
        }

        /// Where its frame stands in the world with the frame it hangs from at `carrier`: at its
        /// origin there, turned by its turn, save that a frame whose turn has ones down its
        /// diagonal takes its parent's orientation as it is.
        pub fn frameWithin(part: *const Part, carrier: math.Place) math.Place {
            const unturned = part.turn[0] == 1 and part.turn[4] == 1 and part.turn[8] == 1;
            return .{
                .position = carrier.point(part.origin),
                .orientation = if (unturned) carrier.orientation else math.product(carrier.orientation, part.turn),
            };
        }
    };

    /// How a node plays its animation track (node `+0xB4`).
    pub const Mode = shp.PlayMode(i32);

    /// The tracks the loader files by name, for the game to start by it (`node_play`).
    pub const Slot = enum { startup, fire, deploy };

    /// A part node's place in the frame it hangs from.
    pub const Local = math.Place;

    /// A part node's pose: the animation's angles, plus the turret's, and the animation's offset.
    pub const Pose = struct {
        angles: Vector = @splat(0),
        offset: Vector = @splat(0),
    };

    /// A place, and the pose `node_place` worked it out from.
    pub const Posed = struct {
        place: Local = .{},
        pose: Pose = .{},
    };

    /// A part's node as its animation has it: what `node_place` reads of the part, the part's
    /// tracks, which of them the node plays, how and where in it (node `+0xB4` to `+0xD8`), and the
    /// place and pose of the last step and of the next, which the frames drawn between the steps
    /// fall between (`frame`).
    pub const Animation = struct {
        /// The part's origin in the model, its mount point, which it turns about, and its
        /// orientation, in whose frame it turns (part `+0x44`, `+0x98`, `+0xA4`); and the axes it
        /// doesn't turn about whatever the track says (part `+0xC8`).
        position: Vector = @splat(0),
        mount: Vector = @splat(0),
        orientation: math.Matrix = math.identity,
        still: [3]bool = @splat(false),
        /// How far a turret turns the part about each of its axes, at least and at most, in
        /// degrees (part `+0xD8`, `+0xE4`).
        angles_min: Vector = @splat(0),
        angles_max: Vector = @splat(0),
        /// The part's tracks, and which the loader filed under each name the game starts by.
        tracks: []const shp.Track = &.{},
        slots: std.EnumArray(Slot, ?usize) = .initFill(null),
        mode: Mode = .none,
        track: usize = 0,
        /// Where the node is in its track, and how far it moves on each simulation step.
        time: f32 = 0,
        speed: f32 = 0,
        /// Where the track has the part (node `+0xC4`, `+0xD0`), which `node_animate` sets.
        angles: Vector = @splat(0),
        offset: Vector = @splat(0),
        /// The angles a turret turns the node by besides the track's (node `+0xDC`, `swivel`).
        turret: Vector = @splat(0),
        /// A part of a turret whose muzzle faces back, which turns in its frame turned a half turn
        /// about X: its turret's angles about Y and Z count the other way. **Fix:** the game's
        /// never fires ([#219](https://github.com/vdmkenny/openreliant/issues/219)).
        reversed: bool = false,
        /// The place `node_place` worked out for the next step, and its pose (node `+0x5C` to
        /// `+0xA3`), and the ones `node_tree_update` committed from them (`+0x14` to `+0x5B`).
        next: Posed = .{},
        now: Posed = .{},
        /// The node's flags this keeps (`Node.Flags`): `next_pending`, `committed`, `unframed`,
        /// `posed` and `animating`.
        pending: bool = false,
        committed: bool = false,
        unframed: bool = false,
        posed: bool = false,
        animating: bool = false,

        /// The node's place in the frame it hangs from at `step`.
        pub fn at(a: Animation, step: Step) Local {
            return switch (step) {
                .now => a.now.place,
                .next => a.next.place,
            };
        }
    };

    /// The part `index` hangs from, or null where it hangs from the root: the index a part names,
    /// unless it names none or one no model part answers to.
    fn parentOf(model: *const shp.Model, index: usize) ?usize {
        const named = model.parts[index].part.parent;
        if (named < 0 or named == index) return null;
        const parent: usize = @intCast(named);
        return if (parent < model.parts.len) parent else null;
    }

    /// The part hanging from the root that `part` hangs from, however deep, or `part` itself where
    /// it hangs from the root.
    pub fn topOf(model: *const Model, part: *const Part) *const Part {
        var top = part;
        var up = model.lineage(part.parent orelse return part);
        while (up.next()) |index| top = &model.parts[index];
        return top;
    }

    /// Part `index`, then the part it hangs from, and so on up to the root. Parents that run in a
    /// circle end the walk once it has taken as many steps as there are parts.
    pub fn lineage(model: *const Model, index: usize) Lineage {
        return .{ .parts = model.parts, .at = index };
    }

    pub const Lineage = struct {
        parts: []const Part,
        at: ?usize,
        steps: usize = 0,

        pub fn next(up: *Lineage) ?usize {
            const index = up.at orelse return null;
            if (up.steps == up.parts.len) return null;
            up.steps += 1;
            up.at = up.parts[index].parent;
            return index;
        }
    };

    /// The node at `child` in the root's child list, where each part's node stays at its part's
    /// number whatever part it is linked to: that part, or null past the parts or where it has been
    /// taken out.
    pub fn rootChild(model: *const Model, child: usize) ?*const Part {
        if (child >= model.parts.len or model.parts[child].removed) return null;
        return &model.parts[child];
    }

    /// The parts in an order that puts each after the one it hangs from, so that placing them in
    /// it needs only one pass: by how far each stands from the root, which a part's parent is
    /// always nearer than. A part whose parents run in a circle is taken as standing at the root,
    /// which keeps a broken model from looping here.
    fn linkOrder(gpa: Allocator, model: *const shp.Model) Allocator.Error![]usize {
        const depths = try gpa.alloc(usize, model.parts.len);
        defer gpa.free(depths);
        for (depths, 0..) |*depth, index| {
            depth.* = 0;
            var at = parentOf(model, index);
            while (at) |parent| : (at = parentOf(model, parent)) {
                depth.* += 1;
                if (depth.* > model.parts.len) {
                    depth.* = 0;
                    break;
                }
            }
        }
        const order = try gpa.alloc(usize, model.parts.len);
        var at: usize = 0;
        for (0..model.parts.len + 1) |depth| {
            for (depths, 0..) |part_depth, index| {
                if (part_depth != depth) continue;
                order[at] = index;
                at += 1;
            }
        }
        assert(at == order.len);
        return order;
    }

    /// A node for each part of `model` (`node_add_part`, `0x00499430`), its object flagged as
    /// `model_load` left the part (`loaded`), reached by the lights `lightMask` lets through, and
    /// as far across as its largest level. A part of a component's damaged model is hidden. The
    /// parts hang from nothing yet: `gameobj.linkParts` hangs them, once whatever the model plays
    /// from the start is playing (`create_object`).
    pub fn create(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded, effects: Effects) Allocator.Error!Model {
        return build(gpa, model, loaded, effects, 0);
    }

    /// `create`, with how many mounts deep this model already stands.
    fn build(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded, effects: Effects, depth: usize) Allocator.Error!Model {
        const parts = try gpa.alloc(Part, model.parts.len);
        var parts_made: usize = 0;
        errdefer {
            for (parts[0..parts_made]) |made| if (made.cloak) |effect| effect.deinit(gpa);
            gpa.free(parts);
        }
        for (parts, model.parts, loaded.parts, 0..) |*node, source, part, index| {
            var radius: f32 = 0;
            for (part.meshes) |mesh| radius = @max(radius, mesh.radius);
            const at = source.part.position;
            node.* = .{
                .hidden = source.part.flags.damaged,
                .flags = source.part.flags,
                .attachments = source.attachments,
                .armor = @floatFromInt(source.part.component_armor),
                .component_armor = source.part.component_armor,
                .class = source.part.class,
                .turret_kind = source.part.turret_kind,
                .turret_slot = source.part.turret_slot,
                .link_id = source.part.link_id,
                .component_group = source.part.component_group,
                .force_field = shield.isForceField(source.part.name()),
                .parent = parentOf(model, index),
                .origin = @splat(0),
                .object = .{
                    .flags = part.flags,
                    .position = gameobj.vector(at),
                    .radius = radius,
                    .light_mask = lightMask(model.header.flags.components),
                    .levels = part.levels,
                },
                .animation = .{
                    .position = gameobj.vector(at),
                    .mount = gameobj.vector(source.part.mount_point),
                    .orientation = source.part.orientation,
                    // Three whole numbers, which the game tests as floats against zero.
                    .still = source.part.still != @as(@Vector(3, u32), @splat(0)),
                    .angles_min = gameobj.vector(source.part.angles_min),
                    .angles_max = gameobj.vector(source.part.angles_max),
                    .tracks = source.tracks,
                    .slots = slotsOf(source.tracks),
                },
            };
            // A part that can cloak is coloured by its own colours, clear until a hit shows it
            // through the cloak (`mesh_object_create`). Seen through, it casts a shadow as solid as
            // its hull (`cloak.Drawing`).
            if (part.cloaking) |cloaking| {
                node.cloak = try .create(gpa, cloaking, source.part.name(), part.levels, radius);
                node.object.baked = node.cloak.?.hull_colours;
                node.object.alpha_shadow = true;
            }
            parts_made += 1;
        }
        const order = try linkOrder(gpa, model);
        errdefer gpa.free(order);
        var built: Model = .{ .source = model, .parts = parts, .order = order, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
        const lights = try createLights(gpa, model, effects.light_sprites);
        errdefer gpa.free(lights);
        const glows = try createGlows(gpa, model, effects.glows);
        errdefer gpa.free(glows);
        const flashes = try createFlashes(gpa, model, effects.flashes);
        errdefer gpa.free(flashes);
        built.lights = lights;
        built.glows = glows;
        built.flashes = flashes;
        built.mounts = try createMounts(gpa, model, effects, depth);
        return built;
    }

    /// Which of `tracks` the loader files under each name it knows (`model_load`): the last of
    /// each name, whatever its case.
    fn slotsOf(tracks: []const shp.Track) std.EnumArray(Slot, ?usize) {
        var slots: std.EnumArray(Slot, ?usize) = .initFill(null);
        for (tracks, 0..) |track, index| {
            for (std.enums.values(Slot)) |slot| {
                if (std.ascii.eqlIgnoreCase(track.clip.name(), @tagName(slot))) slots.set(slot, index);
            }
        }
        return slots;
    }

    /// `node_animate` (`0x00499F40`): poses part `index` as its track has it at time `at`, between
    /// the keyframes either side of it, or as the last where `at` runs past them all, then places
    /// it by that pose (`node_place`). Before its first keyframe it moves from no pose at time
    /// zero. A node whose track is past the part's has no pose.
    pub fn animate(model: *Model, index: usize, at: f32) void {
        const a = &model.parts[index].animation;
        if (a.track >= a.tracks.len) {
            a.angles = @splat(0);
            a.offset = @splat(0);
            return model.pose(index);
        }
        var before: Pose = .{};
        var when: f32 = 0;
        var key: Pose = .{};
        for (a.tracks[a.track].keyframes) |keyframe| {
            key = .{
                .angles = gameobj.vector(keyframe.angles),
                .offset = gameobj.vector(keyframe.offset),
            };
            const time: f32 = @floatFromInt(keyframe.time);
            if (at <= time) {
                if (when == time) break;
                const t = (at - when) / (time - when);
                const s: Vector = @splat(1 - t);
                const u: Vector = @splat(t);
                a.angles = before.angles * s + key.angles * u;
                a.offset = before.offset * s + key.offset * u;
                return model.pose(index);
            }
            before = key;
            when = time;
        }
        a.angles = key.angles;
        a.offset = key.offset;
        model.pose(index);
    }

    /// `node_place` (`0x0049A140`): works part `index`'s next place out from its animation's
    /// angles, less those about the axes it doesn't turn about, plus the turret's, and its
    /// offset, and marks it pending and posed.
    pub fn pose(model: *Model, index: usize) void {
        const a = &model.parts[index].animation;
        inline for (0..3) |axis| {
            if (a.still[axis]) a.angles[axis] = 0;
        }
        const turret: Vector = if (a.reversed) .{ a.turret[0], -a.turret[1], -a.turret[2] } else a.turret;
        const posed: Pose = .{ .angles = a.angles + turret, .offset = a.offset };
        a.next = .{ .place = model.placeFor(index, posed), .pose = posed };
        a.pending = true;
        a.posed = true;
    }

    /// Where a pose puts part `index` in the frame it hangs from (`node_place`): its origin in the
    /// model plus the pose's offset, less the origin of the part it hangs from, or less the
    /// object's centre for one at the root, turned about its mount point by the pose's angles in
    /// the part's own frame, which is its orientation transposed, times the angles' turn, times
    /// its orientation. No angles leave it unturned.
    fn placeFor(model: *const Model, index: usize, posed: Pose) Local {
        const part = &model.parts[index];
        const a = &part.animation;
        const turn = math.product(math.product(math.transpose(a.orientation), math.fromAngleVector(posed.angles)), a.orientation);
        const from = if (part.parent) |parent| model.parts[parent].animation.position else model.centre;
        var at = a.position + posed.offset;
        at -= from;
        var lever = a.mount - posed.offset;
        at += lever;
        lever = math.transform(turn, lever);
        at -= lever;
        return .{ .position = at, .orientation = turn };
    }

    /// `node_turn` (`0x0049B520`): turns part `index`'s node by `delta` about its axes besides
    /// its animation, as a turret turns, and marks it animating. About an axis whose limits are
    /// equal it comes round to within a half turn either way; about any other it stays within
    /// them. `pose` places it so.
    ///
    /// **Improvement:** the game turns the limits' degrees to radians by a rounded 0.0174533, and
    /// brings an angle round by 3.14159 and 6.28319; OpenReliant by `std.math.rad_per_deg`, π and
    /// 2π.
    pub fn swivel(model: *Model, index: usize, delta: Vector) void {
        const a = &model.parts[index].animation;
        a.turret += delta;
        model.markAnimating(index);
        inline for (0..3) |axis| {
            const least = a.angles_min[axis];
            const most = a.angles_max[axis];
            if (least == most) {
                a.turret[axis] = math.halfTurn(a.turret[axis]);
            } else {
                if (a.turret[axis] < least * std.math.rad_per_deg) a.turret[axis] = least * std.math.rad_per_deg;
                if (a.turret[axis] > most * std.math.rad_per_deg) a.turret[axis] = most * std.math.rad_per_deg;
            }
        }
    }

    /// `node_play` (`0x0049A2D0`): plays on part `index`'s node the track the loader filed under
    /// `slot`, from `time` unless that is below zero, in `mode`, or the track's own where null, at
    /// `speed` a step. Nothing, where the part has no such track.
    pub fn play(model: *Model, index: usize, slot: Slot, time: f32, mode: ?Mode, speed: f32) void {
        const track = model.parts[index].animation.slots.get(slot) orelse return;
        model.start(index, track, time, mode, speed);
    }

    /// `node_play_named` (`0x0049A340`): likewise for the first of the part's tracks named `name`,
    /// whatever its case.
    pub fn playNamed(model: *Model, index: usize, name: []const u8, time: f32, mode: ?Mode, speed: f32) void {
        for (model.parts[index].animation.tracks, 0..) |track, found| {
            if (!std.ascii.eqlIgnoreCase(track.clip.name(), name)) continue;
            return model.start(index, found, time, mode, speed);
        }
    }

    fn start(model: *Model, index: usize, track: usize, time: f32, mode: ?Mode, speed: f32) void {
        const a = &model.parts[index].animation;
        const chosen = mode orelse @as(Mode, @enumFromInt(@intFromEnum(a.tracks[track].clip.mode)));
        a.track = track;
        a.mode = chosen;
        if (time >= 0) a.time = time;
        a.speed = speed;
        if (chosen != .none) model.markAnimating(index);
    }

    /// `node_mark_animating` (`0x0049A2A0`): marks part `index`'s node as animating, and every
    /// node it hangs from up to the root, unless it is marked already.
    pub fn markAnimating(model: *Model, index: usize) void {
        if (model.parts[index].animation.animating) return;
        var up = model.lineage(index);
        while (up.next()) |part| model.parts[part].animation.animating = true;
    }

    /// `node_tree_frames` (`0x0049A880`) for the model's part nodes and those of the models they
    /// carry, once a frame before it is drawn, `fraction` of the way through the simulation's
    /// step: it walks the root's child list, every part in order whatever it is linked to, and
    /// each shown part's own children, the models it carries. A hidden part keeps its frame, and
    /// so does all it carries.
    pub fn frame(model: *Model, fraction: f32) void {
        for (model.parts, 0..) |*part, index| {
            if (part.hidden) continue;
            model.framePart(index, fraction);
            var each = model.carriedBy(index);
            while (each.next()) |mount| mount.model.frame(fraction);
        }
    }

    /// `node_frame_update` (`0x0049A460`) for part `index`: a node that the last step committed a
    /// new place for is drawn between that place and the next. One the step posed moves between
    /// the two poses, which turns it the short way round; one that moved otherwise moves in a
    /// straight line and turns by a share of the turn between.
    fn framePart(model: *Model, index: usize, fraction: f32) void {
        const part = &model.parts[index];
        const a = &part.animation;
        if (!a.committed and !a.unframed) return;
        a.unframed = false;
        const local: Local = if (fraction == 0) a.now.place else if (!a.posed) between(a.now.place, a.next.place, fraction) else posed: {
            const offset = math.lerp(a.now.pose.offset, a.next.pose.offset, fraction);
            var turned = a.next.pose.angles - a.now.pose.angles;
            inline for (0..3) |axis| turned[axis] = math.halfTurn(turned[axis]);
            const angles = turned * @as(Vector, @splat(fraction)) + a.now.pose.angles;
            break :posed model.placeFor(index, .{ .angles = angles, .offset = offset });
        };
        part.origin = local.position;
        part.turn = local.orientation;
    }

    /// One light for each attachment of kind `light` a part carries, at its place in the model
    /// (`node_mount_light`), with its sprites or the light it casts, or both.
    fn createLights(gpa: Allocator, model: *const shp.Model, images: LightSprites) Allocator.Error![]Light {
        var each: Attached = .of(model, .light);
        const lights = try gpa.alloc(Light, each.count());
        for (lights) |*light| {
            const found = each.next().?;
            const attachment = found.attachment;
            light.* = .{
                .part = found.part,
                .origin = gameobj.vector(attachment.position),
                .blink = .{ .times = attachment.blink, .phase = attachment.blink_phase },
                .sprites = null,
                .cast = null,
            };
            if (attachment.size[0] > 0) {
                light.sprites = .{
                    .colour = lightColour(attachment.light()),
                    .lamp_colour = lampColour(attachment.light()),
                    .size = attachment.size[1],
                    .set = .{ .flags = .{ ._unknown_6 = 1 }, .surface = srapiext.Surface.glow(images.flare), .sprites = &.{} },
                    .sprite = @splat(.{ .bias = attachment.size[0] * bias_width * sprite_bias }),
                    .lamp = srapiext.Surface.glow(images.lamp),
                };
                // The set and its lamp point into the light itself, which does not move again.
                const sprites = &light.sprites.?;
                sprites.sprite[Light.Sprites.lamp_sprite].surface = &sprites.lamp;
                sprites.set.sprites = &sprites.sprite;
                // A sprite whose image the game lacks is left out.
                sprites.sprite[Light.Sprites.flare].hidden = images.flare == null;
                sprites.sprite[Light.Sprites.lamp_sprite].hidden = images.lamp == null;
            }
            const blinks = attachment.blink[0] +% attachment.blink[1] != 0;
            if (attachment.light_brightness > 0 and blinks) {
                light.cast = .{
                    .mask = 0,
                    .intensity = attachment.light_brightness,
                    .colour = lightColour(attachment.light()),
                    .kind = .{ .point = .{ .position = @splat(0), .range = attachment.light_range } },
                };
            }
        }
        return lights;
    }

    /// One glow for each attachment of kind `engine_glow` a part carries, at its place in the model
    /// (`node_mount_glow`). A model carries none while the glows' meshes are not built.
    fn createGlows(gpa: Allocator, model: *const shp.Model, glows: ?*const environfx.Glows) Allocator.Error![]Glow {
        const built = glows orelse return gpa.alloc(Glow, 0);
        var each: Attached = .of(model, .engine_glow);
        const made = try gpa.alloc(Glow, each.count());
        for (made) |*glow| {
            const found = each.next().?;
            const attachment = found.attachment;
            const size: Vector = attachment.size;
            glow.* = .{
                .part = found.part,
                .origin = gameobj.vector(attachment.position),
                .orientation = attachment.orientation,
                .size = size,
                // Its plume burns the way the attachment's Z axis points, so a plume that
                // reaches forward pushes the ship back.
                .retro = size[2] * attachment.orientation[8] > 0,
                .steady = attachment.id == steady_glow,
                .level = .{.{ .mesh = built.mesh(attachment.id), .until = std.math.inf(f32) }},
                .object = .{
                    // Neither culled nor given a level of detail by how far off it is.
                    .flags = .{ .not_culled = true, .always_drawn = true },
                    .position = @splat(0),
                    .radius = @reduce(.Max, @abs(size)),
                    .levels = &.{},
                },
            };
            // The object shows the one mesh its kind shares, which does not change again.
            glow.object.levels = glow.level[0..1];
        }
        return made;
    }

    /// One flash for each attachment of kind `gun_muzzle` a part carries, hidden
    /// (`node_mount_muzzle`). A model carries none while the flashes' meshes are not built.
    fn createFlashes(gpa: Allocator, model: *const shp.Model, looks: ?*const flash.Looks) Allocator.Error![]flash.Flash {
        const built = looks orelse return gpa.alloc(flash.Flash, 0);
        var each: Attached = .of(model, .gun_muzzle);
        const made = try gpa.alloc(flash.Flash, each.count());
        for (made) |*lit| {
            const found = each.next().?;
            lit.init(built, found.part, found.attachment);
        }
        return made;
    }

    /// The attachments of one kind a model's parts carry, part by part and each part's in order,
    /// with the part that carries each, as `node_add_part` mounts them.
    const Attached = struct {
        parts: []const shp.PartData,
        kind: shp.Attachment.Kind,
        /// The part, and the attachment of it, the walk has reached.
        part: usize = 0,
        at: usize = 0,

        const Found = struct {
            part: usize,
            attachment: *const shp.Attachment,
        };

        fn of(model: *const shp.Model, kind: shp.Attachment.Kind) Attached {
            return .{ .parts = model.parts, .kind = kind };
        }

        fn next(each: *Attached) ?Found {
            while (each.part < each.parts.len) : ({
                each.part += 1;
                each.at = 0;
            }) {
                const attachments = each.parts[each.part].attachments;
                while (each.at < attachments.len) {
                    const attachment = &attachments[each.at];
                    each.at += 1;
                    if (attachment.kind == each.kind) return .{ .part = each.part, .attachment = attachment };
                }
            }
            return null;
        }

        /// How many the rest of the walk hands out.
        fn count(each: Attached) usize {
            var rest = each;
            var found: usize = 0;
            while (rest.next()) |_| found += 1;
            return found;
        }
    };

    pub fn deinit(model: Model, gpa: Allocator) void {
        var each = model.carried();
        while (each.next()) |mount| mount.model.deinit(gpa);
        gpa.free(model.mounts);
        gpa.free(model.hung);
        for (model.parts) |part| if (part.cloak) |effect| effect.deinit(gpa);
        gpa.free(model.parts);
        gpa.free(model.order);
        gpa.free(model.lights);
        gpa.free(model.glows);
        gpa.free(model.flashes);
    }

    /// The model each gun and pod attachment holds, mounted on the part that carries it
    /// (`node_mount`). A mount is left out where nothing answers for its model, and a model that
    /// mounts itself stops at `shp.max_mount_depth`.
    fn createMounts(gpa: Allocator, model: *const shp.Model, effects: Effects, depth: usize) Allocator.Error![]Mount {
        const mounts = effects.mounts orelse return gpa.alloc(Mount, 0);
        if (depth >= shp.max_mount_depth) return gpa.alloc(Mount, 0);
        var made: std.ArrayList(Mount) = .empty;
        errdefer {
            for (made.items) |mount| mount.model.deinit(gpa);
            made.deinit(gpa);
        }
        for (model.parts, 0..) |part, index| {
            for (part.attachments, 0..) |attachment, at| {
                const mounted = mounts.of(attachment) orelse continue;
                try made.append(gpa, .{
                    .part = index,
                    .attachment = at,
                    .origin = gameobj.vector(attachment.position),
                    .orientation = attachment.orientation,
                    .model = try build(gpa, mounted.model, mounted.loaded, effects, depth + 1),
                });
                // A mounted model's parts hang as an object's own do, and it stands on its own
                // centre of mass.
                gameobj.linkParts(&made.items[made.items.len - 1].model, mounted.model);
            }
        }
        return made.toOwnedSlice(gpa);
    }

    /// Puts the object's root at `position`, turned by `orientation`, and each part's object with
    /// it: a part standing at the root stands in the root's frame, and one hanging from another
    /// stands in that part's frame, so a part carries what hangs from it
    /// (`SR_object_concate_parents`, `0x004C3490`, for each part's frame).
    pub fn place(model: *Model, position: Vector, orientation: math.Matrix) void {
        model.position = position;
        model.orientation = orientation;
        for (model.order) |index| {
            const part = &model.parts[index];
            const carrier: math.Place = if (part.parent) |parent| model.parts[parent].drawn() else .{ .position = position, .orientation = orientation };
            const at = part.frameWithin(carrier);
            part.object.position = at.position;
            part.object.orientation = at.orientation;
        }
        var each = model.carried();
        while (each.next()) |mount| {
            const at = mount.rootAt(model.parts[mount.part].drawn());
            mount.model.place(at.position, at.orientation);
        }
    }

    /// Where part `index`'s frame stands in the world with the root's at `root`: in the frame of
    /// the part it hangs from, and that one's, up to the root, as `place` puts them
    /// (`SR_object_concate_parents`, `0x004C3570`), whether or not the model has been placed since
    /// its frames last moved. Parents that run in a circle stand at the root once the walk up has
    /// taken as many steps as there are parts, as `lineage` ends it.
    pub fn frameAt(model: *const Model, index: usize, root: math.Place) math.Place {
        return model.frameUp(index, root, model.parts.len);
    }

    fn frameUp(model: *const Model, index: usize, root: math.Place, steps: usize) math.Place {
        const part = &model.parts[index];
        const parent = if (steps == 0) null else part.parent;
        const carrier = if (parent) |up| model.frameUp(up, root, steps - 1) else root;
        return part.frameWithin(carrier);
    }

    /// Whether part `index` plays a track, or a part it hangs from does: a node whose track has a
    /// mode and a speed.
    pub fn moving(model: *const Model, index: usize) bool {
        var up = model.lineage(index);
        while (up.next()) |part| {
            const track = &model.parts[part].animation;
            if (track.mode != .none and track.speed != 0) return true;
        }
        return false;
    }

    /// Which of a node's places: the one the last simulation step committed, or the one the next
    /// takes it to.
    pub const Step = enum { now, next };

    /// Where part `index` stands in the model's frame at `step`: its place in the part it hangs
    /// from, and that part's in its own, up to the root (`lineage`).
    pub fn partPlace(model: *const Model, index: usize, step: Step) math.Place {
        var stands: math.Place = .{};
        var up = model.lineage(index);
        while (up.next()) |part| stands = stands.within(model.parts[part].animation.at(step));
        return stands;
    }

    /// Where part `index` of `held`, this model or one it carries however deep, stands in the world
    /// at `step`, with this model's root at `root` (`node_world_place`, `node_next_place`); null
    /// where it carries no such model.
    pub fn partAt(model: *const Model, root: math.Place, held: *const Model, index: usize, step: Step) ?math.Place {
        return held.partPlace(index, step).within(model.mountedAt(root, held, step) orelse return null);
    }

    /// Where the root of `held`, this model or one it carries however deep, stands at `step`, with
    /// this model's root at `root`; null where it carries no such model. Its parts stand from
    /// there by `partPlace`: together, `node_world_place` (`0x004AD960`) and `node_next_place`
    /// (`0x004AD8D0`).
    ///
    /// **Quirk:** the game skips a parent's turn where its diagonal reads 1, 1 and anything but 1,
    /// which no turn does.
    pub fn mountedAt(model: *const Model, root: math.Place, held: *const Model, step: Step) ?math.Place {
        if (held == model) return root;
        var each = model.carried();
        while (each.next()) |mount| {
            if (mount.model.mountedAt(model.mountRoot(mount, root, step), held, step)) |found| return found;
        }
        return null;
    }

    /// Where the root of `mount`, one this model carries, stands at `step`, with this model's
    /// root at `root`.
    pub fn mountRoot(model: *const Model, mount: *const Mount, root: math.Place, step: Step) math.Place {
        return mount.rootAt(model.partPlace(mount.part, step).within(root));
    }

    /// Each model it carries: those its attachments mount, then those its missile hardpoints
    /// hold.
    pub fn carried(model: Model) Carried {
        return .{ .mounts = model.mounts, .hung = model.hung };
    }

    /// `node_find_named` (`0x004ADD90`): the first part named `name`, in the order the root's
    /// child list holds them, each followed by the models it carries, however deep; null where
    /// none is, or for a model with no file behind it.
    pub fn partNamed(model: *Model, name: []const u8) ?PartRef {
        for (model.source.parts, 0..) |data, index| {
            if (index >= model.parts.len) break;
            if (std.mem.eql(u8, data.part.name(), name)) return .{ .model = model, .index = index };
            var each = model.carriedBy(index);
            while (each.next()) |mount| {
                if (mount.model.partNamed(name)) |found| return found;
            }
        }
        return null;
    }

    /// Whether `other` is this model or one it carries, however deep.
    pub fn holds(model: *const Model, other: *const Model) bool {
        if (model == other) return true;
        var each = model.carried();
        while (each.next()) |mount| {
            if (mount.model.holds(other)) return true;
        }
        return false;
    }

    /// The part a hit on part `index` counts against for the mission's events (`component_damage`,
    /// `0x00464A0A`): the first part left in the model that its record marks a component, of the
    /// part's group (`Part.component_group`) where it has one, else of its assembly; the part
    /// itself where there is none.
    pub fn countedAgainst(model: *Model, index: usize) *Part {
        const struck = &model.parts[index];
        for (model.parts) |*part| {
            if (part.removed or !part.flags.component) continue;
            const same = if (struck.component_group != 0) part.component_group == struck.component_group else part.link_id == struck.link_id;
            if (same) return part;
        }
        return struck;
    }

    /// The parts of assembly `link`, those whose part records share the link id, in part order,
    /// leaving out any taken out of the model.
    pub fn assembly(model: *const Model, link: u32) Assembly {
        return .{ .parts = model.parts, .link = link };
    }

    pub const Assembly = struct {
        parts: []const Part,
        link: u32,
        /// The part after the one handed out last.
        at: usize = 0,

        pub fn next(each: *Assembly) ?usize {
            while (each.at < each.parts.len) {
                const index = each.at;
                each.at += 1;
                const part = &each.parts[index];
                if (!part.removed and part.link_id == each.link) return index;
            }
            return null;
        }
    };

    /// Each model part `index` carries, in the order `carried` has them: the roots among its
    /// node's children.
    pub fn carriedBy(model: Model, index: usize) Carried {
        return .{ .mounts = model.mounts, .hung = model.hung, .on = index };
    }

    /// The part numbered `number` among the model's parts and those of the models it carries,
    /// however deep, counted in the order `hitWalk` walks them: each part, then the models it
    /// carries; null past the last. The game numbers an object's part nodes as it creates the
    /// object (`object_number_parts`) and finds a node by its number (`GameObject.part_nodes`).
    pub fn numbered(model: *Model, number: usize) ?PartRef {
        var count: Counting = .{ .until = .{ .number = number } };
        return if (model.countParts(&count)) count.found else null;
    }

    /// Where `part`, one of this model's parts or of a model it carries however deep, stands in
    /// the world at `step`, with this model's root at `root` (`partAt`); null for a part of
    /// neither.
    pub fn placeOf(model: *Model, root: math.Place, part: *const Part, step: Step) ?math.Place {
        const held = model.holding(part) orelse return null;
        const index = (@intFromPtr(part) - @intFromPtr(held.parts.ptr)) / @sizeOf(Part);
        return model.partAt(root, held, index, step);
    }

    /// The model holding `part`, the model itself or one it carries however deep (`node_holder`,
    /// for the root it hangs from); null for a part of neither.
    pub fn holding(model: *Model, part: *const Part) ?*Model {
        for (model.parts) |*own| if (own == part) return model;
        for (0..model.parts.len) |index| {
            var each = model.carriedBy(index);
            while (each.next()) |mount| if (mount.model.holding(part)) |found| return found;
        }
        return null;
    }

    /// The number of part `ref` (`numbered`); null for a part neither the model's nor carried by
    /// it.
    pub fn numberOf(model: *Model, ref: PartRef) ?usize {
        var count: Counting = .{ .until = .{ .part = ref } };
        return if (model.countParts(&count)) count.counted else null;
    }

    /// A count of the parts in the order `numbered` numbers them, until the part it looks for.
    const Counting = struct {
        until: union(enum) { number: usize, part: PartRef },
        counted: usize = 0,
        found: ?PartRef = null,
    };

    /// Counts the model's parts, then the models each carries, until `count` finds its part:
    /// whether it did.
    fn countParts(model: *Model, count: *Counting) bool {
        for (0..model.parts.len) |index| {
            const ref: PartRef = .{ .model = model, .index = index };
            const reached = switch (count.until) {
                .number => |number| count.counted == number,
                .part => |part| std.meta.eql(ref, part),
            };
            if (reached) {
                count.found = ref;
                return true;
            }
            count.counted += 1;
            var each = model.carriedBy(index);
            while (each.next()) |mount| if (mount.model.countParts(count)) return true;
        }
        return false;
    }

    pub const Carried = struct {
        mounts: []Mount,
        hung: []?Mount,
        /// The part whose models alone it hands out; every part's where null.
        on: ?usize = null,

        pub fn next(each: *Carried) ?*Mount {
            while (each.take()) |mount| {
                if (each.on) |on| if (mount.part != on) continue;
                return mount;
            }
            return null;
        }

        fn take(each: *Carried) ?*Mount {
            if (each.mounts.len > 0) {
                defer each.mounts = each.mounts[1..];
                return &each.mounts[0];
            }
            while (each.hung.len > 0) {
                defer each.hung = each.hung[1..];
                if (each.hung[0]) |*mount| return mount;
            }
            return null;
        }
    };

    /// Adds each shown part's object to `layer`, the world's or, for a cockpit, the overlay
    /// (`node_draw`, `0x0049A8C0`, for the model's part nodes), a cloaked object's parts as its
    /// cloak draws them (`cloak.Drawing`); then the lights, unless the view leaves them out, the
    /// engine glows its shown parts carry, and the muzzle flashes they carry that a shot has lit
    /// (`flash.Flash.show`), with their lights where they cast them. A flash goes into the world's
    /// layer whatever the part's. Nothing, for an object too far off to see.
    ///
    /// Not yet ported: the nodes of kind 6.
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer, view: View) Allocator.Error!void {
        if (view.tooFarOff(model.position, model.radius * model.visibility)) return;
        for (model.parts) |*part| {
            if (part.hidden) continue;
            if (view.cloak) |drawing| {
                if (drawing.shimmer(part, &view)) |shimmer| try xtrabits.sceneAdd(gpa, scene, .{ .mesh = shimmer }, layer);
                if (!drawing.hull(part, &view)) continue;
            }
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, layer);
        }
        for (model.lights) |*light| {
            if (!view.lights) break;
            // A light goes dark with the part that carries it, as a damaged part's does while the
            // part it belongs to is whole.
            if (model.parts[light.part].hidden) continue;
            const blink = light.blink.brightness(view.blink_offset +% view.frame_start);
            if (!(blink > 0)) continue;
            const world = model.parts[light.part].drawn().point(light.origin);
            if (light.sprites) |*sprites| {
                sprites.set.position = world;
                sprites.show(blink, math.distance(world, view.camera));
                try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &sprites.set }, layer);
            }
            if (light.cast) |*cast| {
                cast.kind.point.position = world;
                try xtrabits.sceneAdd(gpa, scene, .{ .light = cast }, layer);
            }
        }
        for (model.glows) |*glow| {
            if (!view.glows) break;
            // A glow goes out with the part that carries it, as a light does.
            if (model.parts[glow.part].hidden) continue;
            const burning = glow.plume(view.throttle, view.random) orelse continue;
            const carrier = model.parts[glow.part].drawn();
            glow.object.position = carrier.point(glow.origin);
            // The plume stands as its attachment does, drawn to the size it gives it.
            const scale = math.scaling(glow.size * Vector{ 1, 1, burning });
            glow.object.orientation = math.product(math.product(carrier.orientation, glow.orientation), scale);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &glow.object }, layer);
        }
        for (model.flashes) |*lit| {
            // A flash goes out of sight with the part that carries it, as a light does.
            const carrier = &model.parts[lit.part];
            if (carrier.hidden) continue;
            if (!lit.show(view.frame_start, carrier.drawn())) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &lit.object }, .world);
            if (lit.light) |*light| try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .world);
        }
        var each = model.carried();
        while (each.next()) |mount| {
            // What a hidden part carries is hidden with it, as a light and a glow are.
            if (model.parts[mount.part].hidden) continue;
            try mount.model.draw(gpa, scene, layer, view);
        }
    }

    /// OpenReliant's: adds each shown part's object, and those of the models it mounts, to the
    /// scene's casters, which throw their shadows without being drawn (`srshadow`).
    pub fn castShadows(model: *Model, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        for (model.parts) |*part| {
            if (!part.hidden) try scene.casters.append(gpa, &part.object);
        }
        var each = model.carried();
        while (each.next()) |mount| {
            if (!model.parts[mount.part].hidden) try mount.model.castShadows(gpa, scene);
        }
    }
};

/// What a model draws its attachments with: the sprites every light draws, the meshes the engine
/// glows and the muzzle flashes draw, and where the models a gun or a pod attachment holds come
/// from. A model carries only the ones it is given.
pub const Effects = struct {
    light_sprites: LightSprites = .{},
    glows: ?*const environfx.Glows = null,
    flashes: ?*const flash.Looks = null,
    mounts: ?Mounts = null,
};

/// Where the model an attachment point holds comes from: a gun's or a pod's, parsed and built the
/// way the ship's own is, and living at least as long as the model that mounts it. Whoever has the
/// game's files answers; `load` returns null for a model the game lacks, which mounts nothing.
pub const Mounts = struct {
    context: *anyopaque,
    /// Null for a model the game lacks or cannot read; whoever answers says why.
    load: *const fn (context: *anyopaque, file: []const u8) ?Mounted,

    pub const Mounted = srofiles.ModelFile;

    /// The model `attachment` mounts, or null where its kind mounts none, the table names none, or
    /// the game lacks the file (`node_mount`, `0x00499A10`).
    fn of(mounts: Mounts, attachment: shp.Attachment) ?Mounted {
        switch (attachment.kind) {
            .gun, .pod => {},
            else => return null,
        }
        const entry = create.models.attachment(attachment.kind, attachment.id) orelse return null;
        const file = entry.model orelse return null;
        return mounts.load(mounts.context, file);
    }
};

/// What a model's lights are drawn by: where the camera stands, since a light's size and brightness
/// follow how far off it is, and the frame's tick, which says where each light stands in its blink.
pub const View = struct {
    camera: Vector = @splat(0),
    /// `frame_start`, the mission tick the frame began on.
    frame_start: i32 = 0,
    /// The object's own offset into its lights' blinks (`GameObject.blink_offset`), which the
    /// lights of what it mounts share.
    blink_offset: i16 = 0,
    /// Whether its lights are drawn: `DisableLights` puts them out, for which `mission_frame` hands
    /// `node_draw` flag 8, which leaves out the nodes of kind 4 attachments.
    lights: bool = true,
    /// Whether its engines' glows are drawn: `object_draw` hands `node_draw` flag 4 for a capital
    /// ship splitting in two, which leaves out the nodes of engine glow attachments.
    glows: bool = true,
    /// How hard the object is burning, between -1 and 1, which is how far its engine glows reach.
    /// `object_draw` is given the throttle of its last update, dimmed by the share of its engines
    /// still standing.
    throttle: f32 = 0,
    /// Where the glows' flicker comes from; without one they burn steady.
    random: ?*libcmt.Rand = null,
    /// Pixels to a view unit across the screen (`srapi.Projection.scale`), which says how far off
    /// an object stops being worth drawing. Zero draws one however far off it stands.
    scale: f32 = 0,
    /// How a cloaked object's cloak draws its parts (`node_draw`'s flag `0x80`); null for an
    /// object not cloaked.
    cloak: ?cloak.Drawing = null,
    /// Whether the game is paused, and whether a hardware renderer draws (`sr + 0x1AC`), which a
    /// cloak draws by (`cloak.Drawing`).
    paused: bool = false,
    hardware: bool = true,

    /// Whether an object of `radius` standing at `at` is too far off to be worth drawing
    /// (`node_draw`): its radius no longer covers a pixel, since the radius over the distance,
    /// times the screen's scale, is how many pixels across it is drawn.
    pub fn tooFarOff(view: View, at: Vector, radius: f32) bool {
        if (!(view.scale > 0)) return false;
        const reach = view.scale * radius;
        const away = at - view.camera;
        return reach * reach < math.dot(away, away);
    }
};

/// The share of a simulation step each game tick takes, which `node_frame_update` counts in, and
/// what turns a velocity a step into one a tick.
pub const tick_share: f32 = 1.0 / @as(f32, @import("gameobj.zig").ticks_per_step);

/// How far into its step the simulation is, which `node_frame_update` draws each object between
/// its last two places by: a quarter for each tick since the step (`simulation_counter`).
///
/// **Improvement:** with `smooth`, the time past the last tick counts as well, so that what
/// moves moves on every frame rather than every tick, and evenly at any display rate; the
/// original moves it on in hundredths of a second, which a display's frames fall between
/// unevenly. While the game is paused nothing moves, so the time past the tick doesn't count.
pub fn stepFraction(clock: *const Clock, smooth: bool) f32 {
    const ticks: f32 = @floatFromInt(clock.simulation_counter);
    return (ticks + pastTick(clock, smooth)) * tick_share;
}

/// How far past its last tick the frame is drawn, as a share of a tick: what the effects, which
/// move by their velocities a tick, are drawn that much further along by. None without `smooth`
/// or while the game is paused, as `stepFraction` counts it.
pub fn pastTick(clock: *const Clock, smooth: bool) f32 {
    return if (!smooth or clock.paused) 0 else clock.past_tick;
}

/// How far along a frame is drawn: `fraction` of the way through the simulation's step
/// (`stepFraction`), and `ahead` of a tick past the last tick (`pastTick`).
pub const Timing = struct {
    fraction: f32 = 0,
    ahead: f32 = 0,

    pub fn of(clock: *const Clock, smooth: bool) Timing {
        return .{ .fraction = stepFraction(clock, smooth), .ahead = pastTick(clock, smooth) };
    }
};

/// Where `node_frame_update` draws a node that moved rather than posed, `fraction` of the way from
/// `now` to `next`: along the straight line between, and turned from `now` by that share of the
/// angles that turn it to `next`.
fn between(now: Model.Local, next: Model.Local, fraction: f32) Model.Local {
    const position = math.lerp(now.position, next.position, fraction);
    const angles = math.angles(math.product(math.transpose(now.orientation), next.orientation)) * @as(Vector, @splat(fraction));
    return .{ .position = position, .orientation = math.product(now.orientation, math.fromAngleVector(angles)) };
}

/// The glow that burns at its full length whatever the throttle, the last of the seven
/// (`node_draw`).
const steady_glow = environfx.glow_kinds;

/// The least of its length a plume ever flickers down to, and how far above that it reaches.
const flicker_least: f32 = 0.8;
const flicker_range: f32 = 0.2;

comptime {
    assert(flicker_least + flicker_range == 1);
}

/// What a plume's length is scaled by this frame: somewhere between `flicker_least` and its whole
/// length, so that a burning engine is never quite still (`node_draw`).
fn flicker(random: ?*libcmt.Rand) f32 {
    const source = random orelse return 1;
    return source.fraction() * flicker_range + flicker_least;
}

/// The sprites every light draws, whatever its colour (`node_mount_light`): the flare, which
/// attachment kind 4 id 0 names, and the lamp, which id 1 names.
pub const LightSprites = struct {
    flare: ?*srtexture.Image = null,
    lamp: ?*srtexture.Image = null,

    pub fn load(textures: *srtexture.Table) matmanager.Error!LightSprites {
        return .{ .flare = try sprite(textures, 0), .lamp = try sprite(textures, 1) };
    }

    fn sprite(textures: *srtexture.Table, id: u32) matmanager.Error!?*srtexture.Image {
        const entry = create.models.attachment(.light, id) orelse return null;
        const name = entry.sprite orelse return null;
        return try matmanager.textureRequire(textures, name);
    }
};

/// Where `attachment` stands on its part, and how it is turned there: a muzzle's, a flash's, a case
/// ejector's or an eject point's.
pub fn attachmentPlace(attachment: *const shp.Attachment) math.Place {
    return .{ .position = gameobj.vector(attachment.position), .orientation = attachment.orientation };
}

test attachmentPlace {
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.position = .{ .x = 1, .y = 2, .z = 3 };
    attachment.orientation = math.rotation(.y, 1);
    const place = attachmentPlace(&attachment);
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, place.position);
    try std.testing.expectEqual(attachment.orientation, place.orientation);
}

/// The colour of a light: its flare's, and the light it casts (`node_draw`, `node_mount_light`).
/// Past the sixth it takes none.
pub fn lightColour(light: shp.Attachment.Light) [3]f32 {
    return switch (light) {
        .blue => .{ 0, 0, 1 },
        .green => .{ 0, 1, 0 },
        .yellow => .{ 1, 1, 0 },
        .red => .{ 1, 0, 0 },
        .cyan => .{ 0, 1, 1 },
        .white => .{ 1, 1, 1 },
        _ => .{ 0, 0, 0 },
    };
}

/// The paler colour of a light's lamp (`node_draw`). Past the sixth it takes none.
fn lampColour(light: shp.Attachment.Light) [3]f32 {
    return switch (light) {
        .blue => .{ 0.2, 0.5, 1 },
        .green => .{ 0.5, 1, 0.5 },
        .yellow => .{ 1, 1, 0.5 },
        .red => .{ 1, 0.5, 0.2 },
        .cyan => .{ 0.5, 1, 1 },
        .white => .{ 1, 1, 1 },
        _ => .{ 0, 0, 0 },
    };
}

/// How far a light's flare reaches at its largest, and its lamp, over the attachment's height.
const flare_scale: f32 = 7;
const lamp_scale: f32 = 0.3;

/// The share of its colour a light's flare takes.
const flare_share: f32 = 0.5;

/// What a light's two sprites add to their depth for sorting, over the attachment's width times
/// `bias_width` (`node_mount_light`): both sort a little nearer than they stand.
const sprite_bias: f32 = -0.25;
const bias_width: f32 = 9;

/// A light's blink runs on a clock of ten to the tick (`node_draw`), and fades out over this much
/// of it.
const blink_clock_per_tick = 10;
const blink_fade = 200;

/// The least brightness in its blink at which a light still shows its lamp.
const lamp_least: f32 = 0.9;

/// A light's flare is at its brightest up to `full_at` units off and fades to `faded` of that by
/// `faded_at`, staying there beyond; it grows with how far off it is up to `grown_at`, so that it
/// stays worth seeing at a distance.
const full_at: f32 = 1000;
const faded_at: f32 = 15000;
const faded: f32 = 0.1;
const grown_at: f32 = 6000;

/// Hangs each part of `model` from its parent as `gameobj.linkParts` does, leaving its origin
/// where it is.
fn testingLink(model: *Model) void {
    for (0..model.parts.len) |index| gameobj.linkPart(model, index);
}

/// A part record for the tests: nothing in it but an orientation, which every model's part has.
fn testingPart() shp.PartData {
    var data = std.mem.zeroes(shp.PartData);
    data.part.orientation = math.identity;
    return data;
}

/// Fixtures for the tests here and in the modules that build models.
pub const testing = struct {
    /// A part with no mesh, no mass and no tracks, standing unturned at the model's origin.
    pub const part = testingPart;
    /// A track's clip of `length`, played in `mode`, named `name`.
    pub const clip = testingClip;

    /// Mounts that answer every attachment with `fixture`'s model.
    pub fn mountsOf(fixture: *create.testing.Model) Mounts {
        return .{ .context = fixture, .load = loadFixture };
    }

    fn loadFixture(context: *anyopaque, _: []const u8) ?Mounts.Mounted {
        const fixture: *create.testing.Model = @ptrCast(@alignCast(context));
        return .{ .model = &fixture.source, .loaded = &fixture.loaded };
    }

    /// A model of one part with no mesh, hanging from the root, whose one attachment, a gun's at
    /// `at`, unturned, mounts the model it is built with. It is set up where it stays, since its
    /// records point into it.
    pub const Carrier = struct {
        attachments: [1]shp.Attachment,
        data: [1]shp.PartData,
        source: shp.Model,
        loaded_parts: [1]srofiles.LoadedPart,
        loaded: srofiles.Loaded,

        pub fn init(carrier: *Carrier, at: Vector) void {
            carrier.attachments = .{std.mem.zeroes(shp.Attachment)};
            carrier.attachments[0].kind = .gun;
            carrier.attachments[0].position = gameobj.vec3(at);
            carrier.attachments[0].orientation = math.identity;
            carrier.data = .{testingPart()};
            carrier.data[0].part.parent = -1;
            carrier.data[0].attachments = &carrier.attachments;
            carrier.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &carrier.data, .trailing_bytes = 0 };
            carrier.loaded_parts = .{.{ .flags = .{}, .levels = &.{}, .meshes = &.{} }};
            carrier.loaded = .{ .parts = &carrier.loaded_parts };
        }

        /// Its model, its attachment mounting `gun`'s.
        pub fn build(carrier: *const Carrier, gpa: Allocator, gun: *create.testing.Model) Allocator.Error!Model {
            return .create(gpa, &carrier.source, &carrier.loaded, .{ .mounts = mountsOf(gun) });
        }
    };
};

test "Node.commitNext" {
    var node: Node = std.mem.zeroes(Node);
    node.next_position = .{ .x = 1, .y = 2, .z = 3 };
    node.next_orientation = .{ 0, 1, 0, 1, 0, 0, 0, 0, 1 };
    node.next_pose.offset.z = 7;
    node.flags.posed = true;
    // Nothing pending: only bits 1 and 3 are cleared.
    node.commitNext();
    try std.testing.expectEqual(0, node.position.x);
    try std.testing.expect(!node.flags.posed);
    // Pending: the whole next block is committed, and the flags say so.
    node.flags.next_pending = true;
    node.commitNext();
    try std.testing.expectEqual(node.next_position, node.position);
    try std.testing.expectEqual(node.next_orientation, node.orientation);
    try std.testing.expectEqual(7, node.pose.offset.z);
    try std.testing.expect(!node.flags.next_pending and node.flags.committed and node.flags.unframed);
    // The next visit clears bit 1 again but leaves bit 2.
    node.commitNext();
    try std.testing.expect(!node.flags.committed and node.flags.unframed);
}

test lightMask {
    try std.testing.expectEqual(0x18, lightMask(true));
    try std.testing.expectEqual(0x03, lightMask(false));
}

test "Node.Kind" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("muzzle", try std.fmt.bufPrint(&buffer, "{f}", .{Node.Kind.muzzle}));
    try std.testing.expectEqualStrings("node kind 9", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Node.Kind, @enumFromInt(9))}));
}

test "Model.Attached" {
    var attachments = [3]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    attachments[0].kind = .light;
    attachments[1].kind = .gun_muzzle;
    attachments[2].kind = .light;
    var data = [2]shp.PartData{ testingPart(), testingPart() };
    data[0].attachments = attachments[0..2];
    data[1].attachments = attachments[2..3];
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .trailing_bytes = 0 };
    // The lights, part by part, each with its part; a kind none carries, none.
    var each: Model.Attached = .of(&source, .light);
    try std.testing.expectEqual(2, each.count());
    const first = each.next().?;
    try std.testing.expectEqual(0, first.part);
    try std.testing.expectEqual(&attachments[0], first.attachment);
    try std.testing.expectEqual(1, each.count());
    try std.testing.expectEqual(1, each.next().?.part);
    try std.testing.expectEqual(null, each.next());
    try std.testing.expectEqual(0, Model.Attached.of(&source, .pod).count());
}

test {
    std.testing.refAllDecls(@This());
}

test Model {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = .{ 0, 0, 100 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    // A light standing on that part, at its own place on it.
    var lights = [_]Model.Light{.{
        .part = 0,
        .origin = .{ 0, 0, 0 },
        .blink = .{},
        .sprites = .{
            .colour = .{ 1, 0, 0 },
            .lamp_colour = .{ 1, 0.5, 0.2 },
            .size = 10,
            .set = .{ .sprites = &.{} },
            .sprite = @splat(.{}),
            .lamp = srapiext.Surface.glow(null),
        },
        .cast = null,
    }};
    lights[0].sprites.?.set.sprites = &lights[0].sprites.?.sprite;
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &lights, .glows = &.{}, .mounts = &.{} };
    // A part hangs at its origin, turned with the root.
    model.place(.{ 1000, 0, 0 }, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(1100, parts[0].object.position[0], 1e-3);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try model.draw(gpa, &scene, .world, .{});
    // Its one part and the light standing on it.
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    // Recentred on its one part's mass, its origin moves to the part's centre: 100 along Z, plus
    // the part's own first moment over its volume.
    var data = testingPart();
    data.part.volume = 2;
    data.part.density = 3;
    data.part.first_moments = .{ 0, 0, 20 };
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = (&data)[0..1], .trailing_bytes = 0 };
    gameobj.recentre(&model, &source);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 110 }), model.centre);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -10 }), parts[0].origin);
    // A light hangs on the part that carries it, so recentring leaves it where it stood on the
    // hull: drawn, its sprite stands where the part does.
    model.place(@splat(0), math.identity);
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(parts[0].object.position, lights[0].sprites.?.set.position);
    model.place(.{ 1000, 0, 0 }, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@sqrt(100.0 * 100.0 * 2.0 + 10.0 * 10.0), model.radius, 1e-3);

    // The part and its light are both drawn; hidden, the part takes its light with it.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    parts[0].hidden = true;
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    parts[0].hidden = false;

    // With its lights out, the part alone.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{ .lights = false });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

test lightColour {
    // The six the drawing knows, and nothing beyond them.
    try std.testing.expectEqual([3]f32{ 0, 0, 1 }, lightColour(.blue));
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, lightColour(.red));
    try std.testing.expectEqual([3]f32{ 0, 1, 1 }, lightColour(.cyan));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, lightColour(.white));
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lightColour(@enumFromInt(6)));
}

test lampColour {
    // Paler than the light's own colour, and nothing past the sixth.
    try std.testing.expectEqual([3]f32{ 0.2, 0.5, 1 }, lampColour(.blue));
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0.2 }, lampColour(.red));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, lampColour(.white));
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lampColour(@enumFromInt(6)));
}

test "Model.Blink.brightness" {
    // A light that does not blink is always full on.
    var blink: Model.Blink = .{};
    try std.testing.expectEqual(1, blink.brightness(0));
    try std.testing.expectEqual(1, blink.brightness(12_345));

    // On for 1000 of its clock, then off for 1000; the clock runs ten to the tick.
    blink.times = .{ 1000, 1000 };
    try std.testing.expectEqual(1, blink.brightness(0));
    try std.testing.expectEqual(1, blink.brightness(100)); // at 1000, still on
    // Just past the on time it fades, and by 200 of its clock it is out.
    try std.testing.expectEqual(0.5, blink.brightness(110));
    try std.testing.expect(blink.brightness(120) <= 0);
    // Its phase shifts where it stands: the same light started later is still on.
    blink.phase = 1000;
    try std.testing.expectEqual(1, blink.brightness(110));
    // Before its phase has passed, its clock wraps as an unsigned number does: at 796 of the
    // 2000, still on, where a signed remainder would put it at 1500, out.
    blink.phase = 500;
    try std.testing.expectEqual(1, blink.brightness(0));
}

test "Model.Light.Sprites.show" {
    var sprites: Model.Light.Sprites = .{
        .colour = .{ 1, 0, 0 },
        .lamp_colour = .{ 1, 0.5, 0.2 },
        .size = 10,
        .set = .{ .sprites = &.{} },
        .sprite = @splat(.{}),
        .lamp = srapiext.Surface.glow(null),
    };
    const flare = &sprites.sprite[Model.Light.Sprites.flare];
    const lamp = &sprites.sprite[Model.Light.Sprites.lamp_sprite];

    // Near and full on: the flare takes half the colour and grows with how far off it is; the lamp
    // keeps its own size and its paler colour.
    sprites.show(1, 600);
    try std.testing.expectEqual([3]f32{ 0.5, 0, 0 }, flare.colour);
    try std.testing.expectApproxEqAbs(7, flare.half_size[0], 1e-5);
    try std.testing.expectEqual(flare.half_size[0], flare.half_size[1]);
    try std.testing.expectEqual([2]f32{ 3, 3 }, lamp.half_size);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0.2 }, lamp.colour);

    // Fading in its blink, the lamp goes out at once while the flare dims.
    sprites.show(0.5, 600);
    try std.testing.expectEqual([3]f32{ 0.25, 0, 0 }, flare.colour);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lamp.colour);

    // Past six thousand units the flare stops growing; from a thousand it fades, to a tenth by
    // fifteen thousand, and stays there beyond.
    sprites.show(1, 8000);
    try std.testing.expectEqual([2]f32{ 70, 70 }, flare.half_size);
    try std.testing.expectApproxEqAbs(0.275, flare.colour[0], 1e-6);
    sprites.show(1, 100_000);
    try std.testing.expectApproxEqAbs(0.05, flare.colour[0], 1e-6);

    // Brighter than full is held at full.
    sprites.show(2, 0);
    try std.testing.expectEqual([3]f32{ 0.5, 0, 0 }, flare.colour);
    try std.testing.expectEqual([2]f32{ 0, 0 }, flare.half_size);
}

test "a model's lights: their sprites, and the light a blinking one casts" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [1]srofiles.LoadedPart{.{ .flags = .{}, .levels = &levels, .meshes = &.{} }};
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };

    // Three lights on one hull: a steady one with a width; a blinking red one with a brightness
    // but no width; a blinking one with a width but no brightness.
    var attachments: [3]shp.Attachment = @splat(.{
        .kind = .light,
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .orientation = math.identity,
        .id = 0,
        .later_tiers = @splat(0),
        .size = .{ 2, 3, 0 },
        .blink = .{ 0, 0 },
        .blink_phase = 0,
        ._unknown_60 = @splat(0),
        .gun_type = 0,
        ._unknown_68 = @splat(0),
        .light_range = 50,
        .light_brightness = 1,
    });
    attachments[1].position = .{ .x = 40, .y = 0, .z = 0 };
    attachments[1].id = 3;
    attachments[1].size = .{ 0, 3, 0 };
    attachments[1].blink = .{ 1000, 1000 };
    attachments[1].light_brightness = 2;
    attachments[2].blink = .{ 1000, 1000 };
    attachments[2].light_brightness = 0;
    var hull = [1]shp.PartData{testingPart()};
    hull[0].part.parent = -1;
    hull[0].attachments = &attachments;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &hull, .trailing_bytes = 0 };

    var flare: srtexture.Image = .{ .levels = &.{} };
    var lamp: srtexture.Image = .{ .levels = &.{} };
    var built: Model = try .create(gpa, &model, &loaded, .{ .light_sprites = .{ .flare = &flare, .lamp = &lamp } });
    defer built.deinit(gpa);
    testingLink(&built);

    // Sprites for the two with a width, sorting nearer by their width; the lamp drawn with its
    // own image, the flare with the set's.
    const steady = built.lights[0].sprites.?;
    try std.testing.expectEqual(-4.5, steady.sprite[Model.Light.Sprites.flare].bias);
    try std.testing.expectEqual(-4.5, steady.sprite[Model.Light.Sprites.lamp_sprite].bias);
    try std.testing.expectEqual(null, steady.sprite[Model.Light.Sprites.flare].surface);
    try std.testing.expectEqual(&built.lights[0].sprites.?.lamp, steady.sprite[Model.Light.Sprites.lamp_sprite].surface.?);
    try std.testing.expectEqual(&lamp, steady.lamp.textures[0].image);
    try std.testing.expectEqual(null, built.lights[1].sprites);
    try std.testing.expect(built.lights[2].sprites != null);
    // A light only for the blinking one with a brightness: its colour, reaching its brightness
    // times its range, and every object that takes lights.
    try std.testing.expectEqual(null, built.lights[0].cast);
    try std.testing.expectEqual(null, built.lights[2].cast);
    const cast = built.lights[1].cast.?;
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, cast.colour);
    try std.testing.expectEqual(2, cast.intensity);
    try std.testing.expectEqual(50, cast.kind.point.range);
    try std.testing.expect(cast.reaches(lightMask(false)) and cast.reaches(lightMask(true)));

    // Drawn, the hull and the two sets go to the layer and the cast light to the lights, where
    // the light stands on the hull.
    built.place(.{ 0, 0, 1000 }, math.identity);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual(@as(Vector, .{ 40, 0, 1000 }), scene.lights.items[0].kind.point.position);
    // Out in its blink, the blinking lights show nothing and cast nothing; the object's offset
    // moves them through it.
    scene.clear();
    try built.draw(gpa, &scene, .world, .{ .frame_start = 150 });
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(0, scene.lights.items.len);
    scene.clear();
    try built.draw(gpa, &scene, .world, .{ .frame_start = 150, .blink_offset = 60 });
    try std.testing.expectEqual(1, scene.lights.items.len);
}

test "an engine glow burns with the throttle" {
    const forward: Model.Glow = .{
        .part = 0,
        .origin = @splat(0),
        .orientation = math.identity,
        .size = .{ 10, 10, 40 },
        .retro = false,
        .steady = false,
        .level = undefined,
        .object = undefined,
    };
    var retro = forward;
    retro.retro = true;
    var steady = forward;
    steady.steady = true;

    // Without a source of flicker a plume burns at just the throttle it is given.
    try std.testing.expectEqual(0.5, forward.plume(0.5, null));
    try std.testing.expectEqual(null, forward.plume(0, null));
    try std.testing.expectEqual(null, forward.plume(-1, null));
    // A retro thruster burns the other way round, on reverse thrust alone.
    try std.testing.expectEqual(null, retro.plume(0.5, null));
    try std.testing.expectEqual(1, retro.plume(-1, null));
    // The steady glow burns full whatever the throttle, and never flickers.
    var random: libcmt.Rand = .{};
    try std.testing.expectEqual(1, steady.plume(0, &random));
    try std.testing.expectEqual(1, steady.plume(-1, &random));
    try std.testing.expectEqual(1, random.seed);

    // A flicker takes a burning plume down by at most a fifth, never past its full length.
    for (0..100) |_| {
        const burning = forward.plume(1, &random).?;
        try std.testing.expect(burning >= flicker_least and burning <= 1);
    }
    try std.testing.expect(random.seed != 1);
}

test "a model draws the muzzle flashes a shot has lit" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const built: flash.testing.Built = try .init(gpa, .{});
    defer built.deinit(gpa);
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};

    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = .{ 0, 0, 0 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var muzzle = std.mem.zeroes(shp.Attachment);
    muzzle.kind = .gun_muzzle;
    muzzle.gun_type = 1;
    muzzle.position = .{ .x = 0, .y = 0, .z = 50 };
    muzzle.orientation = math.identity;
    var flashes: [1]flash.Flash = undefined;
    flashes[0].init(&built.looks, 0, &muzzle);
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &.{}, .flashes = &flashes, .mounts = &.{} };
    model.place(.{ 0, 0, 1000 }, math.identity);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Until a shot lights it, only the part is drawn.
    try model.draw(gpa, &scene, .overlay, .{ .frame_start = 10 });
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    // Lit, it stands on its muzzle, in the world's layer whatever the part's, and casts its light.
    flashes[0].fire(.laser_cannon, 10, .{ 0, 0.5, 1 });
    try model.draw(gpa, &scene, .overlay, .{ .frame_start = 10 });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1050 }), flashes[0].object.position);
    try std.testing.expectEqual(1, scene.lights.items.len);

    // A flash goes out of sight with the part that carries it.
    parts[0].hidden = true;
    try model.draw(gpa, &scene, .overlay, .{ .frame_start = 10 });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

test "a model draws the glows its parts carry" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const built: environfx.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};

    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = .{ 0, 0, 0 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var glows = [_]Model.Glow{.{
        .part = 0,
        .origin = .{ 0, 0, -50 },
        .orientation = math.identity,
        .size = .{ 5, 5, 20 },
        .retro = false,
        .steady = false,
        .level = .{.{ .mesh = built.glows.mesh(1), .until = std.math.inf(f32) }},
        .object = .{ .flags = .{ .not_culled = true }, .position = @splat(0), .radius = 20, .levels = &.{} },
    }};
    glows[0].object.levels = glows[0].level[0..1];
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &glows, .mounts = &.{} };
    model.place(.{ 0, 0, 1000 }, math.identity);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Idle, the ship burns nothing: only its part is drawn.
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);

    // At half throttle the plume stands where its attachment does, half as long as it reaches.
    try model.draw(gpa, &scene, .world, .{ .throttle = 0.5 });
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 950 }), glows[0].object.position);
    try std.testing.expectEqual(5, glows[0].object.orientation[0]);
    try std.testing.expectEqual(10, glows[0].object.orientation[8]);

    // A glow goes out with the part that carries it.
    parts[0].hidden = true;
    try model.draw(gpa, &scene, .world, .{ .throttle = 1 });
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
}

test "a part hangs from the part it names" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);

    // Three parts: a hull at the model's origin, a turret standing on it, and a barrel on the
    // turret. The barrel comes first, so the order has to sort them out.
    var data = [3]shp.PartData{
        testingPart(),
        testingPart(),
        testingPart(),
    };
    data[0].part.position = .{ .x = 0, .y = 0, .z = 300 };
    data[0].part.parent = 1;
    data[1].part.position = .{ .x = 0, .y = 0, .z = 100 };
    data[1].part.parent = 2;
    data[2].part.position = .{ .x = 0, .y = 0, .z = 0 };
    data[2].part.parent = -1;
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .trailing_bytes = 0 };

    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [3]srofiles.LoadedPart{
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
    };
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };
    var model: Model = try .create(gpa, &source, &loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // Each hangs from the part it names, and stands at its origin in that part.
    try std.testing.expectEqual(@as(?usize, 1), model.parts[0].parent);
    try std.testing.expectEqual(@as(?usize, 2), model.parts[1].parent);
    try std.testing.expectEqual(@as(?usize, null), model.parts[2].parent);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 200 }), model.parts[0].origin);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 100 }), model.parts[1].origin);
    // The hull comes before the turret, and the turret before the barrel.
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, model.order);

    // Placed, each stands where the model puts it, whatever it hangs from.
    model.place(.{ 1000, 0, 0 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 1000, 0, 300 }), model.parts[0].object.position);
    try std.testing.expectEqual(@as(Vector, .{ 1000, 0, 100 }), model.parts[1].object.position);

    // Turned, a part carries what hangs from it: a quarter turn about Y puts them along X.
    model.place(@splat(0), math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(300, model.parts[0].object.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(100, model.parts[1].object.position[0], 1e-3);

    // A part's frame stands where placing the model would put it, the model placed or not.
    const root: math.Place = .{ .position = .{ 0, 50, 0 }, .orientation = math.rotation(.x, 0.5) };
    const barrel = model.frameAt(0, root);
    model.place(root.position, root.orientation);
    try std.testing.expectEqual(model.parts[0].drawn(), barrel);
}

test "a part whose parents run in a circle stands at the root" {
    const gpa = std.testing.allocator;
    var data = [2]shp.PartData{ testingPart(), testingPart() };
    data[0].part.parent = 1;
    data[1].part.parent = 0;
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .trailing_bytes = 0 };
    const order = try Model.linkOrder(gpa, &source);
    defer gpa.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, order);
}

test "a gun attachment mounts the model its id names" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [1]srofiles.LoadedPart{.{ .flags = .{}, .levels = &levels, .meshes = &.{} }};
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };

    // The gun the mount answers with: one part at the model's origin.
    var gun_data = [1]shp.PartData{testingPart()};
    gun_data[0].part.parent = -1;
    gun_data[0].part.volume = 1;
    gun_data[0].part.density = 1;
    const gun: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &gun_data, .trailing_bytes = 0 };

    // A hull carrying one gun attachment, out along X, and one of a kind that mounts nothing.
    var attachments = [2]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    attachments[0] = .{
        .kind = .gun,
        .position = .{ .x = 50, .y = 0, .z = 0 },
        .orientation = math.identity,
        .id = 0,
        .later_tiers = @splat(0),
        .size = @splat(0),
        .blink = .{ 0, 0 },
        .blink_phase = 0,
        ._unknown_60 = @splat(0),
        .gun_type = 0,
        ._unknown_68 = @splat(0),
        .light_range = 0,
        .light_brightness = 0,
    };
    attachments[1] = attachments[0];
    attachments[1].kind = .missile;
    var hull = [1]shp.PartData{testingPart()};
    hull[0].part.parent = -1;
    hull[0].attachments = &attachments;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &hull, .trailing_bytes = 0 };

    const Answer = struct {
        gun: *const shp.Model,
        loaded: *const srofiles.Loaded,
        asked: usize = 0,
        fn load(context: *anyopaque, file: []const u8) ?Mounts.Mounted {
            const answer: *@This() = @ptrCast(@alignCast(context));
            answer.asked += 1;
            // Only the gun the table names for kind 1 id 0 is answered for.
            if (!std.mem.eql(u8, file, create.models.attachment(.gun, 0).?.model.?)) return null;
            return .{ .model = answer.gun, .loaded = answer.loaded };
        }
    };
    var answer: Answer = .{ .gun = &gun, .loaded = &loaded };
    var built: Model = try .create(gpa, &model, &loaded, .{
        .mounts = .{ .context = &answer, .load = Answer.load },
    });
    defer built.deinit(gpa);
    testingLink(&built);

    // Only the gun is mounted; the missile attachment mounts nothing and is not even looked for.
    try std.testing.expectEqual(1, built.mounts.len);
    try std.testing.expectEqual(1, answer.asked);
    try std.testing.expectEqual(0, built.mounts[0].part);
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 0 }), built.mounts[0].origin);
    try std.testing.expectEqual(1, built.mounts[0].model.parts.len);

    // The parts are numbered from the hull's, then the gun's it carries; none past them.
    const gun_part: PartRef = .{ .model = &built.mounts[0].model, .index = 0 };
    try std.testing.expectEqual(PartRef{ .model = &built, .index = 0 }, built.numbered(0).?);
    try std.testing.expectEqual(gun_part, built.numbered(1).?);
    try std.testing.expectEqual(null, built.numbered(2));
    try std.testing.expectEqual(1, built.numberOf(gun_part));
    try std.testing.expectEqual(null, built.numberOf(.{ .model = &built, .index = 1 }));

    // Placed, the mounted model stands at the attachment on the part that carries it.
    built.place(.{ 0, 0, 1000 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 1000 }), built.mounts[0].model.parts[0].object.position);
    // At the steps' places, its root stands where placing puts it; a model it doesn't carry
    // stands nowhere.
    const root: math.Place = .{ .position = .{ 0, 0, 1000 }, .orientation = math.identity };
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 1000 }), built.mountedAt(root, &built.mounts[0].model, .next).?.position);
    try std.testing.expectEqual(root.position, built.mountedAt(root, &built, .now).?.position);
    try std.testing.expectEqual(null, built.mounts[0].model.mountedAt(root, &built, .now));
    // Turned a quarter about Y, the attachment goes with the hull.
    built.place(@splat(0), math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(0, built.mounts[0].model.parts[0].object.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(-50, built.mounts[0].model.parts[0].object.position[2], 1e-3);

    // It is drawn with the hull, and goes dark with the part that carries it.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    built.parts[0].hidden = true;
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    // A model that mounts itself stops rather than running on: the gun answers with the hull.
    const Circle = struct {
        model: *const shp.Model,
        loaded: *const srofiles.Loaded,
        fn load(context: *anyopaque, _: []const u8) ?Mounts.Mounted {
            const circle: *@This() = @ptrCast(@alignCast(context));
            return .{ .model = circle.model, .loaded = circle.loaded };
        }
    };
    var circle: Circle = .{ .model = &model, .loaded = &loaded };
    var deep: Model = try .create(gpa, &model, &loaded, .{
        .mounts = .{ .context = &circle, .load = Circle.load },
    });
    defer deep.deinit(gpa);
    testingLink(&deep);
    var depth: usize = 0;
    var at = &deep;
    while (at.mounts.len > 0) : (depth += 1) at = &at.mounts[0].model;
    try std.testing.expectEqual(shp.max_mount_depth, depth);
}

test "an object too far off to cover a pixel is not drawn" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = @splat(0),
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    model.radius = 100;
    model.place(.{ 0, 0, 50_000 }, math.identity);

    // A thousand pixels to a view unit: a radius of 100 covers a pixel out to 100,000 units.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    scene.clear();
    model.place(.{ 0, 0, 150_000 }, math.identity);
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    // Without a scale nothing is left out, however far off it stands.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    // An object that sees less far than its size says goes first.
    scene.clear();
    model.place(.{ 0, 0, 50_000 }, math.identity);
    model.visibility = 0.25;
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

/// A model of three parts, each hanging from the one before, the second carrying `tracks`, built as
/// `create_object` builds one, for the animation tests.
const Animated = struct {
    data: [3]shp.PartData,
    levels: [1]srapiext.Level,
    loaded_parts: [3]srofiles.LoadedPart,
    loaded: srofiles.Loaded,
    source: shp.Model,

    fn init(animated: *Animated, mesh: *const srapiext.Mesh, tracks: []shp.Track) void {
        animated.levels = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        for (&animated.data, &animated.loaded_parts, 0..) |*data, *loaded, index| {
            data.* = testingPart();
            data.part.parent = @as(i32, @intCast(index)) - 1;
            data.part.position = .{ .x = 0, .y = 0, .z = @floatFromInt(100 * index) };
            loaded.* = .{ .flags = .{}, .levels = &animated.levels, .meshes = &.{} };
        }
        animated.data[1].tracks = tracks;
        animated.loaded = .{ .parts = &animated.loaded_parts };
        animated.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &animated.data, .trailing_bytes = 0 };
    }
};

fn testingKey(time: i32, angles: Vector, offset: Vector) shp.Keyframe {
    return .{ .time = time, .angles = gameobj.vec3(angles), .offset = gameobj.vec3(offset) };
}

fn testingClip(length: i32, mode: Model.Mode, name: []const u8) shp.Clip {
    var made: shp.Clip = .{ .length = length, .mode = @enumFromInt(@intFromEnum(mode)), .name_bytes = @splat(0) };
    @memcpy(made.name_bytes[0..name.len], name);
    return made;
}

test "Model.animate" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var keys = [_]shp.Keyframe{
        testingKey(100, .{ 0, 0, 0 }, .{ 0, 0, 10 }),
        testingKey(200, .{ 0, 0, 0 }, .{ 0, 0, 30 }),
        testingKey(200, .{ 0, 0, 0 }, .{ 0, 0, 99 }),
    };
    var tracks = [_]shp.Track{.{ .clip = testingClip(300, .once, "startup"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    const a = &model.parts[1].animation;
    // Before the first keyframe it moves from no pose at time zero; between two, in a straight
    // line; where two share a time, the first of them; past them all, as the last has it.
    model.animate(1, 50);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 5 }), a.offset);
    model.animate(1, 150);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 20 }), a.offset);
    model.animate(1, 200);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 30 }), a.offset);
    model.animate(1, 1000);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 99 }), a.offset);
    // The pose moves the part's next place by its offset, and marks it pending and posed.
    try std.testing.expect(a.pending and a.posed);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 199 }), a.next.place.position);
    // A track past the part's leaves it no pose.
    a.track = 5;
    model.animate(1, 150);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 0 }), a.offset);
}

test "Model.placeFor" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    // The part's frame is turned a quarter about X from the model's, as an exporter leaves many.
    animated.data[1].part.orientation = math.rotation(.x, std.math.pi / 2.0);
    animated.data[1].part.mount_point = .{ .x = 10, .y = 0, .z = 0 };
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // With no pose it stands at its origin in its parent, unturned.
    const rest = model.placeFor(1, .{});
    try std.testing.expect(math.length(rest.position - @as(Vector, .{ 0, 0, 100 })) < 1e-4);
    for (rest.orientation, math.identity) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    // Turned, it turns in its own frame, about its mount point, which stays where it is.
    const angles: Vector = .{ 0, 0.5, 0 };
    const turned = model.placeFor(1, .{ .angles = angles });
    const o = model.parts[1].animation.orientation;
    const expected = math.product(math.product(math.transpose(o), math.fromAngles(0, 0.5, 0)), o);
    try std.testing.expectEqual(expected, turned.orientation);
    const mount: Vector = .{ 10, 0, 0 };
    const pivot = turned.point(mount);
    try std.testing.expect(math.length(pivot - (mount + @as(Vector, .{ 0, 0, 100 }))) < 1e-3);
}

test "Model.swivel" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    // A turret's base, which turns freely about X, up to 60 degrees down about Y and not at all
    // about Z.
    animated.data[1].part.angles_min = .{ .x = 0, .y = -60, .z = 0 };
    animated.data[1].part.angles_max = .{ .x = 0, .y = 0, .z = 0 };
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    const a = &model.parts[1].animation;

    // Freely about X it comes round within a half turn; about Y it stops at its limit. It is
    // marked animating, up to the root.
    model.swivel(1, .{ 4, -2, 0 });
    try std.testing.expectApproxEqAbs(4 - std.math.tau, a.turret[0], 1e-6);
    try std.testing.expectApproxEqAbs(-60 * std.math.rad_per_deg, a.turret[1], 1e-6);
    try std.testing.expect(a.animating and model.parts[0].animation.animating);
    // Its pose adds the turret's angles to the track's.
    a.angles = .{ 0, 0.25, 0 };
    model.pose(1);
    try std.testing.expectEqual(a.turret + @as(Vector, .{ 0, 0.25, 0 }), a.next.pose.angles);
    try std.testing.expect(a.pending and a.posed);
    // An axis whose limits are equal, but not zero, is free too.
    a.angles_min[2] = 10;
    a.angles_max[2] = 10;
    model.swivel(1, .{ 0, 0, 0.5 });
    try std.testing.expectEqual(0.5, a.turret[2]);
}

test "Model.partPlace" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // Each part stands 100 along Z from the one it hangs from.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 200 }), model.partPlace(2, .now).position);
    // The middle part swivelled a quarter about Y for the next step carries the last with it
    // there, but not yet now.
    model.swivel(1, .{ 0, std.math.pi / 2.0, 0 });
    model.pose(1);
    const next = model.partPlace(2, .next);
    try std.testing.expectApproxEqAbs(100, next.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(100, next.position[2], 1e-3);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 200 }), model.partPlace(2, .now).position);
}

test loseComponents {
    const gpa = std.testing.allocator;
    const guns = @import("guns.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const ctx = mission.orders();
    var fixture: create.testing.Model = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);
    _ = try mission.add(.kamov, @splat(0));
    const index = try create.createObject(mission.objects, &mission.tables, fixture.types(), null, .predator, 0, @splat(0), &mission.random);
    const slot = &mission.objects.slots[index];

    // Its model, three parts hanging from the root: a comms transmitter; its damaged model, hidden;
    // and an engine that is a missile turret's base.
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    const kept = slot.model;
    slot.model = model;
    defer slot.model = kept;
    const live = &slot.model.?;
    for (live.parts) |*part| part.parent = null;
    live.parts[0] = .{ .hidden = false, .parent = null, .origin = @splat(0), .object = live.parts[0].object, .class = .comms_transmitter, .link_id = 1, .armor = 100 };
    live.parts[1].link_id = 1;
    live.parts[1].hidden = true;
    live.parts[2].class = .engine;
    live.parts[2].link_id = 2;
    live.parts[2].armor = 100;
    live.parts[2].turret = true;
    slot.components[0] = &live.parts[0];
    var fitted = [_]guns.Fitted{.{ .turret = .{ .missile = .{ .model = live, .base = 2, .launcher = 2 } } }};
    const kept_guns = slot.guns;
    slot.guns = &fitted;
    defer slot.guns = kept_guns;

    // Nothing happens until a component's armour runs out and its root is flagged.
    loseComponents(ctx, index);
    try std.testing.expect(!live.parts[0].spent);

    // The comms transmitter is taken out and leaves the components; its damaged model shows.
    live.parts[0].armor = -1;
    live.destroyed = true;
    loseComponents(ctx, index);
    try std.testing.expect(live.parts[0].spent and live.parts[0].removed and live.parts[0].hidden);
    try std.testing.expect(!live.parts[1].hidden);
    try std.testing.expect(!live.parts[2].removed);
    try std.testing.expect(!live.destroyed);
    try std.testing.expectEqual(null, slot.components[0]);

    // An engine takes its share of the thrust with it, and the turret on it stops for good.
    slot.object.engines = 2;
    slot.object.engines_intact = 1;
    live.parts[2].armor = -1;
    live.destroyed = true;
    loseComponents(ctx, index);
    try std.testing.expectEqual(0.5, slot.object.engines_intact);
    try std.testing.expect(live.parts[2].removed);
    try std.testing.expect(fitted[0].turret == .gone);

    // A shield generator takes the object's with it.
    live.parts[1] = .{ .hidden = false, .parent = null, .origin = @splat(0), .object = live.parts[1].object, .class = .shield_generator, .link_id = 3, .armor = -1 };
    slot.object.flags.shield_generator = true;
    live.destroyed = true;
    loseComponents(ctx, index);
    try std.testing.expect(!slot.object.flags.shield_generator);
    try std.testing.expect(live.parts[1].removed);
}

test "a ship that lists components ends with its hull" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const ctx = mission.orders();
    var fixture: create.testing.Model = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);
    fixture.data[0].part.class = .hull;
    _ = try mission.add(.kamov, @splat(0));

    // Any ship: the hull is taken out with the rest of its assembly, and the ship ends.
    const ship = try create.createObject(mission.objects, &mission.tables, fixture.types(), null, .predator, 0, @splat(0), &mission.random);
    const hull = &mission.objects.slots[ship].model.?;
    hull.parts[0].armor = -1;
    hull.destroyed = true;
    loseComponents(ctx, ship);
    try std.testing.expect(mission.objects.slots[ship].object.flags.exploding);
    try std.testing.expect(hull.parts[0].removed and !hull.destroyed);

    // A capital ship's routine ends it there instead, leaving the hull and its root's flag, and
    // it drifts on unpowered.
    const capital = try create.createObject(mission.objects, &mission.tables, fixture.types(), null, .badanov, 0, .{ 0, 0, 5000 }, &mission.random);
    const wreck = &mission.objects.slots[capital].model.?;
    wreck.parts[0].armor = -1;
    wreck.destroyed = true;
    loseComponents(ctx, capital);
    const flags = mission.objects.slots[capital].object.flags;
    try std.testing.expect(flags.exploding and flags.unpowered);
    try std.testing.expect(wreck.parts[0].spent and !wreck.parts[0].removed and wreck.destroyed);
    try std.testing.expectEqual(0, mission.objects.slots[capital].object.order_count);
}

test "Model.lineage" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // The last part, the middle one it hangs from, and the first, which hangs from the root.
    var seen: std.ArrayList(usize) = .empty;
    defer seen.deinit(gpa);
    var up = model.lineage(2);
    while (up.next()) |index| try seen.append(gpa, index);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, seen.items);
    try std.testing.expect(model.topOf(&model.parts[2]) == &model.parts[0]);

    // Parents that run in a circle end the walk after as many steps as there are parts, and
    // marking one animating marks them all.
    model.parts[0].parent = 2;
    seen.clearRetainingCapacity();
    up = model.lineage(2);
    while (up.next()) |index| try seen.append(gpa, index);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, seen.items);
    model.markAnimating(1);
    for (model.parts) |part| try std.testing.expect(part.animation.animating);
}

test "a segment strikes a part of a model mounted on another" {
    const gpa = std.testing.allocator;
    // The mounted model: a square facing -Z, with its collision tree.
    var gun: create.testing.Model = undefined;
    try gun.init(gpa);
    defer gun.deinit(gpa);
    gun.withHull();
    // The model carrying it: a part with a gun attachment 1000 along Z.
    var carrier: testing.Carrier = undefined;
    carrier.init(.{ 0, 0, 1000 });
    var built = try carrier.build(gpa, &gun);
    defer built.deinit(gpa);
    gameobj.linkParts(&built, &carrier.source);
    // The carrier's box reaches the mount, as its object's does once its parts are summed.
    built.bounds = .{ .{ -200, -200, -200 }, .{ 200, 200, 1200 } };

    // The segment through the square is struck on the mounted model's part.
    const hit = hitSegment(&built, .{}, .{ 5, 5, 900 }, .{ 5, 5, 1100 }) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(&built.mounts[0].model, hit.part.model);
    try std.testing.expectEqual(0, hit.part.index);
}

test "a part's first track poses it where it is linked" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    // A gun barrel whose firing track starts drawn back.
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, -60 }), testingKey(50, .{ 0, 0, 0 }, .{ 0, 0, 0 }) };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "fire"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    // It stands drawn back from the start, with nothing pending, and plays nothing.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 40 }), model.parts[1].origin);
    try std.testing.expect(!model.parts[1].animation.pending and !model.parts[1].animation.animating);
    try std.testing.expectEqual(@as(?usize, 0), model.parts[1].animation.slots.get(.fire));
    try std.testing.expectEqual(@as(?usize, null), model.parts[1].animation.slots.get(.startup));
}

test "Model.play" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var tracks = [_]shp.Track{
        .{ .clip = testingClip(100, .none, "idle"), .keyframes = &.{}, .events = &.{} },
        .{ .clip = testingClip(100, .loop, "STARTUP"), .keyframes = &.{}, .events = &.{} },
    };
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    const a = &model.parts[1].animation;

    // `create_object` plays the `startup` track, whatever its case, as it says, at 4 a step, and
    // marks the part and all it hangs from as animating.
    create.startUp(&model);
    try std.testing.expectEqual(1, a.track);
    try std.testing.expectEqual(Model.Mode.loop, a.mode);
    try std.testing.expectEqual(4, a.speed);
    try std.testing.expect(a.animating and model.parts[0].animation.animating and !model.parts[2].animation.animating);
    // A time below zero leaves the time as it is; a track by a name it doesn't have plays nothing.
    a.time = 30;
    model.playNamed(1, "idle", -1, null, 2);
    try std.testing.expectEqual(0, a.track);
    try std.testing.expectEqual(Model.Mode.none, a.mode);
    try std.testing.expectEqual(30, a.time);
    model.playNamed(1, "wave", 0, .once, 2);
    try std.testing.expectEqual(0, a.track);
    model.play(1, .deploy, 0, .once, 2);
    try std.testing.expectEqual(Model.Mode.none, a.mode);
}

/// Keeps the events a model's tracks set off.
const Fired = struct {
    kinds: [8]shp.ClipEvent.Kind = undefined,
    count: usize = 0,

    fn events(fired: *Fired) gameobj.Events {
        return .{ .context = fired, .fire = fire };
    }

    fn fire(context: *anyopaque, _: u16, _: *Model, _: usize, kind: shp.ClipEvent.Kind) void {
        const fired: *Fired = @ptrCast(@alignCast(context));
        fired.kinds[fired.count] = kind;
        fired.count += 1;
    }
};

test "a track plays once, round and round, and back and forth" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, 0 }), testingKey(100, .{ 0, 0, 0 }, .{ 0, 0, 100 }) };
    var clip_events = [_]shp.ClipEvent{
        .{ .time = 10, .kind = .muzzles, ._unknown_08 = 0 },
        .{ .time = 90, .kind = .puff, ._unknown_08 = 0 },
        .{ .time = 50, .kind = @enumFromInt(3), ._unknown_08 = 0 },
    };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "fire"), .keyframes = &keys, .events = &clip_events }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    const a = &model.parts[1].animation;
    var root = std.mem.zeroes(Node);
    var fired: Fired = .{};

    // Once: each step moves it on by its speed, setting off the events it passes, a kind the
    // update doesn't know aside; at the end it stops, and the part stops animating.
    model.play(1, .fire, 0, null, 40);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(40, a.time);
    try std.testing.expectEqual(1, fired.count);
    try std.testing.expectEqual(shp.ClipEvent.Kind.muzzles, fired.kinds[0]);
    try std.testing.expect(root.flags.animating);
    gameobj.updateTree(&root, &model, fired.events());
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(100, a.time);
    try std.testing.expectEqual(0, a.speed);
    try std.testing.expectEqual(2, fired.count);
    try std.testing.expectEqual(shp.ClipEvent.Kind.puff, fired.kinds[1]);
    // Each step commits the place the last worked out. The part it is linked to, a child of the
    // root as every part is, plays nothing and cleared its mark on its first visit. Stopped, the
    // part clears its own on its next visit, and the root on the one after.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 80 }), a.now.pose.offset);
    try std.testing.expect(!model.parts[0].animation.animating);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(!a.animating and root.flags.animating);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(!root.flags.animating);

    // Round and round: past the end it starts again, and the events on both sides go off.
    fired.count = 0;
    model.play(1, .fire, 80, .loop, 40);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(20, a.time);
    try std.testing.expectEqual(2, fired.count);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 20 }), a.offset);

    // Back and forth: out over the length and back over the next, with no events.
    fired.count = 0;
    model.play(1, .fire, 60, .swing, 70);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(130, a.time);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 70 }), a.offset);
    gameobj.updateTree(&root, &model, fired.events());
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(70, a.time);
    try std.testing.expectEqual(0, fired.count);

    // A part linked to a hidden one is still visited, as a child of the root; a hidden one isn't.
    model.parts[0].hidden = true;
    var was = a.time;
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(a.time != was);
    model.parts[1].hidden = true;
    was = a.time;
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(was, a.time);
}

test "Model.frame" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    // A dish that turns a little past half a turn about Y each step.
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, 0 }), testingKey(100, .{ 0, 3, 0 }, .{ 0, 0, 40 }) };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "startup"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    var root = std.mem.zeroes(Node);
    const part = &model.parts[1];
    const linked = part.origin;

    create.startUp(&model);
    // The first step works out the next pose but commits nothing yet: the frame stays.
    gameobj.updateTree(&root, &model, null);
    model.frame(0.5);
    try std.testing.expectEqual(linked, part.origin);
    // After the next it is drawn between the two, at the step at the committed place.
    gameobj.updateTree(&root, &model, null);
    model.frame(0);
    try std.testing.expectEqual(part.animation.now.place.position, part.origin);
    model.frame(0.5);
    const halfway = model.placeFor(1, .{ .angles = .{ 0, 0.18, 0 }, .offset = .{ 0, 0, 2.4 } });
    try std.testing.expect(math.length(halfway.position - part.origin) < 1e-4);
    // Poses more than half a turn apart are drawn turning the short way round: from -3 to 3 by
    // way of -pi rather than zero.
    const a = &part.animation;
    a.now.pose.angles = .{ 0, -3, 0 };
    a.next.pose.angles = .{ 0, 3, 0 };
    a.unframed = true;
    model.frame(0.5);
    const offset = (a.next.pose.offset - a.now.pose.offset) * @as(Vector, @splat(0.5)) + a.now.pose.offset;
    const short = model.placeFor(1, .{ .angles = .{ 0, -std.math.pi, 0 }, .offset = offset });
    for (short.orientation, part.turn) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);

    // The part it is linked to hidden, it is framed still, a child of the root as every part is;
    // hidden itself, it keeps its frame.
    model.parts[0].hidden = true;
    a.unframed = true;
    model.frame(0);
    try std.testing.expectEqual(a.now.place.position, part.origin);
    part.hidden = true;
    part.origin = @splat(0);
    a.unframed = true;
    model.frame(0);
    try std.testing.expectEqual(@as(Vector, @splat(0)), part.origin);
}

test "Model.assembly" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);

    // The parts sharing a link id, in part order, but for one taken out.
    for (model.parts, [_]u32{ 4, 7, 4 }) |*part, link| part.link_id = link;
    var each = model.assembly(4);
    try std.testing.expectEqual(0, each.next());
    try std.testing.expectEqual(2, each.next());
    try std.testing.expectEqual(null, each.next());
    model.parts[0].removed = true;
    each = model.assembly(4);
    try std.testing.expectEqual(2, each.next());
    try std.testing.expectEqual(null, each.next());
}

test "Model.rootChild" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // The root's child list holds each part at its number, linked to another or not.
    try std.testing.expect(model.rootChild(2) == &model.parts[2]);
    try std.testing.expectEqual(null, model.rootChild(3));
    model.parts[2].removed = true;
    try std.testing.expectEqual(null, model.rootChild(2));
}

test partEntry {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    model.place(@splat(0), math.identity);

    // Three squares in a row along Z, each linked to the one before; a segment along Z through
    // them all meets the first first and the last last.
    const from: Vector = .{ 0, 0, -50 };
    const to: Vector = .{ 0, 0, 250 };
    try std.testing.expectApproxEqAbs(50.0 / 300.0, partEntry(&model, from, to, .first).?, 1e-4);
    try std.testing.expectApproxEqAbs(250.0 / 300.0, partEntry(&model, from, to, .last_shown).?, 1e-4);
    // A hidden part counts for a missile, not for a shot; one taken out, for neither.
    model.parts[0].hidden = true;
    try std.testing.expectApproxEqAbs(50.0 / 300.0, partEntry(&model, from, to, .first).?, 1e-4);
    model.parts[0].removed = true;
    try std.testing.expectApproxEqAbs(150.0 / 300.0, partEntry(&model, from, to, .first).?, 1e-4);
    model.parts[2].hidden = true;
    try std.testing.expectApproxEqAbs(150.0 / 300.0, partEntry(&model, from, to, .last_shown).?, 1e-4);
}

test "Node.framePlace" {
    var root = std.mem.zeroes(Node);
    root.orientation = math.identity;
    root.next_orientation = math.rotation(.y, 0.4);
    root.next_position = .{ .x = 40, .y = 0, .z = 0 };
    // Until a step commits a place, the frame stays where it was.
    try std.testing.expectEqual(null, root.framePlace(0.5));
    root.flags.next_pending = true;
    root.commitNext();
    root.next_position = .{ .x = 80, .y = 0, .z = 0 };
    root.next_orientation = math.rotation(.y, 0.8);
    // At the step, the committed place; a quarter of the way on, a quarter of the move and turn.
    const at = root.framePlace(0).?;
    try std.testing.expectEqual(@as(Vector, .{ 40, 0, 0 }), at.position);
    const quarter = root.framePlace(0.25).?;
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 0 }), quarter.position);
    const turned = math.rotation(.y, 0.5);
    for (turned, quarter.orientation) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);
}

test stepFraction {
    var clock: Clock = .{};
    clock.start(0);
    // A frame two ticks into a step, and three quarters of the way through the next tick.
    clock.advanceToFine(275, 100);
    clock.simulation_counter = 2;
    try std.testing.expectEqual(0.5, stepFraction(&clock, false));
    try std.testing.expectEqual(0.6875, stepFraction(&clock, true));
    // Paused, nothing moves, so the time past the tick doesn't count.
    clock.paused = true;
    try std.testing.expectEqual(0.5, stepFraction(&clock, true));
}
