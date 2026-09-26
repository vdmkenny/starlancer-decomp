//! tablegen: derives the engine's static tables from the game binary.
//!
//!     tablegen opcodes <LANCER.EXE> <disassembly.asm> <output.zig>
//!     tablegen commands <LANCER.EXE> <output.zig>
//!     tablegen conditions <LANCER.EXE> <output.zig>
//!     tablegen models <LANCER.EXE> <disassembly.asm> <output.zig>
//!     tablegen combat <LANCER.EXE> <output.zig>
//!     tablegen guns <LANCER.EXE> <output.zig>
//!     tablegen sounds <LANCER.EXE> <output.zig>
//!     tablegen controls <LANCER.EXE> <output.zig>
//!     tablegen orders <LANCER.EXE> <output.zig>
//!     tablegen maneuvers <LANCER.EXE> <output.zig>
//!     tablegen views <LANCER.EXE> <output.zig>
//!     tablegen objectives <LANCER.EXE> <output.zig>
//!     tablegen sequences <LANCER.EXE> <output.zig>
//!     tablegen sources <LANCER.EXE> <disassembly.asm> <strings.tsv> <output.zig>
//!
//! `opcodes`: the VM dispatches on a byte through a table of handler addresses. Reading that table
//! gives the opcode set, and following each handler gives the size and shape of the instruction it
//! decodes. `disassembly.asm` is what `make ghidra-export` writes for the payload executable.
//!
//! `commands`: the Executor catalogue that `0x21 command` indexes, which needs only the binary.
//!
//! `conditions`: the trigger condition catalogue, which also needs only the binary.
//!
//! `models`: the model of each ship type, and the models mounted on attachment points, which the
//! engine loads in code that the listing lets this follow.
//!
//! `combat`: the words of each ship type's combat stats that the executable holds: whether it can
//! be targeted, its name, its class and its side.
//!
//! `guns`: the words of each gun type's record that the executable holds: what a shot costs the
//! ship, the sound it makes and how often that sound is heard.
//!
//! `sounds`: the 3D sounds' definitions, the voice classes they play on, and how the player's
//! engine sounds for each ship type.
//!
//! `controls`: the player's actions and the bindings the game starts with.
//!
//! `orders`: the orders objects follow, with their routines, flags and priorities.
//!
//! `maneuvers`: the combat maneuvers' scripts, their opcodes' routines and Fight's choice lists.
//!
//! `views`: the camera's views, with the string that names each and its two flags.
//!
//! `objectives`: the strings that name each mission's objectives.
//!
//! `sequences`: how each capital ship type that splits in two as its hull is destroyed does so.
//!
//! `sources`: the source files the payload was compiled from, in link order, and the code known to
//! be each one's, from the paths their assertions hold. `strings.tsv` is the export's too.
//!
//! All come straight out of the binary, so the tables written are transcripts of the engine rather
//! than readings of the mission files.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const max_file_size = openreliant.engine.files.max_file_size;

const combat = @import("combat.zig");
const commands = @import("commands.zig");
const conditions = @import("conditions.zig");
const controls = @import("controls.zig");
const eval = @import("eval.zig");
const gun_stats = @import("guns.zig");
const sound_tables = @import("sounds.zig");
const image = @import("image.zig");
const maneuvers = @import("maneuvers.zig");
const models = @import("models.zig");
const orders = @import("orders.zig");
const sources = @import("sources.zig");
const sequences = @import("sequences.zig");
const views = @import("views.zig");
const objectives = @import("objectives.zig");
const x86 = @import("x86.zig");
const zig_text = @import("zig_text.zig");

/// Virtual address of the dispatch table, found from the `CALL dword ptr [...]` that the
/// interpreter's inner loop makes.
const dispatch_table: u32 = 0x004F6350;

/// Entries the table could hold. The real one is shorter; where it ends is worked out below.
const max_opcodes = 256;

const Handler = struct {
    opcode: u8,
    address: u32,
    shape: eval.Shape,
};

const usage =
    \\usage: tablegen opcodes <LANCER.EXE> <disassembly.asm> <output.zig>
    \\       tablegen commands <LANCER.EXE> <output.zig>
    \\       tablegen conditions <LANCER.EXE> <output.zig>
    \\       tablegen models <LANCER.EXE> <disassembly.asm> <output.zig>
    \\       tablegen combat <LANCER.EXE> <output.zig>
    \\       tablegen guns <LANCER.EXE> <output.zig>
    \\       tablegen sounds <LANCER.EXE> <output.zig>
    \\       tablegen controls <LANCER.EXE> <output.zig>
    \\       tablegen orders <LANCER.EXE> <output.zig>
    \\       tablegen maneuvers <LANCER.EXE> <output.zig>
    \\       tablegen views <LANCER.EXE> <output.zig>
    \\       tablegen objectives <LANCER.EXE> <output.zig>
    \\       tablegen sequences <LANCER.EXE> <output.zig>
    \\       tablegen sources <LANCER.EXE> <disassembly.asm> <strings.tsv> <output.zig>
    \\
;

const Mode = union(enum) {
    opcodes: struct { binary: []const u8, listing: []const u8, output: []const u8 },
    commands: struct { binary: []const u8, output: []const u8 },
    conditions: struct { binary: []const u8, output: []const u8 },
    models: struct { binary: []const u8, listing: []const u8, output: []const u8 },
    combat: struct { binary: []const u8, output: []const u8 },
    guns: struct { binary: []const u8, output: []const u8 },
    sounds: struct { binary: []const u8, output: []const u8 },
    controls: struct { binary: []const u8, output: []const u8 },
    orders: struct { binary: []const u8, output: []const u8 },
    maneuvers: struct { binary: []const u8, output: []const u8 },
    views: struct { binary: []const u8, output: []const u8 },
    objectives: struct { binary: []const u8, output: []const u8 },
    sequences: struct { binary: []const u8, output: []const u8 },
    sources: struct { binary: []const u8, listing: []const u8, strings: []const u8, output: []const u8 },

    /// The mode `args` names, then its paths in the order its fields list them.
    fn parse(args: []const [:0]const u8) ?Mode {
        if (args.len == 0) return null;
        const tag = std.meta.stringToEnum(std.meta.Tag(Mode), args[0]) orelse return null;
        const rest = args[1..];
        switch (tag) {
            inline else => |mode| {
                const Paths = @FieldType(Mode, @tagName(mode));
                const fields = @typeInfo(Paths).@"struct".fields;
                if (rest.len != fields.len) return null;
                var paths: Paths = undefined;
                inline for (fields, 0..) |field, i| @field(paths, field.name) = rest[i];
                return @unionInit(Mode, @tagName(mode), paths);
            },
        }
    }
};

/// The most of Ghidra's listing this reads: it is not one of the game's files, and runs longer.
const max_listing_size = 256 << 20;

/// The payload executable at `path`, read whole, as a reader of its memory.
fn loadBinary(init: std.process.Init, arena: std.mem.Allocator, path: []const u8) !image.Reader {
    const binary = try Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_file_size));
    return .init(try .parse(binary), binary);
}

/// The Ghidra export's file at `path`, read whole.
fn loadExport(init: std.process.Init, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_listing_size));
}

/// Writes the file at `path` with `emitFn`, which takes the writer and then `args`.
fn writeOutput(init: std.process.Init, path: []const u8, comptime emitFn: anytype, args: anytype) !void {
    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try Io.Dir.cwd().createFile(init.io, path, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try @call(.auto, emitFn, .{&out.interface} ++ args);
    try out.interface.flush();
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mode = Mode.parse(args[1..]) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    return switch (mode) {
        .opcodes => |paths| opcodes(init, arena, paths),
        .commands => |paths| catalogue(init, arena, paths),
        .conditions => |paths| conditionCatalogue(init, arena, paths),
        .models => |paths| modelTables(init, arena, paths),
        .combat => |paths| combatTable(init, arena, paths),
        .guns => |paths| gunTable(init, arena, paths),
        .sounds => |paths| soundTables(init, arena, paths),
        .controls => |paths| controlTable(init, arena, paths),
        .orders => |paths| orderTable(init, arena, paths),
        .maneuvers => |paths| maneuverTable(init, arena, paths),
        .views => |paths| viewTable(init, arena, paths),
        .objectives => |paths| objectiveTable(init, arena, paths),
        .sequences => |paths| sequenceTable(init, arena, paths),
        .sources => |paths| sourceMap(init, arena, paths),
    };
}

fn catalogue(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "commands")) !u8 {
    const all = try commands.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, commands.emit, .{all});
    std.debug.print("{d} commands -> {s}\n", .{ all.len, paths.output });
    return 0;
}

fn conditionCatalogue(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "conditions")) !u8 {
    const catalogue_read = try conditions.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, conditions.emit, .{catalogue_read});
    std.debug.print("{d} conditions -> {s}\n", .{ catalogue_read.conditions.len, paths.output });
    return 0;
}

fn modelTables(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "models")) !u8 {
    const reader = try loadBinary(init, arena, paths.binary);
    const tables = try models.read(arena, reader, try x86.parse(arena, try loadExport(init, arena, paths.listing)));
    try writeOutput(init, paths.output, models.emit, .{tables});
    std.debug.print("{d} ship types and the attachment models -> {s}\n", .{ tables.ship_types.len, paths.output });
    return 0;
}

fn combatTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "combat")) !u8 {
    const types = try combat.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, combat.emit, .{types});
    std.debug.print("{d} ship types' combat words -> {s}\n", .{ types.len, paths.output });
    return 0;
}

fn gunTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "guns")) !u8 {
    const types = try gun_stats.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, gun_stats.emit, .{types});
    std.debug.print("{d} gun types' own words -> {s}\n", .{ types.len, paths.output });
    return 0;
}

fn soundTables(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "sounds")) !u8 {
    const tables = try sound_tables.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, sound_tables.emit, .{tables});
    std.debug.print("{d} 3D sounds, their voice classes and the engines -> {s}\n", .{ tables.definitions.len, paths.output });
    return 0;
}

fn controlTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "controls")) !u8 {
    const bindings = try controls.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, controls.emit, .{bindings});
    std.debug.print("{d} actions -> {s}\n", .{ bindings.len, paths.output });
    return 0;
}

fn objectiveTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "objectives")) !u8 {
    const rows = try objectives.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, objectives.emit, .{rows});
    std.debug.print("{d} rows of objectives -> {s}\n", .{ rows.len, paths.output });
    return 0;
}

fn viewTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "views")) !u8 {
    const records = try views.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, views.emit, .{records});
    std.debug.print("{d} views -> {s}\n", .{ records.len, paths.output });
    return 0;
}

fn sequenceTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "sequences")) !u8 {
    const records = try sequences.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, sequences.emit, .{records});
    std.debug.print("{d} explosion sequences -> {s}\n", .{ records.len, paths.output });
    return 0;
}

fn orderTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "orders")) !u8 {
    const table = try orders.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, orders.emit, .{ table, try orders.identifiers(arena, table.orders) });
    std.debug.print("{d} orders in {d} groups -> {s}\n", .{ table.orders.len, table.groups.len, paths.output });
    return 0;
}

fn maneuverTable(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "maneuvers")) !u8 {
    const table = try maneuvers.read(arena, try loadBinary(init, arena, paths.binary));
    try writeOutput(init, paths.output, maneuvers.emit, .{ arena, table });
    std.debug.print("{d} maneuvers -> {s}\n", .{ table.maneuvers.len, paths.output });
    return 0;
}

fn opcodes(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "opcodes")) !u8 {
    const reader = try loadBinary(init, arena, paths.binary);
    const listing = try loadExport(init, arena, paths.listing);

    const base = reader.base;
    const text = reader.image.sectionByName(".text") orelse {
        std.debug.print("{s}: no .text section\n", .{paths.binary});
        return 1;
    };
    const text_start = base + text.virtual_address;
    const text_end = text_start + text.virtual_size;

    const entries = reader.records(u32, dispatch_table, max_opcodes) catch {
        std.debug.print("dispatch table at {x} is not in the image\n", .{dispatch_table});
        return 1;
    };

    const functions = try x86.parse(arena, listing);
    var by_address: std.AutoHashMapUnmanaged(u32, x86.Function) = .empty;
    for (functions) |function| try by_address.put(arena, function.address, function);

    // The table runs from its start to the first entry that is neither empty nor a code address.
    // Past that point the data is some other structure, which holds values that happen to look
    // like addresses.
    var handlers: std.ArrayList(Handler) = .empty;
    var length: usize = 0;
    for (entries, 0..) |entry, opcode| {
        if (entry == 0) continue;
        if (entry < text_start or entry >= text_end) break;
        length = opcode + 1;

        const handler = by_address.get(entry) orelse {
            std.debug.print("opcode {x:0>2}: no function at {x:0>8} in the listing\n", .{ opcode, entry });
            return 1;
        };
        const shape = eval.analyze(arena, handler) catch |err| {
            std.debug.print("opcode {x:0>2} ({s}): {t}\n", .{ opcode, handler.name, err });
            return 1;
        };
        try handlers.append(arena, .{ .opcode = @intCast(opcode), .address = entry, .shape = shape });
    }

    try writeOutput(init, paths.output, emit, .{ handlers.items, length });
    std.debug.print("{d} opcodes over a table of {d} entries -> {s}\n", .{
        handlers.items.len, length, paths.output,
    });
    return 0;
}

fn emit(w: *Io.Writer, handlers: []const Handler, length: usize) !void {
    try w.print(
        \\//! The mission script VM's instruction set.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's dispatch table at
        \\//! 0x{[table]X:0>8}, which holds {[length]d} entries. Do not edit by hand; run `make vm-opcodes`.
        \\
        \\
        \\/// What an instruction does to the instruction pointer.
        \\pub const Form = enum {{
        \\    /// Execution continues at the instruction after the operands.
        \\    sequential,
        \\    /// The operand bytes hold a displacement, relative to their own position, to where
        \\    /// execution resumes. The instruction itself still ends after them.
        \\    branch,
        \\    /// The one operand byte is a total length, covering itself: `length - 1` bytes of
        \\    /// inline data follow it, and execution resumes after them.
        \\    inline_data,
        \\    /// Control passes somewhere a linear decoder cannot follow.
        \\    transfer,
        \\}};
        \\
        \\pub const Info = struct {{
        \\    opcode: u8,
        \\    /// Operand bytes between the opcode and the next instruction. For `inline_data` this
        \\    /// counts only the length byte.
        \\    operands: u8,
        \\    form: Form,
        \\    /// Whether execution can continue at the instruction after the operands. Where it
        \\    /// cannot, the bytes that follow are reached only by a branch, so a linear sweep
        \\    /// would decode whatever happens to sit there.
        \\    falls_through: bool,
        \\    /// Address of the handler in the payload executable.
        \\    handler: u32,
        \\}};
        \\
        \\/// Every opcode the VM implements, in order.
        \\pub const table = [_]Info{{
        \\
    , .{ .table = dispatch_table, .length = length });

    for (handlers) |handler| {
        try w.print(
            "    .{{ .opcode = 0x{X:0>2}, .operands = {d}, .form = .{t}, .falls_through = {}, .handler = 0x{X:0>8} }},\n",
            .{
                handler.opcode,              handler.shape.operands, handler.shape.form,
                handler.shape.falls_through, handler.address,
            },
        );
    }

    try w.writeAll(
        \\};
        \\
        \\/// Looks up `opcode`, or null when the VM has no handler for it.
        \\pub fn find(opcode: u8) ?Info {
        \\    // The table is sorted, and short enough that a scan beats anything cleverer.
        \\    for (table) |info| {
        \\        if (info.opcode == opcode) return info;
        \\        if (info.opcode > opcode) break;
        \\    }
        \\    return null;
        \\}
        \\
        \\test find {
        \\    const std = @import("std");
        \\    try std.testing.expect(find(table[0].opcode) != null);
        \\    try std.testing.expect(find(0x00) == null);
        \\    for (table[1..], table[0 .. table.len - 1]) |next, previous| {
        \\        try std.testing.expect(next.opcode > previous.opcode);
        \\    }
        \\}
        \\
    );
}

fn sourceMap(init: std.process.Init, arena: std.mem.Allocator, paths: @FieldType(Mode, "sources")) !u8 {
    const reader = try loadBinary(init, arena, paths.binary);
    const code = try sources.functions(arena, try loadExport(init, arena, paths.listing));
    if (code.len == 0) return error.EmptyListing;
    const strings = try sources.stringAddresses(arena, try loadExport(init, arena, paths.strings));
    const files = try sources.read(arena, reader, code, strings);
    try writeOutput(init, paths.output, sources.emit, .{ code[0].address, files });

    var placed: usize = 0;
    for (files) |file| placed += @intFromBool(file.code != null);
    std.debug.print("{d} source files, {d} with code placed -> {s}\n", .{ files.len, placed, paths.output });
    return 0;
}

test Mode {
    const both = Mode.parse(&.{ "commands", "LANCER.EXE", "out.zig" }).?;
    try std.testing.expectEqualStrings("out.zig", both.commands.output);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{ "opcodes", "LANCER.EXE" }));
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{"bogus"}));

    const models_mode = Mode.parse(&.{ "models", "LANCER.EXE", "disassembly.asm", "out.zig" }).?;
    try std.testing.expectEqualStrings("disassembly.asm", models_mode.models.listing);
    const controls_mode = Mode.parse(&.{ "controls", "LANCER.EXE", "out.zig" }).?;
    try std.testing.expectEqualStrings("out.zig", Mode.parse(&.{ "combat", "LANCER.EXE", "out.zig" }).?.combat.output);
    try std.testing.expectEqualStrings("LANCER.EXE", controls_mode.controls.binary);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{ "controls", "LANCER.EXE" }));
    try std.testing.expectEqualStrings("out.zig", Mode.parse(&.{ "views", "LANCER.EXE", "out.zig" }).?.views.output);
    const sources_mode = Mode.parse(&.{ "sources", "LANCER.EXE", "disassembly.asm", "strings.tsv", "out.zig" }).?;
    try std.testing.expectEqualStrings("strings.tsv", sources_mode.sources.strings);
}

test {
    std.testing.refAllDecls(@This());
    _ = combat;
    _ = gun_stats;
    _ = commands;
    _ = conditions;
    _ = controls;
    _ = eval;
    _ = image;
    _ = maneuvers;
    _ = models;
    _ = orders;
    _ = sequences;
    _ = sources;
    _ = views;
    _ = objectives;
    _ = x86;
    _ = zig_text;
}
