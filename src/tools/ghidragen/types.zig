//! The type schema: every exported Zig type as rows that `ghidra/scripts/ApplyTypes.java` turns
//! into Ghidra data types.
//!
//! Rows are tab-separated. The first column says what a row is:
//!
//!     struct    <name> <size>
//!     field     <struct> <offset> <field> <type>
//!     bits      <struct> <offset> <bytes> <bit offset> <bits> <field> <base type>
//!     union     <name> <size>
//!     member    <union> <field> <type>
//!     enum      <name> <size>
//!     value     <enum> <label> <value>
//!     function  <name> <signature>
//!
//! A type is a Ghidra type string: a name, then `*` and `[n]` decorations, as Ghidra's
//! `DataTypeParser` reads them. A signature is C with no function name, which the script inserts.
//! A packed struct becomes a structure of bitfields over its backing integer. A run of unknown
//! bytes, a `_unknown` field of `u8` array type, gets no row: Ghidra leaves it undefined and names
//! what reads it by offset. A `u8` array whose field name says it is a name becomes `char`.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const dte = openreliant.dte;
const engine = openreliant.engine;
const shp = openreliant.shp;
const tcache = openreliant.tcache;

const Export = struct { []const u8, type };

/// Every type the schema defines, under its Ghidra name. A struct, union, enum or code type that
/// one of these refers to must be listed as well, or the tool does not compile.
pub const exported = [_]Export{
    // Mission records, which the engine uses in place.
    .{ "SectionEntry", dte.DirectoryEntry },
    .{ "SectionFormats", dte.DirectoryEntry.Formats },
    .{ "MissionGlobal", dte.Global },
    .{ "MissionShip", dte.Ship },
    .{ "MissionShipFlags", dte.Ship.Flags },
    .{ "FlightGroup", dte.FlightGroup },
    .{ "Trigger", dte.Trigger },
    .{ "TriggerRepeat", dte.Trigger.Repeat },
    .{ "TriggerReference", dte.Reference },
    .{ "ReferenceTag", dte.Reference.Tag },
    .{ "Condition", dte.Condition },
    .{ "MissionObject", dte.Object },
    .{ "ObjectKind", dte.Object.Kind },
    .{ "ObjectKindSet", dte.Object.KindSet },
    .{ "MissionPart", dte.Part },
    .{ "MissionPartFlags", dte.Part.Flags },
    .{ "Squad", dte.Squad },
    .{ "SquadMember", dte.SquadMember },
    .{ "Curve", dte.Curve },

    // The script VM.
    .{ "VmHandler", engine.vm.Handler },
    .{ "VmCommand", engine.game.executor.Command },
    .{ "VmShipCommand", engine.game.executor.ShipCommand },
    .{ "VmThread", engine.vm.Thread },
    .{ "VmCallRecord", engine.vm.CallRecord },
    .{ "VmFunction", engine.vm.Function },
    .{ "VmFunctionEntry", engine.vm.Function.Entry },
    .{ "VmParam", engine.vm.Function.Param },
    .{ "ParamKinds", engine.game.executor.commands.Kinds },
    .{ "VmTimer", engine.vm.Timer },
    .{ "ConditionDescriptor", engine.vm.ConditionDescriptor },
    .{ "EventValue", engine.vm.EventValue },
    .{ "ObjectEvents", engine.vm.ObjectEvents },
    .{ "QueuedEvent", engine.vm.QueuedEvent },
    .{ "ComponentTag", engine.vm.ComponentTag },

    // Stat tables.
    .{ "FlightModel", engine.game.create.FlightModel },
    .{ "FlightTurns", engine.game.create.FlightModel.Turns },
    .{ "ShipCombat", engine.game.create.ShipCombat },
    .{ "ShipTargeting", engine.game.create.ShipCombat.Targeting },
    .{ "ShipClass", engine.game.create.ShipCombat.Class },
    .{ "TargetDisplay", engine.game.create.ShipCombat.TargetDisplay },
    .{ "ShipSide", engine.game.gameobj.Side(i16) },
    .{ "Damage", openreliant.stats.Damage },
    .{ "GunStats", engine.game.guns.Gun },
    .{ "GunKind", engine.game.guns.Kind },
    .{ "MissileStats", engine.game.missiles.Stats },
    .{ "MissileOrder", engine.game.missiles.Order },
    .{ "PilotStats", engine.game.pilots.Pilot },
    .{ "PilotTimings", engine.game.pilots.Pilot.Timings },
    .{ "PilotRange", engine.game.pilots.Pilot.Range },

    // Sound.
    .{ "SoundVoice", engine.game.hog_snd.Voice },
    .{ "SoundVoice3D", engine.game.hog_snd.Voice3D },
    .{ "Sound3DDefinition", engine.game.sound3d.Definition },
    .{ "Sound3DFollows", engine.game.sound3d.Follows },
    .{ "Sound3DClass", engine.game.sound3d.Class },
    .{ "Sound3DEngineState", engine.game.sound3d.EngineState },
    .{ "HSAMPLE", engine.mss.Sample },
    .{ "H3DSAMPLE", engine.mss.Sample3D },
    .{ "HSTREAM", engine.mss.Stream },

    // Player input.
    .{ "JoystickState", engine.input.JoystickState },
    .{ "JoystickAxes", engine.input.JoystickAxes },
    .{ "MouseState", engine.input.MouseState },
    .{ "ControlBinding", engine.input.ControlBinding },
    .{ "ControlModifier", engine.input.ControlBinding.Modifier },
    .{ "ControlAction", engine.input.controls.Action },
    .{ "ControlMode", engine.input.ControlMode },
    .{ "MissileRack", engine.game.gameobj.Rack },
    .{ "Avoided", engine.game.gameobj.Avoided },
    .{ "MissileType", engine.game.missiles.Type },
    .{ "MissileLook", engine.game.missiles.trail.Look },
    .{ "MissileLookPieces", engine.game.missiles.trail.Look.Pieces },
    .{ "MissileRingEntry", engine.game.hud.missile_display.Entry },
    .{ "MissileLockState", engine.game.main.lock.Phase },

    // The pause menu.
    .{ "MenuItem", engine.game.hudoptions.menu.Item },
    .{ "MenuPlace", engine.game.hudoptions.menu.Place },
    .{ "MenuEdge", engine.game.hudoptions.menu.Place.Edge },
    .{ "MenuShape", engine.game.hudoptions.menu.Shape },
    .{ "MenuFont", engine.game.hudoptions.menu.Font },
    .{ "MenuString", engine.game.hudoptions.menu.String },
    .{ "MenuItemStyle", engine.game.hudoptions.menu.Item.Style },
    .{ "MenuAlignment", engine.game.hudoptions.menu.Alignment },

    // Orders.
    .{ "Order", engine.game.ai.orders.Order },
    .{ "OrderRecord", engine.game.ai.Record },
    .{ "OrderFlags", engine.game.ai.Record.Flags },
    .{ "OrderTarget", engine.game.aigeneric.Target },
    .{ "OrderTargetKind", engine.game.aigeneric.Target.Kind },
    .{ "OrderEntry", engine.game.aigeneric.Entry },
    .{ "OrderData", engine.game.aigeneric.Entry.Data },
    .{ "QueuedOrder", engine.game.aigeneric.Queued },
    .{ "OrderState", engine.game.aigeneric.State },
    .{ "FlyState", engine.game.aiorders.FlyState },
    .{ "MillState", engine.game.aiorders.MillState },
    .{ "EscortState", engine.game.aiorders.EscortState },
    .{ "FindTargetState", engine.game.aiorders.FindTargetState },
    .{ "AttachState", engine.game.aiorders.AttachState },
    .{ "DisruptedState", engine.game.aiorders.DisruptedState },
    .{ "DisruptedData", engine.game.aiorders.DisruptedData },
    .{ "ExplodeState", engine.game.aiexplode.State },
    .{ "ExplodeMode", engine.game.aiexplode.Mode },
    .{ "ExplodeStyle", engine.game.aiexplode.Style },
    .{ "ExplodeData", engine.game.aiexplode.Data },
    .{ "EjectPlayerState", engine.game.aieject.PlayerState },
    .{ "EjectState", engine.game.aieject.State },
    .{ "EjectStage", engine.game.aieject.Stage },
    .{ "ScoopUpState", engine.game.tractor.State },
    .{ "ScoopUpStage", engine.game.tractor.Stage },
    .{ "LaunchState", engine.game.launch.State },
    .{ "LaunchStyle", engine.game.launch.Style },
    .{ "LaunchStep", engine.game.launch.Step },
    .{ "LaunchData", engine.game.launch.Data },
    .{ "JumpState", engine.game.jump.State },
    .{ "JumpOutStep", engine.game.jump.OutStep },
    .{ "JumpInStep", engine.game.jump.InStep },
    .{ "FollowData", engine.game.ai.follow.Data },
    .{ "FollowState", engine.game.ai.follow.State },
    .{ "FollowStep", engine.game.ai.follow.Step },
    .{ "Follower", engine.game.motion.Follower },
    .{ "FollowPath", engine.game.motion.Follower.Path },
    .{ "DockData", engine.game.aidock.Data },
    .{ "DockStyle", engine.game.aidock.Style },
    .{ "DockState", engine.game.aidock.State },
    .{ "DockStep", engine.game.aidock.Step },
    .{ "RipperGrabState", engine.game.airipper.GrabState },
    .{ "RipperGrabStep", engine.game.airipper.GrabStep },
    .{ "RipperDropState", engine.game.airipper.DropState },
    .{ "RipperDropStep", engine.game.airipper.DropStep },
    .{ "RipperEndDropState", engine.game.airipper.EndDropState },
    .{ "RipperEndDropStep", engine.game.airipper.EndDropStep },
    .{ "RipperAttachState", engine.game.airipper.AttachState },
    .{ "RipperAttachStep", engine.game.airipper.AttachStep },
    .{ "ParticleTemplate", engine.game.particles.Template },
    .{ "ParticleKind", engine.game.particles.Template.Kind },
    .{ "ParticleCurve", engine.game.particles.Curve },
    .{ "SmokeLevel", engine.game.main.smoke.Level },

    // Combat maneuvers.
    .{ "ManeuverOpcode", engine.game.aidefend.Opcode },
    .{ "ManeuverMirror", engine.game.aidefend.Mirror },
    .{ "ManeuverCondition", engine.game.aidefend.Condition },
    .{ "ManeuverNumber", engine.game.aidefend.maneuvers.Maneuver },
    .{ "ManeuverRecord", engine.game.aidefend.Maneuver },
    .{ "ManeuverScriptLine", engine.game.aidefend.ScriptLine },
    .{ "ManeuverHandler", engine.game.aidefend.Handler },
    .{ "ManeuverHandlers", engine.game.aidefend.Handlers },
    .{ "ManeuverInstruction", engine.game.aidefend.Instruction },
    .{ "ManeuverRange", engine.game.aidefend.Instruction.Range },
    .{ "ManeuverTicks", engine.game.aidefend.Instruction.Ticks },
    .{ "ManeuverFlag", engine.game.aidefend.Instruction.Flag },
    .{ "ManeuverJump", engine.game.aidefend.Instruction.Jump },
    .{ "ManeuverBranch", engine.game.aidefend.Instruction.Branch },
    .{ "FightState", engine.game.aifight.FightState },
    .{ "FightData", engine.game.aifight.FightData },

    // The C runtime.
    .{ "FILE", engine.libcmt.File },
    .{ "FileFlags", engine.libcmt.File.Flags },

    // Live objects and their models.
    .{ "GameObject", engine.game.gameobj.GameObject },
    .{ "ObjectType", engine.game.gameobj.Type },
    .{ "Quadrants", engine.game.gameobj.Quadrants },
    .{ "ObjectWing", engine.game.gameobj.Wing },
    .{ "ObjectFlags", engine.game.gameobj.GameObject.Flags },
    .{ "ObjectEnds", engine.game.gameobj.GameObject.Ends },
    .{ "ObjectSide", engine.game.gameobj.Side(i32) },
    .{ "ObjectSlot", engine.game.gameobj.Slot },
    .{ "ObjectVoice", engine.game.gameobj.Voice },
    .{ "NetworkFlags", engine.game.gameobj.NetworkFlags },
    .{ "GunMode", engine.game.gameobj.GunMode },
    .{ "Invulnerability", engine.game.gameobj.Invulnerability },
    .{ "PowerUp", engine.game.gameobj.PowerUp },
    .{ "DamageKind", engine.game.collision.Kind },
    .{ "Difficulty", engine.game.collision.Difficulty },
    .{ "GunGroupSide", engine.game.guns.GroupSide },
    .{ "ObjectRoutine", engine.game.gameobj.Routine },
    .{ "ModelNode", engine.game.objects.Node },
    .{ "NodeKind", engine.game.objects.Node.Kind },
    .{ "NodeFlags", engine.game.objects.Node.Flags },
    .{ "NodePose", engine.game.objects.Node.Pose },
    .{ "SurrenderFrame", engine.surrender.surrenderlib.srapiext.Frame },
    .{ "ObjectComponent", engine.game.gameobj.Component },
    .{ "ShipTypeEntry", engine.game.create.ShipType },
    .{ "MountedModel", engine.game.create.MountedModel },
    .{ "ShpPart", shp.Part },
    .{ "ShpPartFlags", shp.Part.Flags },
    .{ "ShpPartClass", shp.Part.Class },
    .{ "ShpPartTurretKind", shp.Part.TurretKind },
    .{ "ShpFiringArc", shp.FiringArc },
    .{ "ShpAttachment", shp.Attachment },
    .{ "NodePlayMode", shp.PlayMode(i32) },
    .{ "ShpAttachmentKind", shp.Attachment.Kind },
    .{ "Vec3", shp.Vec3 },

    // Textures.
    .{ "TextureCacheHeader", tcache.Header },
    .{ "TextureEntry", tcache.Entry },
    .{ "TextureImage", tcache.Image },
    .{ "TextureFlags", tcache.Flags },
    .{ "PixelFormat", tcache.PixelFormat },
    .{ "PixelChannel", tcache.Channel },

    // Meshes.
    .{ "SurrenderMaterial", engine.surrender.surrenderlib.srapiext.Material },
    .{ "MaterialCoordinates", engine.surrender.surrenderlib.srapiext.Material.Coordinates },
    .{ "MaterialBlend", engine.surrender.surrenderlib.srapiext.Material.Blend },
    .{ "MeshGroup", engine.surrender.surrenderlib.srapiext.Group },
    .{ "Stars", engine.surrender.surrenderlib.srstars.Stars },
    .{ "StarsKind", engine.surrender.surrenderlib.srstars.Stars.Kind },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (exported, 0..) |a, i| {
        for (exported[0..i]) |b| {
            if (std.mem.eql(u8, a[0], b[0])) @compileError("ghidragen: two types named " ++ a[0]);
            if (a[1] == b[1]) @compileError("ghidragen: " ++ @typeName(a[1]) ++ " is listed twice");
        }
    }
}

/// The Ghidra name of an exported type.
fn nameOf(comptime T: type) []const u8 {
    for (exported) |entry| {
        if (entry[1] == T) return entry[0];
    }
    @compileError("ghidragen: " ++ @typeName(T) ++ " is referred to but not exported");
}

/// Ghidra's type string for `T`.
fn typeString(comptime T: type) []const u8 {
    if (engine.isPointer(T)) {
        if (T.Target == anyopaque) return "void *";
        return typeString(T.Target) ++ " *";
    }
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |int| switch (int.bits) {
            8 => if (int.signedness == .signed) "sbyte" else "byte",
            16 => if (int.signedness == .signed) "short" else "ushort",
            32 => if (int.signedness == .signed) "int" else "uint",
            64 => if (int.signedness == .signed) "longlong" else "ulonglong",
            else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
        },
        .float => |float| switch (float.bits) {
            32 => "float",
            64 => "double",
            else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
        },
        // Consecutive dimensions go outermost first, as in C.
        .array => arrayString(T, ""),
        .@"struct", .@"union", .@"enum", .@"opaque" => nameOf(T),
        else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
    };
}

fn arrayString(comptime T: type, comptime dimensions: []const u8) []const u8 {
    return switch (@typeInfo(T)) {
        .array => |array| arrayString(array.child, dimensions ++ std.fmt.comptimePrint("[{d}]", .{array.len})),
        else => typeString(T) ++ dimensions,
    };
}

/// The rows defining `T`: a comptime string, so that a type the schema cannot express, or one that
/// refers to a type not exported, is a compile error rather than a failure at run time.
fn Definition(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const name = nameOf(T);
    if (engine.isCode(T)) {
        return "function\t" ++ name ++ "\t" ++ T.c_signature ++ "\n";
    }
    return switch (@typeInfo(T)) {
        .@"struct" => |info| switch (info.layout) {
            .@"extern" => structRows(T, name, info),
            .@"packed" => bitsRows(T, name, info),
            .auto => @compileError("ghidragen: " ++ @typeName(T) ++ " has no fixed layout"),
        },
        .@"union" => |info| switch (info.layout) {
            .@"extern" => unionRows(T, name, info),
            else => @compileError("ghidragen: " ++ @typeName(T) ++ " has no fixed layout"),
        },
        .@"enum" => |info| enumRows(T, name, info),
        else => @compileError("ghidragen: cannot define " ++ @typeName(T)),
    };
}

fn structRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Struct) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("struct\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        const bytes: ?usize = switch (@typeInfo(field.type)) {
            .array => |array| if (array.child == u8) array.len else null,
            else => null,
        };
        if (bytes != null and std.mem.startsWith(u8, field.name, "_unknown")) continue;
        const field_type = if (bytes != null and std.mem.indexOf(u8, field.name, "name") != null)
            std.fmt.comptimePrint("char[{d}]", .{bytes.?})
        else
            typeString(field.type);
        rows = rows ++ std.fmt.comptimePrint("field\t{s}\t{d}\t{s}\t{s}\n", .{
            name, @offsetOf(T, field.name), field.name, field_type,
        });
    }
    return rows;
}

fn bitsRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Struct) []const u8 {
    const base = typeString(info.backing_integer.?);
    var rows: []const u8 = std.fmt.comptimePrint("struct\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        const field_base = switch (@typeInfo(field.type)) {
            .bool, .int => base,
            .@"enum" => nameOf(field.type),
            else => @compileError("ghidragen: cannot make a bitfield of " ++ @typeName(field.type)),
        };
        rows = rows ++ std.fmt.comptimePrint("bits\t{s}\t0\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{
            name, @sizeOf(T), @bitOffsetOf(T, field.name), @bitSizeOf(field.type), field.name, field_base,
        });
    }
    return rows;
}

fn unionRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Union) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("union\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        rows = rows ++ std.fmt.comptimePrint("member\t{s}\t{s}\t{s}\n", .{ name, field.name, typeString(field.type) });
    }
    return rows;
}

fn enumRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Enum) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("enum\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        rows = rows ++ std.fmt.comptimePrint("value\t{s}\t{s}\t{d}\n", .{ name, field.name, field.value });
    }
    return rows;
}

/// Every row, in the order `exported` lists the types.
pub const schema = blk: {
    @setEvalBranchQuota(10_000_000);
    var rows: []const u8 = "";
    for (exported) |entry| rows = rows ++ Definition(entry[1]);
    break :blk rows;
};

pub fn write(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("# Generated by ghidragen types from the Zig definitions in src/.\n");
    try w.writeAll(schema);
}

test typeString {
    try std.testing.expectEqualStrings("uint[2][5]", comptime typeString([2][5]u32));
    try std.testing.expectEqualStrings("VmThread *", comptime typeString(engine.Pointer(engine.vm.Thread)));
    try std.testing.expectEqualStrings("byte *[4]", comptime typeString([4]engine.Pointer(u8)));
    try std.testing.expectEqualStrings("void *", comptime typeString(engine.Pointer(anyopaque)));
}

test structRows {
    const rows = comptime Definition(engine.game.objects.Node);
    try std.testing.expect(std.mem.indexOf(u8, rows, "_unknown_14") == null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "field\tModelNode\t164\tpart\tShpPart *\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, comptime Definition(shp.Part), "\tname_bytes\tchar[64]\n") != null);
}

test schema {
    try std.testing.expect(std.mem.indexOf(u8, schema, "struct\tVmThread\t184\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "field\tVmThread\t173\tcall_depth\tbyte\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "bits\tMissionPartFlags\t0\t1\t0\t1\tstart\tbyte\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "value\tTriggerRepeat\tcounted\t2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "member\tVmFunctionEntry\timplementation\tVmCommand *\n") != null);
}
