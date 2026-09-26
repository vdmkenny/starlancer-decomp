//! `sltool shp ...`: read `.SHP` models and export their geometry.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const shp = openreliant.shp;

const sltool = @import("main.zig");
const Context = sltool.Context;
const Library = @import("library.zig").Library;

pub const Command = union(enum) {
    info: struct { model: []const u8 },
    /// Cross-checks the parsed model against itself.
    check: struct { model: []const u8 },
    /// Lists the chunk stream as it appears in the file.
    chunks: struct { model: []const u8 },
    /// Lists the parts objects of the model name as components, by index.
    components: struct { model: []const u8 },
    /// Writes Wavefront OBJ, one object per part.
    obj: struct { model: []const u8, out: []const u8, lod: u32 = 0, model_space: bool = false },

    pub const usage =
        \\  shp info <model>                parts, meshes, materials and bounds
        \\  shp check <model>               validate indices, bounds and normals
        \\  shp chunks <model>              list the raw chunk stream
        \\  shp components <model>          list the components objects of the model name by index,
        \\                                  finding mounted models beside it
        \\  shp obj <model> <out.obj> [--lod <n>] [--model-space]
        \\                                  export geometry as Wavefront OBJ, righted to Y-up
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        switch (verb) {
            inline .info, .check, .chunks, .components => |tag| return sltool.positional(Command, tag, operands),
            .obj => {
                if (operands.len < 2) return error.Usage;
                var command: Command = .{ .obj = .{ .model = operands[0], .out = operands[1] } };
                var i: usize = 2;
                while (i < operands.len) {
                    if (std.mem.eql(u8, operands[i], "--model-space")) {
                        command.obj.model_space = true;
                        i += 1;
                    } else if (std.mem.eql(u8, operands[i], "--lod") and i + 1 < operands.len) {
                        command.obj.lod = std.fmt.parseInt(u32, operands[i + 1], 10) catch return error.Usage;
                        i += 2;
                    } else return error.Usage;
                }
                return command;
            },
        }
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.model,
        };
        const data = try ctx.readInput(path);

        switch (command) {
            .chunks => try chunks(ctx, data),
            .components => try listComponents(ctx, path),
            .info => try info(ctx, try shp.Model.parse(ctx.arena, data)),
            .check => try check(ctx, try shp.Model.parse(ctx.arena, data)),
            .obj => |operands| try writeObj(
                ctx,
                try shp.Model.parse(ctx.arena, data),
                operands.out,
                operands.lod,
                operands.model_space,
            ),
        }
    }
};

fn listComponents(ctx: Context, path: []const u8) !void {
    var library: Library = try .beside(ctx, path);
    defer library.deinit();
    const name = std.fs.path.basename(path);
    const model = try library.load(name) orelse return error.FileNotFound;
    if (!model.header.flags.components) {
        try ctx.stdout.writeAll("the model's header does not ask for components, so its objects list none\n");
        return;
    }
    const list = try shp.components(ctx.arena, model, name, &library);
    try ctx.stdout.writeAll("index  part  class  link  armor  model                 name\n");
    for (list, 0..) |component, index| {
        // A signed number given a width takes a plus sign, so the armour is padded as text, in a
        // buffer that holds any i32.
        var armor: [std.fmt.count("{d}", .{std.math.minInt(i32)})]u8 = undefined;
        try ctx.stdout.print("{d:>5}  {d:>4}  {d:>5}  {d:>4}  {s:>5}  {s:<20}  {s}\n", .{
            index,
            component.part_index,
            @intFromEnum(component.part.class),
            component.part.link_id,
            std.fmt.bufPrint(&armor, "{d}", .{component.part.component_armor}) catch unreachable,
            component.model,
            component.part.name(),
        });
    }
    if (list.len > shp.max_components) {
        try ctx.stdout.print("more than the {d} an object can list: the engine stops with a fatal error\n", .{shp.max_components});
    }
}

fn chunks(ctx: Context, data: []const u8) !void {
    var reader: shp.Reader = .init(data);
    try ctx.stdout.writeAll("  offset   tag  record  count  name\n");
    while (try reader.next()) |chunk| {
        const offset = reader.pos - chunk.data.len - @sizeOf(shp.ChunkHeader);
        try ctx.stdout.print("{x:0>8}  {x:0>4} {d:>7} {d:>6}  {f}\n", .{
            offset, @intFromEnum(chunk.tag), chunk.record_size, chunk.count, chunk.tag,
        });
    }
    try ctx.stdout.print("{x:0>8}  ffff                 end\n", .{reader.pos});
}

fn info(ctx: Context, model: shp.Model) !void {
    try ctx.stdout.print(
        \\version:  {d}
        \\flags:    components={} cloak={}
        \\parts:    {d}
        \\vertices: {d}
        \\faces:    {d}
        \\arcs:     {d}
        \\
    , .{
        model.header.version,
        model.header.flags.components,
        model.header.flags.cloak,
        model.parts.len,
        model.vertexCount(),
        model.faceCount(),
        model.firing_arcs.len,
    });
    if (model.bounds()) |box| {
        const lo, const hi = box;
        try ctx.stdout.print("bounds:   ({d:.0},{d:.0},{d:.0}) to ({d:.0},{d:.0},{d:.0}), {d:.0} x {d:.0} x {d:.0}\n", .{
            lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z,
        });
    }
    try ctx.stdout.writeByte('\n');

    for (model.parts, 0..) |entry, index| {
        const part = entry.part;
        try ctx.stdout.print("[{d:>3}] {s:<34} type {d:>2}  parent {d:>3}  link {d}", .{
            index, part.name(), @intFromEnum(part.class), part.parent, part.link_id,
        });
        if (part.turret_kind != .fixed) {
            try ctx.stdout.print("  turret kind {d} slot {d} yaw [{d:.0},{d:.0}] pitch [{d:.0},{d:.0}]", .{
                @intFromEnum(part.turret_kind), part.turret_slot,
                part.angles_min.x,              part.angles_max.x,
                part.angles_min.y,              part.angles_max.y,
            });
        }
        try ctx.stdout.writeByte('\n');

        for (entry.meshes, 0..) |mesh, level| {
            try ctx.stdout.print("        lod {d}: {d:>5} vertices {d:>5} faces {d:>3} materials", .{
                level, mesh.vertices.len, mesh.faces.len, mesh.materials.len,
            });
            if (mesh.lod.switch_distance != 0) {
                try ctx.stdout.print("  beyond {d:.0}", .{mesh.lod.switch_distance});
            }
            try ctx.stdout.writeByte('\n');
        }

        if (entry.attachments.len + entry.nodes.len + entry.tracks.len + entry.point_lists.len + entry.trigger_count > 0) {
            try ctx.stdout.print("        {d} nodes, {d} attachments, {d} clips, {d} point lists, {d} triggers\n", .{
                entry.nodes.len,       entry.attachments.len, entry.tracks.len,
                entry.point_lists.len, entry.trigger_count,
            });
        }
        for (entry.point_lists) |list| {
            try ctx.stdout.print("          points kind {d}: {d}\n", .{ @intFromEnum(list.kind), list.points.len });
        }
        for (entry.tracks) |track| {
            try ctx.stdout.print("          clip '{s}' length {d} mode {d}, {d} keyframes, {d} events\n", .{
                track.clip.name(), track.clip.length, track.clip.mode, track.keyframes.len, track.events.len,
            });
        }
        for (entry.attachments) |attachment| {
            try ctx.stdout.print("          {s} {d} at ({d:.0},{d:.0},{d:.0})", .{
                switch (attachment.kind) {
                    .missile => "missile",
                    .gun => "gun",
                    .engine_glow => "engine glow",
                    .gun_muzzle => "gun muzzle",
                    .light => "light",
                    .pod => "pod",
                    .eject_point => "eject point",
                    .case_ejector => "case ejector",
                    .launch_point => "launch point",
                    _ => "kind",
                },
                @intFromEnum(attachment.kind),
                attachment.position.x,
                attachment.position.y,
                attachment.position.z,
            });
            if (attachment.kind == .engine_glow) {
                try ctx.stdout.print("  size ({d:.0},{d:.0},{d:.0})", .{
                    attachment.size[0], attachment.size[1], attachment.size[2],
                });
            }
            if (attachment.kind == .light) {
                try ctx.stdout.print("  id {d} brightness {d:.2} range {d:.0} size ({d:.1},{d:.1})", .{
                    attachment.id,
                    attachment.light_brightness,
                    attachment.light_range,
                    attachment.size[0],
                    attachment.size[1],
                });
                if (attachment.blink[0] != 0 or attachment.blink[1] != 0) {
                    try ctx.stdout.print("  blinks {d} on, {d} off, from {d}", .{
                        attachment.blink[0], attachment.blink[1], attachment.blink_phase,
                    });
                }
            }
            try ctx.stdout.writeByte('\n');
        }
    }

    // Materials are per mesh, but the set across the model is what matters for texturing.
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (model.parts) |entry| {
        for (entry.meshes) |mesh| {
            for (mesh.materials) |*material| {
                if (material.name().len > 0) try seen.put(ctx.arena, material.name(), {});
            }
        }
    }
    if (seen.count() > 0) {
        try ctx.stdout.print("\ntextures ({d}):", .{seen.count()});
        for (seen.keys()) |name| try ctx.stdout.print(" {s}", .{name});
        try ctx.stdout.writeByte('\n');
    }
}

/// Cross-checks a parsed model for internal consistency. Every one of these holds for all 440
/// shipped models, so a failure means either a damaged file or a misread structure.
/// How a part's stored bounding box relates to the extent of its finest mesh.
const BoundsFrame = enum {
    /// Zero-sized: the exporter left it unfilled.
    empty,
    /// The vertex extent as stored.
    model_space,
    /// The vertex extent after applying the part's orientation.
    oriented,
    /// Same box up to an axis swap or reflection, in a frame the record does not describe.
    permuted,
    /// A different box entirely.
    other,
};

fn classifyBounds(entry: shp.PartData) BoundsFrame {
    const part = &entry.part;
    const tolerance = 0.5;
    const side = struct {
        fn eql(a: shp.Vec3, b: shp.Vec3, c: shp.Vec3, d: shp.Vec3, t: f32) bool {
            return @abs(a.x - c.x) <= t and @abs(a.y - c.y) <= t and @abs(a.z - c.z) <= t and
                @abs(b.x - d.x) <= t and @abs(b.y - d.y) <= t and @abs(b.z - d.z) <= t;
        }
        fn lengths(lo: shp.Vec3, hi: shp.Vec3) [3]f32 {
            var out = [3]f32{ hi.x - lo.x, hi.y - lo.y, hi.z - lo.z };
            std.mem.sort(f32, &out, {}, std.sort.asc(f32));
            return out;
        }
    };

    const stored_sides = side.lengths(part.bounds_min, part.bounds_max);
    if (stored_sides[2] == 0) return .empty;

    const mesh = entry.meshes[0];
    const lo, const hi = mesh.bounds();
    if (side.eql(lo, hi, part.bounds_min, part.bounds_max, tolerance)) return .model_space;

    const olo, const ohi = mesh.boundsIn(part);
    if (side.eql(olo, ohi, part.bounds_min, part.bounds_max, tolerance)) return .oriented;

    const vertex_sides = side.lengths(lo, hi);
    for (stored_sides, vertex_sides) |a, b| {
        if (@abs(a - b) > 1.0) return .other;
    }
    return .permuted;
}

fn check(ctx: Context, model: shp.Model) !void {
    var problems: usize = 0;
    var bounds_frames: [std.meta.fields(BoundsFrame).len]usize = @splat(0);
    const report = struct {
        fn fail(c: Context, count: *usize, comptime fmt: []const u8, args: anytype) !void {
            count.* += 1;
            if (count.* <= 10) try c.stdout.print("  " ++ fmt ++ "\n", args);
        }
    };

    for (model.parts, 0..) |entry, index| {
        const part = entry.part;
        if (part.parentIndex()) |parent| {
            if (parent >= model.parts.len) {
                try report.fail(ctx, &problems, "part {d}: parent {d} out of range", .{ index, part.parent });
            }
            if (parent == index) {
                try report.fail(ctx, &problems, "part {d}: is its own parent", .{index});
            }
        } else if (part.parent != shp.no_index) {
            try report.fail(ctx, &problems, "part {d}: parent {d} out of range", .{ index, part.parent });
        }

        for (entry.meshes, 0..) |mesh, level| {
            for (mesh.faces, 0..) |face, face_index| {
                for (face.vertices) |vertex| {
                    if (vertex >= mesh.vertices.len) {
                        try report.fail(ctx, &problems, "part {d} lod {d} face {d}: vertex {d} of {d}", .{
                            index, level, face_index, vertex, mesh.vertices.len,
                        });
                    }
                }
                if (face.material >= mesh.materials.len) {
                    try report.fail(ctx, &problems, "part {d} lod {d} face {d}: material {d} of {d}", .{
                        index, level, face_index, face.material, mesh.materials.len,
                    });
                }
            }

            // The next-level counterpart index must point into the following level.
            if (level + 1 < entry.meshes.len) {
                const next = entry.meshes[level + 1];
                for (mesh.vertices, 0..) |*vertex, vertex_index| {
                    const in_range = if (vertex.nextLod()) |target| target < next.vertices.len else vertex.next_lod_vertex == shp.no_index;
                    if (!in_range) {
                        try report.fail(ctx, &problems, "part {d} lod {d} vertex {d}: geomorph target {d} of {d}", .{
                            index, level, vertex_index, vertex.next_lod_vertex, next.vertices.len,
                        });
                    }
                }
            }
        }

        // The collision tree: every box turned by a rotation, every child a node of this part, and
        // every face one of the first level's.
        for (entry.nodes, entry.node_faces, 0..) |node, faces, node_index| {
            for (0..3) |row| {
                const axis: [3]f32 = node.orientation[row * 3 ..][0..3].*;
                const length = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
                if (@abs(length - 1) > 1e-3) {
                    try report.fail(ctx, &problems, "part {d} node {d}: axis {d} is {d:.4} long", .{ index, node_index, row, length });
                }
            }
            if (faces.len == 0) {
                for (node.children, 0..) |child, which| {
                    const in_range = if (node.child(@intCast(which))) |target| target < entry.nodes.len else false;
                    if (!in_range) {
                        try report.fail(ctx, &problems, "part {d} node {d}: child {d} of {d}", .{ index, node_index, child, entry.nodes.len });
                    }
                }
            }
            const in_level = if (entry.meshes.len > 0) entry.meshes[0].faces.len else 0;
            for (faces) |face| {
                if (face >= in_level) {
                    try report.fail(ctx, &problems, "part {d} node {d}: face {d} of {d}", .{ index, node_index, face, in_level });
                }
            }
        }

        // The part record carries a bounding box derived from its vertices, but not always in
        // the part's own frame, so it is classified rather than required to match.
        if (entry.meshes.len > 0 and entry.meshes[0].vertices.len > 0) {
            bounds_frames[@intFromEnum(classifyBounds(entry))] += 1;
        }
    }

    if (problems == 0) {
        try ctx.stdout.print("ok: {d} parts, {d} vertices, {d} faces\n", .{
            model.parts.len, model.vertexCount(), model.faceCount(),
        });
        try ctx.stdout.writeAll("bounds:");
        inline for (std.meta.fields(BoundsFrame)) |field| {
            const count = bounds_frames[field.value];
            if (count > 0) try ctx.stdout.print(" {d} {s}", .{ count, field.name });
        }
        try ctx.stdout.writeByte('\n');
    } else {
        try ctx.stdout.print("{d} problems\n", .{problems});
        try ctx.stdout.flush(); // the error path skips the flush in main
        return error.ModelInconsistent;
    }
}

/// Writes a level's faces as OBJ faces, all wound alike, and returns how many. Odd strip members
/// list their last two corners the other way round, so those are swapped back. Wire faces are lines
/// rather than a surface, and caps are hidden on an intact object, so both are left out.
fn writeFaces(out: *Io.Writer, mesh: shp.Mesh, vertex_base: usize, uv_base: usize) Io.Writer.Error!usize {
    var triangles: usize = 0;
    var current_material: ?u32 = null;
    for (mesh.faces, 0..) |face, face_index| {
        if (face.shading.mode == .wire or face.flags.cap) continue;
        if (current_material == null or current_material.? != face.material) {
            current_material = face.material;
            const name = if (face.material < mesh.materials.len)
                mesh.materials[face.material].name()
            else
                "";
            try out.print("usemtl {s}\n", .{if (name.len > 0) name else "none"});
        }
        const corners: [3]usize = if (face.polygon == .strip_odd) .{ 0, 2, 1 } else .{ 0, 1, 2 };
        try out.writeAll("f");
        for (corners) |corner| {
            const vertex = vertex_base + face.vertices[corner];
            try out.print(" {d}/{d}/{d}", .{ vertex, uv_base + face_index * 3 + corner, vertex });
        }
        try out.writeAll("\n");
        triangles += 1;
    }
    return triangles;
}

/// Writes the requested level of every part as one OBJ object each.
///
/// Every face record is emitted as its own triangle. Records carrying fan or strip grouping would
/// merge into larger polygons in the engine, but each record is already a complete triangle of
/// that polygon, so triangulating them is equivalent and avoids relying on the coplanarity test
/// the loader applies.
fn writeObj(ctx: Context, model: shp.Model, out_path: []const u8, lod: u32, model_space: bool) !void {
    // The model frame is Y-down, Z-forward; OBJ readers assume Y-up. `--model-space` keeps the
    // coordinates exactly as the file stores them.
    const place = struct {
        fn at(v: shp.Vec3, raw: bool) shp.Vec3 {
            return if (raw) v else v.toYUp();
        }
    };
    const file = try Io.Dir.cwd().createFile(ctx.io, out_path, .{});
    defer file.close(ctx.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    const out = &writer.interface;

    try out.print("# Starlancer model, lod {d}, {d} parts, {s}\n", .{
        lod,                                                                       model.parts.len,
        if (model_space) "model space (Y down, Z forward)" else "righted to Y up",
    });

    // OBJ numbers positions, texture coordinates and normals in three independent spaces, each
    // 1-based and running across the whole file.
    var vertex_base: usize = 1;
    var uv_base: usize = 1;
    var exported: usize = 0;
    var triangles: usize = 0;

    for (model.parts) |entry| {
        if (lod >= entry.meshes.len) continue;
        const mesh = entry.meshes[lod];
        if (mesh.vertices.len == 0) continue;

        // A part's origin is in the model's frame, whatever its parent.
        const offset = entry.part.position;

        try out.print("\no {s}\n", .{if (entry.part.name().len > 0) entry.part.name() else "part"});
        for (mesh.vertices) |vertex| {
            const p = place.at(vertex.position.add(offset), model_space);
            try out.print("v {d} {d} {d}\n", .{ p.x, p.y, p.z });
        }
        for (mesh.vertices) |vertex| {
            const n = place.at(vertex.normal, model_space);
            try out.print("vn {d} {d} {d}\n", .{ n.x, n.y, n.z });
        }
        // OBJ texture coordinates run bottom-up, the opposite of the game's.
        for (mesh.faces) |face| {
            for (0..3) |corner| {
                try out.print("vt {d} {d}\n", .{ face.u[corner], 1.0 - face.v[corner] });
            }
        }

        triangles += try writeFaces(out, mesh, vertex_base, uv_base);

        vertex_base += mesh.vertices.len;
        uv_base += mesh.faces.len * 3;
        exported += 1;
    }

    try out.flush();
    try ctx.stdout.print("wrote {s}: {d} parts, {d} triangles\n", .{ out_path, exported, triangles });
}

test Command {
    const obj = try Command.parse(&.{ "obj", "SHIP.SHP", "ship.obj", "--lod", "2", "--model-space" });
    try std.testing.expectEqualStrings("ship.obj", obj.obj.out);
    try std.testing.expectEqual(2, obj.obj.lod);
    try std.testing.expect(obj.obj.model_space);

    const plain = try Command.parse(&.{ "obj", "SHIP.SHP", "ship.obj" });
    try std.testing.expectEqual(0, plain.obj.lod);
    try std.testing.expect(!plain.obj.model_space);
    try std.testing.expectEqualStrings("SHIP.SHP", (try Command.parse(&.{ "components", "SHIP.SHP" })).components.model);

    try std.testing.expectError(error.Usage, Command.parse(&.{ "obj", "SHIP.SHP", "ship.obj", "--lod" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "obj", "SHIP.SHP", "ship.obj", "--lod", "two" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "obj", "SHIP.SHP", "ship.obj", "--flat" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "obj", "SHIP.SHP" }));
}

test writeFaces {
    var faces: [4]shp.Face = @splat(std.mem.zeroes(shp.Face));
    for (&faces) |*face| {
        face.vertices = .{ 0, 1, 2 };
        face.shading.mode = .lit;
    }
    faces[1].polygon = .strip_odd;
    faces[2].flags.cap = true;
    faces[3].shading.mode = .wire;
    const mesh: shp.Mesh = .{ .lod = .{ .switch_distance = 0 }, .vertices = &.{}, .faces = &faces, .materials = &.{} };

    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(2, try writeFaces(&out, mesh, 1, 1));
    try std.testing.expectEqualStrings(
        \\usemtl none
        \\f 1/1/1 2/2/2 3/3/3
        \\f 1/4/1 3/6/3 2/5/2
        \\
    , out.buffered());
}
