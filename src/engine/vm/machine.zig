//! The script VM at run time: the VM's globals, its threads, the interpreter, the clock and the
//! timers, and the commands that live beside them (the timers', `Wait`, `InterruptTriggerCode` and
//! `KillAllScriptExecutionExecptMe`). [docs/engine/script-vm.md](../../../docs/engine/script-vm.md)
//! describes the VM.
//!
//! Where the game holds an address on a thread's stack, OpenReliant holds where the place lies in
//! the mission image, which holds the script, its strings and every record a script names: a
//! ship's, a flight group's, a global's. The instruction pointer and a block's end are such places
//! too, and a thread's frame is its place on the thread's own stack. Where the game would fault, or
//! read past a table, OpenReliant ends the thread and logs why.
//!
//! Not ported: the script debugger that `vm_run` serves, and what `mission_script_start` does
//! beyond the VM (the table of curve weights `0x00456F00` fills, and the objects it creates for the
//! ships the mission launches).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.vm);

const dte = @import("../../formats/dte.zig");
const libcmt = @import("../libcmt.zig");
const math = @import("../surrender/math.zig");
const vm = @import("../vm.zig");
const executor = @import("../game/executor.zig");
const bind = @import("../game/mission/bind.zig");
const aigeneric = @import("../game/aigeneric.zig");

/// The value `push_null` pushes: no object.
pub const none: u32 = 0xFFFF_FFFF;

/// A command as OpenReliant runs it. Its result is stored in the thread's result, and a zero result
/// ends the thread's run, which a waiting command gives.
pub const Implementation = *const fn (call: Call) u32;

/// What a command runs with.
pub const Call = struct {
    machine: *Machine,
    /// The thread that runs it, by its place in the pool (`vm_thread`, `0x00537578`).
    thread: u8,
    /// Its arguments on the thread's stack, the first first.
    args: []u32,

    /// Has the thread run the command again when it runs next, and yields, as a command that waits
    /// does: its instruction pointer goes back `back` bytes, to the command itself, or to the
    /// pushes of its arguments before it too, which then push them afresh (`*ip -= back`).
    pub fn again(call: Call, back: u32) u32 {
        const thread = &call.machine.threads[call.thread];
        if (thread.ip) |at| thread.ip = at -% back;
        return 0;
    }
};

/// What ends a thread where the game faults or reads past a table.
pub const Fault = error{
    /// An instruction, a constant or a record past the mission image.
    OutsideImage,
    /// An opcode the VM has no handler for.
    UnknownOpcode,
    StackOverflow,
    StackUnderflow,
    /// A number past what it indexes: a part, a local, a command, an event's value.
    OutOfRange,
    /// `push_argument` or `select_argument` in a block started with no arguments.
    NoFrame,
    /// A store with no `select_` before it.
    NoStore,
    /// An integer division by zero.
    DivisionByZero,
    /// Squads that hold one another round in a circle.
    SquadCycle,
};

/// A thread as OpenReliant runs it: the game's record, with the places the game keeps in it as
/// pointers kept beside it.
pub const Running = struct {
    /// The game's record: its wake time, locals, stack, call depth, trigger and result. Its
    /// pointers stay null.
    record: vm.Thread = std.mem.zeroes(vm.Thread),
    /// Where its next instruction lies in the mission image; null for a free slot (`Thread.ip`).
    ip: ?u32 = null,
    /// Where the running block ends, and its constants start (`Thread.block_end`).
    block_end: u32 = 0,
    /// Where the running part's first argument lies on the stack; null for a block started with
    /// none (`Thread.frame`).
    frame: ?u8 = null,
    /// The first free place of its stack (`Thread.stack_top`).
    top: u8 = 0,

    fn push(thread: *Running, value: u32) Fault!void {
        if (thread.top >= thread.record.stack.len) return error.StackOverflow;
        thread.record.stack[thread.top] = value;
        thread.top += 1;
    }

    /// The value `back` places below the top of the stack: 1 for the top.
    fn below(thread: *Running, back: u8) Fault!*u32 {
        if (thread.top < back) return error.StackUnderflow;
        return &thread.record.stack[thread.top - back];
    }

    fn drop(thread: *Running, count: u8) Fault!void {
        if (thread.top < count) return error.StackUnderflow;
        thread.top -= count;
    }

    fn pop(thread: *Running) Fault!u32 {
        const value = (try thread.below(1)).*;
        thread.top -= 1;
        return value;
    }

    /// The two values on top of the stack, `a` below `b`, which a binary opcode takes, and leaves
    /// its result in `a`'s place.
    fn pair(thread: *Running) Fault!struct { a: *u32, b: u32 } {
        const b = (try thread.below(1)).*;
        const a = try thread.below(2);
        thread.top -= 1;
        return .{ .a = a, .b = b };
    }
};

/// What the last `select_` opcode chose for `assign` and the compound stores (`vm_store_target`,
/// `0x00537408`).
pub const Store = union(enum) {
    none,
    /// A dword of the mission image: a global's value.
    image: u32,
    /// A place on a thread's stack: an argument's.
    stack: struct { thread: u8, place: u8 },
    /// One of the game's variables.
    variable: u8,
};

/// The components `push_component` named for the values it pushed since the last command
/// (`vm_component_tag_list`, `0x00537420`), each by the place of its value on the running thread's
/// stack.
pub const Tags = struct {
    tags: [vm.ComponentTag.max]Tag = undefined,
    count: u8 = 0,

    pub const Tag = struct { place: u8, component: u8 };

    /// `vm_tag_component` (`0x0045D8B0`). **Fix:** the game writes a ninth past its list.
    fn add(tags: *Tags, component: u8, place: u8) void {
        if (tags.count == tags.tags.len) return;
        tags.tags[tags.count] = .{ .place = place, .component = component };
        tags.count += 1;
    }

    /// `vm_tags_clear` (`0x0045D890`), after every command.
    fn clear(tags: *Tags) void {
        tags.count = 0;
    }

    /// `0x0045D8E0`: the last tag taken off the list.
    fn pop(tags: *Tags) void {
        if (tags.count > 0) tags.count -= 1;
    }
};

/// A free timer, as `mission_script_start` fills the table: every byte `0xFF`.
const free_timer = std.mem.bytesToValue(vm.Timer, &([_]u8{0xFF} ** @sizeOf(vm.Timer)));

/// The value `push_percent` scales by (`0x004DC730`), a hundredth as a float rounds it.
const percent: f32 = 0.01;

pub const Machine = struct {
    gpa: Allocator,
    /// The mission it runs: its image, which the script reads its records from and writes its
    /// globals into, and the tables binding it made.
    mission: *bind.Mission,
    /// The game's random numbers (`rand`), which `random_branch` draws.
    random: *libcmt.Rand,
    /// `vm_thread_pool` (`0x00537590`).
    threads: [vm.max_threads]Running = @splat(.{}),
    /// `vm_thread_count` (`0x00537415`).
    thread_count: u8 = 0,
    /// `vm_finished` (`0x00537574`): set by a `return` at call depth zero.
    finished: bool = false,
    /// `0x00537410`: set once the pool's first thread finishes.
    first_finished: bool = false,
    store: Store = .none,
    tags: Tags = .{},
    /// `vm_clock` (`0x00538C9C`): seconds of the mission.
    clock: u32 = 0,
    /// `0x00537580`: set as the clock ticks, until the timers have run for the tick.
    ticked: bool = false,
    /// `0x00537400`: whether the timers run, set as the script starts.
    timers_running: bool = true,
    /// `vm_timer_table` (`0x00537470`).
    timers: [vm.max_timers]vm.Timer = @splat(free_timer),
    /// `vm_timer_count` (`0x00537468`).
    timer_count: u16 = 0,
    variables: vm.Variables = .{},
    /// `vm_command_flag` (`0x00537584`): bit 0 of the running command's flags in section 24,
    /// inverted.
    command_flag: bool = false,
    /// `0x00537401`: **Unknown.** Set to `0xFF` as the script starts and before every command.
    _unknown_00537401: u8 = 0xFF,
    /// `event_values`: the last events of the conditions that keep them, for each object.
    event_values: []vm.ObjectEvents = &.{},
    /// The commands not ported yet that have run, each logged the first time.
    logged: std.StaticBitSet(executor.commands.table.len) = .initEmpty(),
    /// What the commands act on the game through, which the game's code reaches through its
    /// globals: the world and its clock, as the mission's start and its frame give them. Null where
    /// there is no game, as in a test of the script alone, and the commands that act on it then do
    /// nothing.
    game: ?aigeneric.Context = null,
    /// `0x00537418`: the first ship the running `forEachShip` has run its command for, which each
    /// later one's object names (`GameObject._unknown_698`); and `0x00537575`, how many it has.
    walk_first: ?u16 = null,
    walk_count: u8 = 0,
    /// `0x0052A1E0`: whether the ships `WaitForJumpOrLaunch` walks are still jumping or launching.
    still_moving: bool = false,

    pub fn init(gpa: Allocator, mission: *bind.Mission, random: *libcmt.Rand) Machine {
        return .{ .gpa = gpa, .mission = mission, .random = random };
    }

    pub fn deinit(machine: *Machine) void {
        machine.gpa.free(machine.event_values);
    }

    /// `mission_script_start` (`0x0045CBC0`), as the mission's binding ends: every object's kept
    /// events emptied, the clock, the timers, the threads and the tags reset, and the timers set
    /// running. Then each start part runs, every object's triggers are armed, and each ship's
    /// Destroyed flag is cleared and its components all intact.
    pub fn start(machine: *Machine) !void {
        const file = machine.mission.file;
        machine.gpa.free(machine.event_values);
        machine.event_values = &.{};
        machine.event_values = try machine.gpa.alloc(vm.ObjectEvents, (try file.objects()).len);
        @memset(machine.event_values, std.mem.zeroes(vm.ObjectEvents));
        machine._unknown_00537401 = 0xFF;
        machine.first_finished = false;
        machine.clock = 0;
        machine.timers = @splat(free_timer);
        machine.resetThreads();
        machine.tags.clear();
        machine.timer_count = 0;
        machine.ticked = false;
        machine.timers_running = true;
        for (try file.parts()) |part| {
            if (part.flags.start and !part.isEmpty()) machine.runPart(part);
        }
        const triggers: []align(1) dte.Trigger = @constCast(try file.triggers());
        for (try file.objects()) |object| {
            const first = @min(object.first, triggers.len);
            for (triggers[first..@min(first + object.count, triggers.len)]) |*trigger| trigger.armed = 1;
        }
        for (try machine.mission.ships()) |*ship| {
            ship.flags = .{ .destroyed = false, ._unknown = 0 };
            ship.intact_components = std.math.maxInt(u32);
        }
    }

    /// `part_run` (`0x0045BAA0`): runs a part's block at once, on a new thread.
    fn runPart(machine: *Machine, part: dte.Part) void {
        const script = machine.mission.file.entry(.script);
        if (part.isEmpty() or !script.isUsed()) return;
        _ = machine.startThread(@intCast(script.offset + part.start()), null, false, null, null);
    }

    /// `vm_thread_start` (`0x0045B8D0`): starts a thread on `block`, the one at `into` or a free
    /// one, which runs now unless `deferred`. None starts while 31 run, or on no block.
    /// **Fix:** the game takes a free thread past its pool where none is free.
    fn startThread(machine: *Machine, block: ?u32, into: ?u8, deferred: bool, frame: ?u8, trigger: ?u8) ?u8 {
        const at = block orelse return null;
        if (machine.thread_count + 1 >= vm.max_threads) return null;
        const index = into orelse machine.allocThread() orelse return null;
        const length = machine.halfword(at) catch return null;
        const thread = &machine.threads[index];
        thread.ip = at + @sizeOf(u16);
        thread.frame = frame;
        thread.record.wake_time = 0;
        thread.record._unknown_b4 = 0;
        thread.block_end = at + length;
        thread.record.call_depth = 0;
        thread.record.interrupted = false;
        thread.record.trigger = trigger orelse no_trigger;
        thread.record._unknown_ac = 0xFF;
        machine.thread_count += 1;
        if (!deferred) machine.runThread(index);
        return index;
    }

    /// The trigger of a thread no trigger started.
    const no_trigger = 0xFF;

    /// `vm_thread_alloc` (`0x0045B960`): the first free thread, its stack emptied.
    fn allocThread(machine: *Machine) ?u8 {
        for (&machine.threads, 0..) |*thread, index| {
            if (thread.ip != null) continue;
            thread.top = 0;
            return @intCast(index);
        }
        return null;
    }

    /// `vm_threads_reset` (`0x0045B990`): frees every thread.
    fn resetThreads(machine: *Machine) void {
        machine.thread_count = 0;
        machine.threads = @splat(.{});
    }

    /// `vm_thread_run` (`0x0045BA30`): runs a thread until it yields or finishes, unless it waits
    /// for a later clock. A finished thread's slot is freed.
    fn runThread(machine: *Machine, index: u8) void {
        const thread = &machine.threads[index];
        if (thread.record.wake_time != 0) {
            if (machine.clock <= thread.record.wake_time) return;
            thread.record.wake_time = 0;
        }
        machine.finished = false;
        if (!machine.run(index)) return;
        thread.ip = null;
        machine.thread_count -= 1;
    }

    /// `vm_threads_run` (`0x0045B9B0`), once a frame (`process_mission`): each thread that was
    /// running as the pass began, and not waiting for its trigger (`InterruptTriggerCode`), runs
    /// on. A thread the pass starts in a later slot runs in it too, while the pass has threads
    /// still to count.
    pub fn runThreads(machine: *Machine) void {
        const count = machine.thread_count;
        if (count == 0) return;
        var counted: u8 = 0;
        for (0..vm.max_threads) |index| {
            if (machine.threads[index].ip != null) {
                if (!machine.threads[index].record.interrupted) machine.runThread(@intCast(index));
                counted += 1;
            }
            if (counted >= count) return;
        }
    }

    /// `vm_clock_tick` (`0x00458910`): a second of the mission has passed. The game's timer calls it
    /// once a second while the game is not paused.
    ///
    /// **Improvement:** OpenReliant ticks it from the game's own clock, once every
    /// `main.ticks_per_second` ticks the pause does not hold, in the place of a timer of its own.
    pub fn tick(machine: *Machine) void {
        machine.ticked = true;
        machine.clock +%= 1;
    }

    /// `vm_run_timers` (`0x0045D140`), once the clock has ticked (`process_mission`): each timer
    /// counts down once a clock value, and at zero starts its part on a new thread, then reloads
    /// its countdown, or after its last firing is destroyed.
    pub fn runTimers(machine: *Machine) void {
        const count = machine.timer_count;
        if (count == 0) return;
        var counted: u16 = 0;
        for (&machine.timers) |*timer| {
            if (timer.part != -1) {
                if (timer.last_tick != machine.clock) {
                    timer.countdown -%= 1;
                    if (timer.countdown == 0) machine.fire(timer);
                }
                counted += 1;
            }
            if (counted >= count) return;
        }
    }

    fn fire(machine: *Machine, timer: *vm.Timer) void {
        timer.last_tick = machine.clock;
        const part = machine.partEntry(.a, timer.part);
        if (timer.remaining == 0) {
            timer.countdown = timer.period;
        } else {
            timer.remaining -= 1;
            if (timer.remaining != 0) timer.countdown = timer.period else machine.destroyTimers(timer.id);
        }
        _ = machine.startThread(part.block, null, true, null, null);
    }

    /// A part table's entry `index`: none past the table.
    fn partEntry(machine: *Machine, table: enum { a, b }, index: anytype) vm.Part {
        const parts = switch (table) {
            .a => &machine.mission.parts,
            .b => &machine.mission.parts_b,
        };
        const at = std.math.cast(usize, index) orelse return .{};
        return if (at < parts.len) parts[at] else .{};
    }

    /// `cmd_CreateTimer` (`0x0045D210`, command `0x01`): a timer with an ID, which destroys any
    /// timer with the same, that starts a part every so many seconds, so many times or for ever.
    /// **Fix:** the game takes a timer past its table where none is free.
    pub fn createTimer(call: Call) u32 {
        const machine = call.machine;
        const id: u16 = @truncate(call.args[0]);
        machine.destroyTimers(id);
        const timer = for (&machine.timers) |*timer| {
            if (timer.part == -1) break timer;
        } else return 1;
        machine.timer_count += 1;
        timer.id = id;
        timer.part = @bitCast(call.args[1]);
        timer.period = @truncate(call.args[2]);
        timer.countdown = timer.period;
        if (timer.period == 1) timer.countdown += 1;
        timer.last_tick = 0;
        timer.remaining = @truncate(call.args[3]);
        return 1;
    }

    /// `cmd_DestroyTimer` (`0x0045D290`, command `0x02`): destroys every timer with an ID.
    pub fn destroyTimer(call: Call) u32 {
        call.machine.destroyTimers(@truncate(call.args[0]));
        return 1;
    }

    fn destroyTimers(machine: *Machine, id: u16) void {
        const count = machine.timer_count;
        if (count == 0) return;
        var counted: u16 = 0;
        for (&machine.timers) |*timer| {
            if (timer.part != -1) {
                if (timer.id == id) {
                    timer.part = -1;
                    machine.timer_count -= 1;
                }
                counted += 1;
            }
            if (counted >= count) return;
        }
    }

    /// `cmd_Wait` (`0x0045D2E0`, command `0x05`): the thread waits until the clock has passed so
    /// many seconds more.
    pub fn wait(call: Call) u32 {
        const machine = call.machine;
        machine.threads[call.thread].record.wake_time = call.args[0] +% machine.clock;
        return 0;
    }

    /// `cmd_InterruptTriggerCode` (`0x0045D450`, command `0x17`): the thread stops until its
    /// trigger fires again.
    pub fn interruptTriggerCode(call: Call) u32 {
        call.machine.threads[call.thread].record.interrupted = true;
        return 0;
    }

    /// `cmd_KillAllScriptExecutionExecptMe` (`0x0045D990`, command `0x51`): every thread but the
    /// caller's ends.
    pub fn killAllScriptExecutionExceptMe(call: Call) u32 {
        const machine = call.machine;
        for (&machine.threads, 0..) |*thread, index| {
            if (thread.ip == null or index == call.thread) continue;
            thread.ip = null;
            machine.thread_count -= 1;
        }
        return 1;
    }

    /// `vm_argument_component` (`0x0045D950`): the component `push_component` named for the
    /// running command's argument `index`, or null for none.
    pub fn argumentComponent(machine: *const Machine, thread: u8, index: u8) ?u8 {
        const first = machine.threads[thread].top;
        for (machine.tags.tags[0..machine.tags.count]) |tag| {
            if (tag.place -% first == index) return tag.component;
        }
        return null;
    }

    // --- The mission's records, as the script names them ------------------------------------

    /// `ship_index` (`0x004531C0`): the index among the mission's ships of the ship at `place`,
    /// the value the script names it by; null for none, zero, `none` or `0xFFFF`, which the game
    /// gives as `0xFFFF`. Like the game, it takes any other place for a ship's.
    pub fn shipIndex(machine: *const Machine, place: u32) ?u16 {
        return machine.recordIndex(.ships, place);
    }

    /// `flight_group_index` (`0x00452060`): the same for a flight group.
    pub fn flightGroupIndex(machine: *const Machine, place: u32) ?u16 {
        return machine.recordIndex(.flight_groups, place);
    }

    /// `squad_index` (`0x00453070`): the same for a squad.
    pub fn squadIndex(machine: *const Machine, place: u32) ?u16 {
        return machine.recordIndex(.squads, place);
    }

    fn recordIndex(machine: *const Machine, section: dte.Section, place: u32) ?u16 {
        if (place == 0 or place == none or place == no_record) return null;
        const offset = machine.mission.file.entry(section).offset;
        return @truncate((place -% offset) / section.stride().?);
    }

    /// The value the game gives a record index for none, and takes as none.
    const no_record = 0xFFFF;

    /// `record_kind` (`0x00453590`): whether `place` is a ship's, a flight group's or a squad's,
    /// taking the place just past a section's last record for one of its own, as the game does;
    /// null for anything else.
    pub fn recordKind(machine: *const Machine, place: u32) ?dte.Object.Kind {
        const file = machine.mission.file;
        for ([_]struct { dte.Section, dte.Object.Kind }{
            .{ .ships, .ship },
            .{ .flight_groups, .flight_group },
            .{ .squads, .squad },
        }) |pair| {
            const entry = file.entry(pair[0]);
            if (place >= entry.offset and place <= entry.offset + @as(u32, entry.count) * pair[0].stride().?) return pair[1];
        }
        return null;
    }

    /// Whether `place` lies among the records section `section` holds.
    fn holds(machine: *const Machine, section: dte.Section, place: u32) bool {
        const entry = machine.mission.file.entry(section);
        return entry.count != 0 and place >= entry.offset and place < entry.offset + @as(u32, entry.count) * section.stride().?;
    }

    /// A command's work for each ship `forEachShip` runs it for: the command's call, with its
    /// arguments after the first, and the ship by its index among the mission's ships.
    pub const ShipImplementation = *const fn (call: Call, ship: u16) void;

    /// `for_each_ship` (`0x0045D460`): runs `each` for each ship of the ship, flight group or squad
    /// the command's first argument names, with its arguments after the first. A flight group's
    /// ships run in the mission's order, and a squad's members in theirs, a member that is a flight
    /// group or a squad for each of its ships, one that names a component of a ship with the
    /// component tagged on the first argument (`argumentComponent`). While the command's flag is
    /// set (`command_flag`), the players' ships in a flight group are passed over. Each ship's
    /// object names the first ship the walk ran for (`GameObject._unknown_698`), or none for the
    /// first. Nothing runs without a game.
    pub fn forEachShip(call: Call, each: ShipImplementation) void {
        const machine = call.machine;
        if (machine.game == null or call.args.len == 0) return;
        machine.walk_first = null;
        machine.walk_count = 0;
        const rest: Call = .{ .machine = machine, .thread = call.thread, .args = call.args[1..] };
        machine.walkEntity(rest, call.args[0], each, 0) catch |fault| {
            log.warn("a command's ships are walked no further: {s}", .{@errorName(fault)});
        };
    }

    /// `for_each_ship`'s walk of `entity` (`0x0045D480`), `depth` squads down.
    ///
    /// **Fix:** the game walks a squad that holds itself round for ever, and walks a member of the
    /// object table no record stands for from address zero; OpenReliant stops once the walk has
    /// gone down more squads than the mission has, and passes over the member.
    fn walkEntity(machine: *Machine, call: Call, entity: u32, each: ShipImplementation, depth: usize) Fault!void {
        if (entity == 0) return;
        if (machine.holds(.ships, entity)) return machine.walkShip(call, entity, each);
        if (machine.holds(.flight_groups, entity)) return machine.walkGroup(call, entity, each);
        if (!machine.holds(.squads, entity)) return;
        const squads = try machine.records(dte.Squad, .squads);
        if (depth > squads.len) return error.SquadCycle;
        // The game takes a squad whose first member's low byte is `0xFF` for one with none.
        const first = try machine.halfword(entity + @offsetOf(dte.Squad, "first_member"));
        if (first & 0xFF == 0xFF) return;
        const own = machine.squadIndex(entity) orelse return;
        const members = machine.mission.file.entry(.squad_members);
        const objects = try machine.records(dte.Object, .objects);
        const end = members.offset + @as(u32, members.count) * @sizeOf(dte.SquadMember);
        var member = members.offset + @as(u32, first) * @sizeOf(dte.SquadMember);
        while (member < end) : (member += @sizeOf(dte.SquadMember)) {
            if (try machine.halfword(member + @offsetOf(dte.SquadMember, "squad")) != own) return;
            const id = try machine.halfword(member + @offsetOf(dte.SquadMember, "object_id"));
            if (id >= objects.len) continue;
            const record = machine.mission.records[id] orelse continue;
            switch (objects[id].kind) {
                .ship => {
                    const ship = switch (record) {
                        .ship => |at| machine.recordPlace(.ships, at),
                        else => continue,
                    };
                    const component = try machine.byte(member + @offsetOf(dte.SquadMember, "component"));
                    const tagged = component != dte.Trigger.whole_object;
                    if (tagged) machine.tags.add(component, machine.threads[call.thread].top);
                    try machine.walkShip(call, ship, each);
                    if (tagged) machine.tags.pop();
                },
                .flight_group => switch (record) {
                    .flight_group => |at| try machine.walkGroup(call, machine.recordPlace(.flight_groups, at), each),
                    else => {},
                },
                .squad => switch (record) {
                    .squad => |at| try machine.walkEntity(call, machine.recordPlace(.squads, at), each, depth + 1),
                    else => {},
                },
                _ => {},
            }
        }
    }

    /// Each ship of the flight group at `group`, as binding the mission listed them, the players'
    /// ones passed over while the command's flag is set.
    ///
    /// **Fix:** the game reads a group's list past the end where its first ship's place runs past
    /// it; OpenReliant stops there.
    fn walkGroup(machine: *Machine, call: Call, group: u32, each: ShipImplementation) Fault!void {
        const count = try machine.byte(group + @offsetOf(dte.FlightGroup, "ship_count"));
        const first = try machine.word(group + @offsetOf(dte.FlightGroup, "first_ship"));
        const listed = machine.mission.group_ships;
        const players = machine.game.?.world.objects.players;
        for (0..count) |n| {
            const at = @as(usize, first) + n;
            if (at >= listed.len) return;
            const ship = listed[at];
            if (machine.command_flag and ship < players) continue;
            try machine.walkShip(call, machine.recordPlace(.ships, ship), each);
        }
    }

    /// `0x0045D700`, `for_each_ship`'s work for one ship: its object names the first ship of the
    /// walk (`0x0045D720`), then the command runs for it. **Fix:** the game takes a ship past the
    /// last object's slot for an object past its array; OpenReliant passes over it.
    fn walkShip(machine: *Machine, call: Call, ship: u32, each: ShipImplementation) Fault!void {
        const index = machine.shipIndex(ship) orelse return;
        const all = machine.game.?.world.objects;
        if (index >= all.slots.len) return;
        const first: dte.Reference = .{ .index = machine.walk_first orelse dte.Reference.unset, .tag = .ship, ._unknown_24 = 0xFF };
        all.slots[index].object._unknown_698 = @bitCast(first);
        if (machine.walk_first == null) machine.walk_first = index;
        machine.walk_count +%= 1;
        each(call, index);
    }

    /// `vm_run` (`0x0045C980`): runs the thread from its instruction pointer, an opcode at a time,
    /// until a handler returns zero. True once the thread has finished, which a `return` at call
    /// depth zero does.
    fn run(machine: *Machine, index: u8) bool {
        var previous: u32 = 1;
        while (previous != 0) {
            previous = machine.step(index, previous) catch |fault| {
                log.warn("a script thread ends at {d}: {s}", .{ machine.threads[index].ip orelse 0, @errorName(fault) });
                machine.finished = true;
                machine.threads[index].record.call_depth = 0;
                return true;
            };
        }
        if (machine.threads[index].record.call_depth != 0) return false;
        if (machine.finished and index == 0) machine.first_finished = true;
        return machine.finished;
    }

    /// One opcode's handler (`vm_dispatch_table`, `0x004F6350`): what it does, with the handler's
    /// return value, `previous` to carry on or zero to end the run.
    fn step(machine: *Machine, index: u8, previous: u32) Fault!u32 {
        const thread = &machine.threads[index];
        const opcode: dte.Opcode = @enumFromInt(try machine.operand(thread));
        switch (opcode) {
            // The comparisons take the values as unsigned (`CMP`, `SBB`), and the float ones load
            // each as a whole number (`FILD`), exactly, so they compare as the others do.
            .equal => try compare(thread, .eq),
            .not_equal => try compare(thread, .neq),
            .greater, .greater_f => try compare(thread, .gt),
            .greater_equal, .greater_equal_f => try compare(thread, .gte),
            .less, .less_f => try compare(thread, .lt),
            .less_equal, .less_equal_f => try compare(thread, .lte),
            .in_flight_group, .not_in_flight_group => {
                const values = try thread.pair();
                const in = try machine.inFlightGroup(values.a.*, values.b);
                values.a.* = @intFromBool(in == (opcode == .in_flight_group));
            },
            .in_squad, .not_in_squad => {
                const values = try thread.pair();
                const in = try machine.inSquad(values.b, values.a.*, dte.Trigger.whole_object, 0);
                values.a.* = @intFromBool(in == (opcode == .in_squad));
            },
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .add_assign_f, .sub_assign_f, .mul_assign_f, .div_assign_f => {
                const value = (try thread.below(1)).*;
                const target = try machine.stored();
                target.* = switch (opcode) {
                    .assign => value,
                    .add_assign => target.* +% value,
                    .sub_assign => target.* -% value,
                    .mul_assign => target.* *% value,
                    .div_assign => try divide(target.*, value),
                    // `FILD` the value, then the operation on the float stored, rounded.
                    .add_assign_f => @bitCast(single(float(target.*) + unsigned(value))),
                    .sub_assign_f => @bitCast(single(float(target.*) - unsigned(value))),
                    .mul_assign_f => @bitCast(single(unsigned(value) * float(target.*))),
                    .div_assign_f => @bitCast(single(float(target.*) / unsigned(value))),
                    else => unreachable,
                };
                try thread.drop(2);
            },
            .add, .sub, .mul, .div, .logical_and, .logical_or, .add_f, .sub_f, .mul_f, .div_f => {
                const values = try thread.pair();
                const a = values.a.*;
                const b = values.b;
                values.a.* = switch (opcode) {
                    .add => a +% b,
                    .sub => a -% b,
                    .mul => a *% b,
                    .div => try divide(a, b),
                    .logical_and => @intFromBool(a != 0 and b != 0),
                    .logical_or => @intFromBool(a != 0 or b != 0),
                    // One loaded unsigned (`FILD`), the other taken signed (`FIADD` and the like),
                    // rounded, then truncated (`__ftol`).
                    .add_f => whole(single(unsigned(b) + signed(a))),
                    .sub_f => whole(single(unsigned(a) - signed(b))),
                    .mul_f => whole(single(unsigned(b) * signed(a))),
                    .div_f => whole(single(unsigned(a) / signed(b))),
                    else => unreachable,
                };
            },
            .command => return machine.command(index, try machine.operand(thread)),
            // The second catalogue is empty.
            .command_b => return error.OutOfRange,
            .call_part => try machine.callPart(index, machine.partEntry(.a, try machine.operand(thread))),
            .call_part_b => try machine.callPart(index, machine.partEntry(.b, try machine.operand(thread))),
            .spawn_part => try machine.spawnPart(index, machine.partEntry(.a, try machine.operand(thread)), true),
            .spawn_part_b => try machine.spawnPart(index, machine.partEntry(.b, try machine.operand(thread)), false),
            .branch_if_zero, .branch_if_zero_alt => {
                const at = thread.ip.?;
                const taken = try thread.pop() == 0;
                thread.ip = if (taken) at +% try machine.big(at) else at + 2;
            },
            .jump => {
                const at = thread.ip.?;
                thread.ip = at +% try machine.big(at);
            },
            .random_branch => try machine.randomBranch(thread),
            .@"return", .return_alt => return machine.returnFromPart(index),
            .push_array => try thread.push(machine.variables.slot(try machine.operand(thread)).*),
            .push_global => try thread.push(try machine.word(try machine.globalPlace(try machine.operand(thread)))),
            .push_constant => try thread.push(try machine.constant(thread, try machine.operand(thread))),
            .push_constant_wide => try thread.push(try machine.constant(thread, try machine.operandWide(thread))),
            .push_string, .push_string_alt => {
                const at = thread.ip.?;
                // The length byte counts itself.
                const length = try machine.byte(at);
                try thread.push(at + 1);
                thread.ip = at +% length;
            },
            .push_ship => try thread.push(machine.recordPlace(.ships, try machine.operand(thread))),
            .push_ship_wide => try thread.push(machine.recordPlace(.ships, try machine.operandWide(thread))),
            .push_component, .push_component_alt => {
                try thread.push(machine.recordPlace(.ships, try machine.operand(thread)));
                machine.tags.add(try machine.operand(thread), thread.top - 1);
            },
            .push_flight_group => try thread.push(machine.recordPlace(.flight_groups, try machine.operand(thread))),
            .push_squad => try thread.push(machine.recordPlace(.squads, try machine.operand(thread))),
            .push_sub_object => try thread.push(machine.recordPlace(.sub_objects, try machine.operand(thread))),
            .push_section_19 => try thread.push(machine.recordPlace(.unused_19, try machine.operand(thread))),
            .push_byte, .push_byte_alt => try thread.push(try machine.operand(thread)),
            .push_percent => {
                const share = try machine.operand(thread);
                // `FIMUL` by the share, then `FMUL` by a hundredth, each rounded.
                const scaled = single(unsigned((try thread.below(1)).*) * @as(f128, @floatFromInt(share)));
                try thread.push(whole(single(@as(f128, scaled) * percent)));
            },
            .push_local => {
                const local = try machine.operand(thread);
                if (local >= thread.record.locals.len) return error.OutOfRange;
                try thread.push(thread.record.locals[local]);
            },
            .push_argument => try thread.push(thread.record.stack[try argument(thread, try machine.operand(thread))]),
            .push_null => try thread.push(none),
            .push_result => try thread.push(thread.record.result),
            .push_event_value => try thread.push(try machine.eventValue(thread)),
            .select_array => {
                const variable = try machine.operand(thread);
                machine.store = .{ .variable = variable };
                try thread.push(machine.variables.slot(variable).*);
            },
            .select_global => {
                const place = try machine.globalPlace(try machine.operand(thread));
                machine.store = .{ .image = place };
                try thread.push(try machine.word(place));
            },
            .select_argument => {
                const place = try argument(thread, try machine.operand(thread));
                machine.store = .{ .stack = .{ .thread = index, .place = place } };
                try thread.push(thread.record.stack[place]);
            },
            .nop => {},
            _ => return error.UnknownOpcode,
        }
        return previous;
    }

    /// `vm_command` (`0x0045BEA0`): runs a command of the catalogue on its arguments, the top of
    /// the stack, which it pops. Its result takes the first argument's place, above the stack, and
    /// is the thread's result.
    fn command(machine: *Machine, index: u8, number: u8) Fault!u32 {
        const thread = &machine.threads[index];
        if (number >= executor.commands.table.len) return error.OutOfRange;
        const count: u8 = @intCast(executor.commands.table[number].params.len);
        try thread.drop(count);
        machine._unknown_00537401 = 0xFF;
        machine.command_flag = machine.commandFlags(number) & 1 == 0;
        const call: Call = .{ .machine = machine, .thread = index, .args = thread.record.stack[thread.top..][0..count] };
        const result = if (executor.implementation(number)) |implementation| implementation(call) else machine.unported(number);
        if (thread.top >= thread.record.stack.len) return error.StackOverflow;
        thread.record.stack[thread.top] = result;
        thread.record.result = result;
        machine.tags.clear();
        return result;
    }

    /// A command not ported yet does nothing and gives 1, which lets the thread run on as most
    /// commands do. It is logged the first time it runs.
    fn unported(machine: *Machine, number: u8) u32 {
        if (!machine.logged.isSet(number)) {
            machine.logged.set(number);
            log.info("the script command {s} is not ported yet: it does nothing", .{executor.commands.table[number].name});
        }
        return 1;
    }

    /// Command `number`'s flags in section 24; none past the section.
    fn commandFlags(machine: *const Machine, number: u8) u16 {
        const flags = machine.mission.file.records(u16, .command_flags) catch return 0;
        return if (number < flags.len) flags[number] else 0;
    }

    /// `vm_call_part` (`0x0045BFA0`) and `vm_call_part_b` (`0x0045C110`): above the arguments the
    /// caller pushed, a call record, then the part's block runs, its frame the first argument.
    /// **Fix:** the second table's call goes on to a part with no block, which the game runs from
    /// address zero.
    fn callPart(machine: *Machine, index: u8, entry: vm.Part) Fault!void {
        const block = entry.block orelse return;
        const thread = &machine.threads[index];
        const length = try machine.halfword(block);
        try thread.push(entry.argument_count);
        try thread.push(thread.ip.?);
        try thread.push(if (thread.frame) |frame| frame else none);
        try thread.push(thread.block_end);
        if (thread.top < @as(u16, entry.argument_count) + @sizeOf(vm.CallRecord) / @sizeOf(u32)) return error.StackUnderflow;
        thread.frame = @intCast(thread.top - entry.argument_count - @sizeOf(vm.CallRecord) / @sizeOf(u32));
        thread.ip = block + @sizeOf(u16);
        thread.block_end = block + length;
        thread.record.call_depth +%= 1;
    }

    /// `vm_return` (`0x0045C6E0`): at call depth zero, the thread has finished. Deeper, the part's
    /// value becomes the thread's result, and the call record and the arguments are popped.
    fn returnFromPart(machine: *Machine, index: u8) Fault!u32 {
        const thread = &machine.threads[index];
        machine.finished = thread.record.call_depth == 0;
        if (machine.finished) return 0;
        thread.record.result = try thread.pop();
        thread.block_end = try thread.pop();
        const frame = try thread.pop();
        thread.frame = if (frame == none) null else std.math.cast(u8, frame) orelse return error.OutOfRange;
        thread.ip = try thread.pop();
        // The argument count is read as a halfword.
        const count: u16 = @truncate(try thread.pop());
        if (count > thread.top) return error.StackUnderflow;
        thread.top -= @intCast(count);
        thread.record.call_depth -%= 1;
        return 1;
    }

    /// `vm_spawn_part` (`0x0045C070`) and `vm_spawn_part_b` (`0x0045C1E0`): the part's arguments
    /// move from the stack to a new thread's, which starts on the part's block at the next pass.
    /// The first table's does nothing for a part with no block; the second's pops the arguments
    /// first, then starts nothing.
    fn spawnPart(machine: *Machine, index: u8, entry: vm.Part, checks_block: bool) Fault!void {
        const thread = &machine.threads[index];
        if (checks_block and entry.block == null) return;
        try thread.drop(entry.argument_count);
        const new = machine.allocThread() orelse return;
        const count = entry.argument_count;
        if (count > machine.threads[new].record.stack.len) return error.StackOverflow;
        @memcpy(machine.threads[new].record.stack[0..count], thread.record.stack[thread.top..][0..count]);
        _ = machine.startThread(entry.block, new, true, 0, null);
        machine.threads[new].top = count;
    }

    /// `vm_random_branch` (`0x0045C910`): a roll of the game's `rand`, below 100, against each
    /// arm's threshold in turn; the first arm it falls below, where it names a target, is taken, or
    /// else the default. The targets count from the opcode.
    fn randomBranch(machine: *Machine, thread: *Running) Fault!void {
        const at = thread.ip.?;
        var arms = try machine.byte(at);
        var arm = at + 3;
        const roll: u8 = @intCast(@rem(machine.random.rand(), 100));
        const target = while (arms != 0) : (arm += 4) {
            arms -= 1;
            if (roll < try machine.byte(arm + 2)) {
                const taken = try machine.big(arm);
                break if (taken != no_arm) taken else try machine.big(at + 1);
            }
        } else try machine.big(at + 1);
        thread.ip = at +% target -% 1;
    }

    /// The target of an arm that takes the default instead.
    const no_arm: u16 = 0xFFFF;

    /// Where the store the last `select_` chose lies.
    fn stored(machine: *Machine) Fault!*align(1) u32 {
        return switch (machine.store) {
            .none => error.NoStore,
            .image => |at| @ptrCast((try machine.bytes(at, @sizeOf(u32))).ptr),
            .stack => |slot| &machine.threads[slot.thread].record.stack[slot.place],
            .variable => |variable| machine.variables.slot(variable),
        };
    }

    /// `ship_in_flight_group` (`0x0045CB20`): whether the ship at `ship` names the flight group at
    /// `group` (`ship_flight_group`, `0x00452AA0`). It reads the flight group byte wherever `ship`
    /// lies, as the game does.
    fn inFlightGroup(machine: *Machine, ship: u32, group: u32) Fault!bool {
        if (ship == 0) return false;
        const named = try machine.byte(ship +% @offsetOf(dte.Ship, "flight_group"));
        if (named == dte.Ship.no_flight_group) return group == 0;
        return machine.recordPlace(.flight_groups, named) == group;
    }

    /// `object_in_squad` (`0x00452AC0`): whether the object at `object` is a member of the squad at
    /// `squad`, as the component `tag`, or through a member that is a flight group or a squad.
    fn inSquad(machine: *Machine, squad: u32, object: u32, tag: u8, depth: u8) Fault!bool {
        const squads = machine.mission.file.entry(.squads);
        if (depth > (try machine.records(dte.Squad, .squads)).len) return error.SquadCycle;
        const first = try machine.halfword(squad +% @offsetOf(dte.Squad, "first_member"));
        if (first == dte.Squad.no_member) return false;
        const members = try machine.records(dte.SquadMember, .squad_members);
        const own = (squad -% squads.offset) / @sizeOf(dte.Squad);
        const id = try machine.halfword(object);
        const objects = try machine.records(dte.Object, .objects);
        for (members[@min(first, members.len)..]) |member| {
            if (member.squad != @as(u16, @truncate(own))) break;
            if (id == member.object_id and member.component == tag) return true;
            if (member.object_id >= objects.len) continue;
            const record = machine.mission.records[member.object_id];
            switch (objects[member.object_id].kind) {
                // A flight group the object table names with no record is a null group, which a
                // ship of no group is in.
                .flight_group => {
                    const group = if (record) |found| switch (found) {
                        .flight_group => |at| machine.recordPlace(.flight_groups, at),
                        else => 0,
                    } else 0;
                    if (try machine.inFlightGroup(object, group)) return true;
                },
                // **Fix:** the game reads a squad with no record from address zero.
                .squad => if (record) |found| switch (found) {
                    .squad => |at| if (try machine.inSquad(machine.recordPlace(.squads, at), object, tag, depth + 1)) return true,
                    else => {},
                },
                else => {},
            }
        }
        return false;
    }

    /// `vm_push_event_value` (`0x0045C5E0`): a value of the last event of a condition an object
    /// keeps (`event_values`).
    fn eventValue(machine: *Machine, thread: *Running) Fault!u32 {
        const condition = try machine.operand(thread);
        const value = try machine.operand(thread);
        const object = try machine.operand(thread);
        if (condition >= vm.conditions.table.len or object >= machine.event_values.len) return error.OutOfRange;
        const slot = vm.conditions.table[condition].slot orelse return error.OutOfRange;
        const kept: *const [10]u32 = @ptrCast(&machine.event_values[object]);
        const at = @as(usize, slot) * 5 + value;
        return if (at < kept.len) kept[at] else error.OutOfRange;
    }

    /// The records of a section of the mission, which fault where they run past its image.
    fn records(machine: *const Machine, comptime T: type, section: dte.Section) Fault![]align(1) const T {
        return machine.mission.file.records(T, section) catch error.OutsideImage;
    }

    /// Where record `index` of a fixed-stride section lies, which the game pushes as the record's
    /// address, whether or not the section holds it.
    fn recordPlace(machine: *const Machine, section: dte.Section, index: usize) u32 {
        const stride = section.stride().?;
        return @truncate(machine.mission.file.entry(section).offset +% index * stride);
    }

    /// Where global `index`'s value lies.
    fn globalPlace(machine: *const Machine, index: u8) Fault!u32 {
        return machine.recordPlace(.globals, index) + @offsetOf(dte.Global, "value");
    }

    /// Constant `index` of the running block, from its end.
    fn constant(machine: *Machine, thread: *Running, index: u16) Fault!u32 {
        return machine.word(thread.block_end +% @as(u32, index) * @sizeOf(u32));
    }

    /// The next byte at the thread's instruction pointer, which it moves past.
    fn operand(machine: *Machine, thread: *Running) Fault!u8 {
        const at = thread.ip.?;
        const value = try machine.byte(at);
        thread.ip = at + 1;
        return value;
    }

    /// The next two bytes, big-endian, as the script's two-byte operands are.
    fn operandWide(machine: *Machine, thread: *Running) Fault!u16 {
        const at = thread.ip.?;
        const value = try machine.big(at);
        thread.ip = at + 2;
        return value;
    }

    /// The text a string argument points at in the mission's image (`push_string`), up to its
    /// terminating zero.
    pub fn text(machine: *const Machine, at: u32) Fault![]const u8 {
        const image = machine.mission.image;
        if (at >= image.len) return error.OutsideImage;
        const rest = image[at..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return error.OutsideImage];
    }

    fn bytes(machine: *Machine, at: u32, count: u32) Fault![]u8 {
        const image = machine.mission.image;
        if (at > image.len or count > image.len - at) return error.OutsideImage;
        return image[at..][0..count];
    }

    fn byte(machine: *Machine, at: u32) Fault!u8 {
        return (try machine.bytes(at, 1))[0];
    }

    fn big(machine: *Machine, at: u32) Fault!u16 {
        return std.mem.readInt(u16, (try machine.bytes(at, 2))[0..2], .big);
    }

    fn halfword(machine: *Machine, at: u32) Fault!u16 {
        return std.mem.readInt(u16, (try machine.bytes(at, 2))[0..2], .little);
    }

    fn word(machine: *Machine, at: u32) Fault!u32 {
        return std.mem.readInt(u32, (try machine.bytes(at, 4))[0..4], .little);
    }
};

/// A comparison of the two values on top, which the result replaces.
fn compare(thread: *Running, how: std.math.CompareOperator) Fault!void {
    const values = try thread.pair();
    values.a.* = @intFromBool(std.math.compare(values.a.*, how, values.b));
}

/// An unsigned division (`DIV`). **Fix:** a division by zero, which faults the game, ends the
/// thread.
fn divide(a: u32, b: u32) Fault!u32 {
    if (b == 0) return error.DivisionByZero;
    return a / b;
}

/// Where argument `index` of the thread's frame lies on its stack.
fn argument(thread: *const Running, index: u8) Fault!u8 {
    const frame = thread.frame orelse return error.NoFrame;
    const at = @as(usize, frame) + index;
    if (at >= thread.record.stack.len) return error.OutOfRange;
    return @intCast(at);
}

/// A value as the FPU loads it with `FILD`: exact.
fn unsigned(value: u32) f128 {
    return @floatFromInt(value);
}

/// A value as `FIADD` and the like take it: a signed whole number.
fn signed(value: u32) f128 {
    return @floatFromInt(@as(i32, @bitCast(value)));
}

/// A stored float, as `FADD float ptr` and the like take it.
fn float(value: u32) f128 {
    return @as(f32, @bitCast(value));
}

/// A result as the FPU rounds it while Direct3D runs, its precision set to single: the exact value
/// rounded once.
fn single(exact: f128) f32 {
    return @floatCast(exact);
}

/// `__ftol`'s whole number of a result.
fn whole(value: f32) u32 {
    return @bitCast(math.ftol(value));
}

/// Fixtures for the tests: a machine on a mission written with `dte.write` from assembled
/// routines.
pub const testing = struct {
    const write = dte.write;
    pub const Routine = dte.assemble.Routine;

    /// A part: its routine's bytes, as `Routine.finish` gives them, and its arguments.
    pub const Part = struct { code: []const u8, arguments: u8 = 0, start: bool = false };

    /// Records for a script to name.
    pub const Records = struct {
        globals: []const u32 = &.{},
        ships: []const dte.Ship = &.{},
        flight_groups: []const dte.FlightGroup = &.{},
        objects: []const dte.Object = &.{},
        squads: []const dte.Squad = &.{},
        squad_members: []const dte.SquadMember = &.{},
    };

    pub const Fixture = struct {
        mission: bind.Mission,
        random: libcmt.Rand = .{},
        machine: Machine,

        /// A mission whose script holds `parts` one after another, each a part of its own, with
        /// `records`, and a machine on it.
        pub fn init(fixture: *Fixture, gpa: Allocator, parts: []const Part, records: Records) !void {
            var script: std.ArrayList(u8) = .empty;
            defer script.deinit(gpa);
            var descriptors: std.ArrayList(dte.Part) = .empty;
            defer descriptors.deinit(gpa);
            for (parts) |part| {
                var descriptor = std.mem.zeroes(dte.Part);
                descriptor.offset = @intCast(script.items.len / @sizeOf(u16));
                descriptor.length = @intCast(part.code.len / @sizeOf(u16));
                descriptor.arguments = part.arguments;
                descriptor.flags.start = part.start;
                try descriptors.append(gpa, descriptor);
                try script.appendSlice(gpa, part.code);
            }
            const globals = try gpa.alloc(dte.Global, records.globals.len);
            defer gpa.free(globals);
            for (globals, records.globals) |*record, value| record.* = .{ .name = 0, ._unknown_02 = 0, .value = value, ._unknown_08 = 0 };
            var sections: write.Sections = @splat(.{});
            const section = struct {
                fn of(all: *write.Sections, which: dte.Section, count: usize, bytes: []const u8) void {
                    all[@intFromEnum(which)] = .{ .count = @intCast(count), .bytes = bytes };
                }
            }.of;
            section(&sections, .script, script.items.len / @sizeOf(u16), script.items);
            section(&sections, .parts, descriptors.items.len, std.mem.sliceAsBytes(descriptors.items));
            section(&sections, .globals, globals.len, std.mem.sliceAsBytes(globals));
            section(&sections, .ships, records.ships.len, std.mem.sliceAsBytes(records.ships));
            section(&sections, .flight_groups, records.flight_groups.len, std.mem.sliceAsBytes(records.flight_groups));
            section(&sections, .objects, records.objects.len, std.mem.sliceAsBytes(records.objects));
            section(&sections, .squads, records.squads.len, std.mem.sliceAsBytes(records.squads));
            section(&sections, .squad_members, records.squad_members.len, std.mem.sliceAsBytes(records.squad_members));
            const image = try write.write(gpa, &sections, .{});
            fixture.mission = try .bind(gpa, image);
            fixture.random = .{};
            fixture.machine = .init(gpa, &fixture.mission, &fixture.random);
        }

        pub fn deinit(fixture: *Fixture) void {
            fixture.machine.deinit();
            fixture.mission.deinit();
        }

        /// Global `index`'s value.
        pub fn global(fixture: *Fixture, index: u8) u32 {
            return fixture.machine.word(fixture.machine.globalPlace(index) catch unreachable) catch unreachable;
        }

        /// A second of the mission, as the game's frame goes through it: the clock ticks, the timers
        /// run for the tick, and the threads run on.
        pub fn second(fixture: *Fixture) void {
            fixture.machine.tick();
            fixture.machine.runThreads();
            if (fixture.machine.ticked and fixture.machine.timers_running) {
                fixture.machine.runTimers();
                fixture.machine.ticked = false;
            }
        }
    };
};

/// Assembles a routine with `build`, which the caller frees.
fn assembled(gpa: Allocator, comptime build: fn (routine: *testing.Routine) anyerror!void) ![]u8 {
    var routine: testing.Routine = .init(gpa);
    defer routine.deinit();
    try build(&routine);
    return routine.finish();
}

test "the arithmetic, the compares and the stores" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Global 0 = 12, global 1 = 10 - 3.
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{12});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{10});
            try r.op(.push_byte, &.{3});
            try r.op(.sub, &.{});
            try r.op(.assign, &.{});
            // Global 2 = none > 1, which holds, the values being unsigned.
            try r.op(.select_global, &.{2});
            try r.op(.push_null, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.greater, &.{});
            try r.op(.assign, &.{});
            // Global 3 += 6 * 7, a wide constant among them; variable 9 = 1.
            try r.op(.select_global, &.{3});
            try r.pushConstant(6);
            try r.pushConstant(7);
            try r.op(.mul, &.{});
            try r.op(.add_assign, &.{});
            try r.op(.select_array, &.{9});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 0, 100 } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(12, fixture.global(0));
    try std.testing.expectEqual(7, fixture.global(1));
    try std.testing.expectEqual(1, fixture.global(2));
    try std.testing.expectEqual(142, fixture.global(3));
    try std.testing.expectEqual(1, fixture.machine.variables.mission_over);
    // The start part's thread has finished.
    try std.testing.expectEqual(0, fixture.machine.thread_count);
    try std.testing.expect(fixture.machine.first_finished);
}

test "Wait holds a thread until the clock has passed its seconds" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{2});
            try r.command("Wait");
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    // At 1 and at 2 it waits; past 2 it runs on.
    fixture.second();
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a call passes its arguments and returns its value" {
    const gpa = std.testing.allocator;
    const caller = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{4});
            try r.op(.push_byte, &.{5});
            try r.op(.call_part, &.{1});
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(caller);
    const called = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_argument, &.{0});
            try r.op(.push_argument, &.{1});
            try r.op(.add, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(called);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = caller, .start = true }, .{ .code = called, .arguments = 2 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(9, fixture.global(0));
    // The return took the record and the arguments off the stack.
    try std.testing.expectEqual(0, fixture.machine.threads[0].top);
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a spawned part takes its arguments to a thread of its own" {
    const gpa = std.testing.allocator;
    const spawner = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{3});
            try r.op(.spawn_part, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(spawner);
    const spawned = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_argument, &.{0});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(spawned);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = spawner, .start = true }, .{ .code = spawned, .arguments = 1 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    // The spawned thread waits for the pass.
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.machine.runThreads();
    try std.testing.expectEqual(3, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a timer starts its part every so many seconds, so many times" {
    const gpa = std.testing.allocator;
    const setter = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // CreateTimer(ID 1, part 1, every 2 seconds, twice).
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{2});
            try r.op(.push_byte, &.{2});
            try r.command("CreateTimer");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(setter);
    const counter = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.add_assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(counter);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = setter, .start = true }, .{ .code = counter } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.machine.timer_count);
    var counts: [6]u32 = undefined;
    for (&counts) |*count| {
        fixture.second();
        // The part the timer started runs at the next pass.
        fixture.machine.runThreads();
        count.* = fixture.global(0);
    }
    try std.testing.expectEqual([6]u32{ 0, 1, 1, 2, 2, 2 }, counts);
    try std.testing.expectEqual(0, fixture.machine.timer_count);
}

test "a command not ported yet does nothing and lets the thread run on" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_ship, &.{0});
            try r.op(.push_byte, &.{2});
            try r.command("PrintShipName");
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "InterruptTriggerCode holds a thread until its trigger fires again" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.command("InterruptTriggerCode");
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    fixture.machine.runThreads();
    try std.testing.expectEqual(0, fixture.global(0));
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    // As its trigger fires again.
    fixture.machine.threads[0].record.interrupted = false;
    fixture.machine.runThreads();
    try std.testing.expectEqual(1, fixture.global(0));
}

test "KillAllScriptExecutionExecptMe ends every other thread" {
    const gpa = std.testing.allocator;
    const killer = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.spawn_part, &.{1});
            try r.op(.spawn_part, &.{1});
            try r.command("KillAllScriptExecutionExecptMe");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(killer);
    const idle = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(idle);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = killer, .start = true }, .{ .code = idle } }, .{});
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "random_branch takes the first arm its roll falls below" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            const low = try r.label();
            const high = try r.label();
            const other = try r.label();
            const done = try r.label();
            try r.randomBranch(other, &.{ .{ .target = low, .threshold = 50, .extra = 0 }, .{ .target = high, .threshold = 100, .extra = 0 } });
            r.place(low);
            try r.op(.push_byte, &.{1});
            try r.branch(.jump, done);
            r.place(high);
            try r.op(.push_byte, &.{2});
            try r.branch(.jump, done);
            r.place(other);
            try r.op(.push_byte, &.{3});
            r.place(done);
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{0});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{0});
            try r.op(.add_assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    var expected: libcmt.Rand = .{};
    const roll = @rem(expected.rand(), 100);
    try fixture.machine.start();
    // The roll picked an arm, whose value lies under the stores.
    try std.testing.expectEqual(@as(u32, if (roll < 50) 1 else 2), fixture.machine.threads[0].record.stack[0]);
}

test "push_string pushes where its text lies" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.pushString("hello");
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(fixture.mission.image[fixture.global(0)..], 0));
}

test "the float opcodes round as the FPU does at single precision" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // 2^24 + 1 comes back 2^24.
            try r.op(.select_global, &.{0});
            try r.pushConstant(16777217);
            try r.op(.push_byte, &.{0});
            try r.op(.add_f, &.{});
            try r.op(.assign, &.{});
            // Half of 200: 200 * 50 times a hundredth rounds to 100, where truncating the exact
            // product would give 99.
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{200});
            try r.op(.push_percent, &.{50});
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{0});
            // A float global, 1.5, plus 2.
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{2});
            try r.op(.add_assign_f, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, @bitCast(@as(f32, 1.5)) } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(16777216, fixture.global(0));
    try std.testing.expectEqual(100, fixture.global(1));
    try std.testing.expectEqual(@as(f32, 3.5), @as(f32, @bitCast(fixture.global(2))));
}

test "a fault ends the thread" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.div, &.{});
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(0, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "in_flight_group and in_squad" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Ship 0 is in flight group 0, ship 1 is not.
            try r.op(.select_global, &.{0});
            try r.op(.push_ship, &.{0});
            try r.op(.push_flight_group, &.{0});
            try r.op(.in_flight_group, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_ship, &.{1});
            try r.op(.push_flight_group, &.{0});
            try r.op(.not_in_flight_group, &.{});
            try r.op(.assign, &.{});
            // Squad 0 holds ship 1 itself, and ship 0 through its flight group.
            try r.op(.select_global, &.{2});
            try r.op(.push_ship, &.{1});
            try r.op(.push_squad, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{3});
            try r.op(.push_ship, &.{0});
            try r.op(.push_squad, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var ships: [2]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    ships[0].object_id = 0;
    ships[0].flight_group = 0;
    ships[1].object_id = 1;
    ships[1].flight_group = dte.Ship.no_flight_group;
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = 2;
    var squad = std.mem.zeroes(dte.Squad);
    squad.object_id = 3;
    squad.first_member = 0;
    const members = [_]dte.SquadMember{
        .{ .object_id = 1, ._unknown_02 = 0, .squad = 0, ._unknown_06 = 0, .component = dte.Trigger.whole_object, ._unknown_09 = @splat(0) },
        .{ .object_id = 2, ._unknown_02 = 0, .squad = 0, ._unknown_06 = 0, .component = dte.Trigger.whole_object, ._unknown_09 = @splat(0) },
    };
    const objects = [_]dte.Object{
        .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
        .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
        .{ .kind = .flight_group, .count = 0, .first = 0, ._unknown_04 = 0 },
        .{ .kind = .squad, .count = 0, .first = 0, ._unknown_04 = 0 },
    };
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{ 0, 0, 0, 0 },
        .ships = &ships,
        .flight_groups = &.{group},
        .objects = &objects,
        .squads = &.{squad},
        .squad_members = &members,
    });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual([4]u32{ 1, 1, 1, 1 }, [4]u32{ fixture.global(0), fixture.global(1), fixture.global(2), fixture.global(3) });
}

test "the branches and the logic" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            const skip = try r.label();
            const never = try r.label();
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{5});
            try r.op(.assign, &.{});
            // Zero branches.
            try r.op(.push_byte, &.{0});
            try r.branch(.branch_if_zero, skip);
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{9});
            try r.op(.assign, &.{});
            r.place(skip);
            // One runs on.
            try r.op(.push_byte, &.{1});
            try r.branch(.branch_if_zero_alt, never);
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.logical_or, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.logical_and, &.{});
            try r.op(.assign, &.{});
            r.place(never);
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 7 } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual([3]u32{ 5, 1, 0 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
}

test "the float opcodes take one value unsigned and the other signed" {
    const gpa = std.testing.allocator;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // 5 less -3 is 8; 3 times -2 is -6; 7 over 2 is 3 once truncated; over zero, 0.
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{5});
            try r.pushConstant(@bitCast(@as(i32, -3)));
            try r.op(.sub_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.pushConstant(@bitCast(@as(i32, -2)));
            try r.op(.push_byte, &.{3});
            try r.op(.mul_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{7});
            try r.op(.push_byte, &.{2});
            try r.op(.div_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{3});
            try r.op(.push_byte, &.{7});
            try r.op(.push_byte, &.{0});
            try r.op(.div_f, &.{});
            try r.op(.assign, &.{});
            // A float global, 6: less 2, times 3, over 4.
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{2});
            try r.op(.sub_assign_f, &.{});
            try r.op(.push_byte, &.{0});
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{3});
            try r.op(.mul_assign_f, &.{});
            try r.op(.push_byte, &.{0});
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{4});
            try r.op(.div_assign_f, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 0, 1, @bitCast(@as(f32, 6)) } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(8, fixture.global(0));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -6))), fixture.global(1));
    try std.testing.expectEqual(3, fixture.global(2));
    try std.testing.expectEqual(0, fixture.global(3));
    try std.testing.expectEqual(@as(f32, 3), @as(f32, @bitCast(fixture.global(4))));
}

test "a part stores into its argument" {
    const gpa = std.testing.allocator;
    const caller = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{1});
            try r.op(.call_part, &.{1});
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(caller);
    const called = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_argument, &.{0});
            try r.op(.push_byte, &.{7});
            try r.op(.assign, &.{});
            try r.op(.push_argument, &.{0});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(called);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = caller, .start = true }, .{ .code = called, .arguments = 1 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(7, fixture.global(0));
}

test "push_local and push_event_value read what the event brought" {
    const gpa = std.testing.allocator;
    const kept = comptime for (vm.conditions.table, 0..) |condition, index| {
        if (condition.slot == 1) break index;
    } else unreachable;
    const code = try assembled(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_local, &.{2});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_event_value, &.{ kept, 1, 0 });
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const objects = [_]dte.Object{.{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 }};
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code }}, .{ .globals = &.{ 0, 0 }, .objects = &objects });
    defer fixture.deinit();
    try fixture.machine.start();
    fixture.machine.event_values[0].destroyed[1] = 42;
    const thread = fixture.machine.startThread(fixture.mission.parts[0].block, null, true, null, 3).?;
    fixture.machine.threads[thread].record.locals[2] = 17;
    fixture.machine.runThreads();
    try std.testing.expectEqual(17, fixture.global(0));
    try std.testing.expectEqual(42, fixture.global(1));
}

test "argumentComponent finds a command's argument's component" {
    var machine: Machine = .{ .gpa = std.testing.allocator, .mission = undefined, .random = undefined };
    // The command's arguments start at place 2; push_component tagged the second.
    machine.threads[0].top = 2;
    machine.tags.add(5, 3);
    try std.testing.expectEqual(5, machine.argumentComponent(0, 1));
    try std.testing.expectEqual(null, machine.argumentComponent(0, 0));
    machine.tags.clear();
    try std.testing.expectEqual(null, machine.argumentComponent(0, 1));
}
