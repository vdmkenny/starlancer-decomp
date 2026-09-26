//! The mission script VM's run-time structures. **Unknown:** its source file; the interpreter's
//! code lies between `mission.cpp`'s and `attach.cpp`'s. [`vm/opcodes.zig`](vm/opcodes.zig) and
//! [`vm/conditions.zig`](vm/conditions.zig) transcribe its opcode and condition tables.
//!
//! A thread runs one block with a stack of its own. While it runs, the interpreter (`vm_run`) keeps
//! its stack pointer and block end in globals (`vm_stack_top`, `vm_block_end`) and hands every
//! opcode handler the addresses of the thread's instruction pointer and frame pointer.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../formats/dte.zig");
const commands = @import("game/executor/commands.zig");
const Command = @import("game/executor.zig").Command;
const engine = @import("../engine.zig");
const hud = @import("game/hud.zig");
const Code = engine.Code;
const Pointer = engine.Pointer;

pub const opcodes = @import("vm/opcodes.zig");
pub const conditions = @import("vm/conditions.zig");
pub const machine = @import("vm/machine.zig");
pub const triggers = @import("vm/triggers.zig");
pub const Machine = machine.Machine;
pub const Implementation = machine.Implementation;

/// An opcode handler, called through `vm_dispatch_table`. `ip` points at the thread's instruction
/// pointer, already past the opcode, and `frame` at its frame pointer. `previous` is what the last
/// handler returned. A handler returns it to carry on, or zero to end the loop.
pub const Handler = Code("uint __fastcall (byte **ip, uint **frame, uint previous)");

/// Threads the pool at `vm_threads` holds. `vm_thread_start` starts none while 31 are running.
pub const max_threads = 32;

/// Timers the table at `vm_timers` holds.
pub const max_timers = 16;

/// A script thread.
pub const Thread = extern struct {
    /// Stack pointer, saved while the thread is suspended.
    stack_top: Pointer(u32),
    /// End of the running block, where its constants start. Saved like `stack_top`.
    block_end: Pointer(u8),
    /// The running part's first argument: `push_argument n` reads `frame[n]`.
    frame: Pointer(u32),
    /// Value of `vm_clock` to resume at, or zero when not waiting.
    wake_time: u32,
    /// Next instruction to run. Null for a free slot.
    ip: Pointer(u8),
    /// Block end at which the script debugger's step-over stops.
    step_block_end: Pointer(u8),
    /// The values of the event that started the thread, which `push_local` reads.
    locals: [5]u32,
    stack: [32]u32,
    /// **Unknown.** `0xFF` when the thread starts.
    _unknown_ac: u8,
    /// Parts called and not yet returned from. A `return` at depth zero ends the thread.
    call_depth: u8,
    /// Set by `InterruptTriggerCode`: the thread waits for its trigger to fire again, which clears
    /// it, and the pass over the threads (`vm_threads_run`) leaves it alone until then.
    interrupted: bool,
    /// Index of the trigger that started the thread, or `0xFF` for none.
    trigger: u8,
    /// The last command's result, or the value the last part returned: what `push_result` reads.
    result: u32,
    /// **Unknown.** Zero when the thread starts.
    _unknown_b4: u32,

    comptime {
        assert(@offsetOf(Thread, "wake_time") == 0x0C);
        assert(@offsetOf(Thread, "ip") == 0x10);
        assert(@offsetOf(Thread, "locals") == 0x18);
        assert(@offsetOf(Thread, "stack") == 0x2C);
        assert(@offsetOf(Thread, "call_depth") == 0xAD);
        assert(@offsetOf(Thread, "result") == 0xB0);
        assert(@sizeOf(Thread) == 0xB8);
    }
};

/// What `call_part` pushes above a part's arguments, and `return` pops. The thread's frame pointer
/// then points at the first argument, `4 * arguments + 16` bytes below the stack pointer.
pub const CallRecord = extern struct {
    argument_count: u32,
    return_ip: Pointer(u8),
    caller_frame: Pointer(u32),
    caller_block_end: Pointer(u8),

    comptime {
        assert(@sizeOf(CallRecord) == 0x10);
    }
};

/// An entry of the command catalogue, or of a mission's part table: what `command` and
/// `call_part` call. The catalogue fills every field; a part's entry has only its block and its
/// argument count.
pub const Function = extern struct {
    entry: Entry,
    /// Arguments taken from the stack. The engine reads a byte of the catalogue's dword.
    argument_count: u8,
    _unknown_05: [3]u8,
    name: Pointer(u8),
    params: [max_params]Param,
    description: Pointer(u8),
    /// **Unknown.**
    flag: u32,

    pub const max_params = 8;

    pub const Entry = extern union {
        implementation: Pointer(Command),
        /// The part's block: its length halfword, then its code.
        block: Pointer(u16),
    };

    pub const Param = extern struct {
        kinds: commands.Kinds,
        /// **Unknown.**
        extra: u32,
        label: Pointer(u8),
    };

    comptime {
        assert(@offsetOf(Function, "name") == 0x08);
        assert(@offsetOf(Function, "params") == 0x0C);
        assert(@offsetOf(Function, "description") == 0x6C);
        assert(@sizeOf(Function) == 0x74);
    }
};

/// A timer that `CreateTimer` set.
pub const Timer = extern struct {
    /// The part to start, or -1 for a free entry.
    part: i32,
    /// Countdown to reload after each firing.
    period: u16,
    /// Firings left. Zero for no limit; `DestroyTimer` runs after the last.
    remaining: u16,
    /// Clock ticks to the next firing.
    countdown: u16,
    /// The ID the script gave it, which `DestroyTimer` takes.
    id: u16,
    /// `vm_clock` when it last counted down, so that it counts once per tick.
    last_tick: u32,

    comptime {
        assert(@sizeOf(Timer) == 0x10);
    }
};

/// An entry of a part table (`part_table`, `part_table_b`) as OpenReliant keeps it: the part's
/// block, by where it lies in the mission image, and its argument count. `mission_fill_part`
/// (`0x00452FD0`) fills the game's `Function` with the same two.
pub const Part = struct {
    /// Where the block's length halfword lies in the mission image; null for a part with no block.
    block: ?u32 = null,
    argument_count: u8 = 0,
};

/// Entries each part table has room for (`mission_alloc_part_tables`, `0x0045CB40`).
pub const part_table_size = 256;

/// A part table: the mission's parts, then entries of no block. **Fix:** the game leaves the
/// entries past the mission's parts as `malloc` gave them, and a call to one runs whatever they
/// hold.
pub const Parts = [part_table_size]Part;

/// The game's variables a script reads and writes by number (`push_array`, `select_array`): the
/// dwords from `jump_ready` (`0x0052A3F0`) on. **Unknown:** most of them, and where the block
/// ends. The shipped missions use the first 38.
pub const Variables = extern struct {
    /// `jump_ready` and `warp_ready`: whether the mission has a jump or a warp ready for JUMP
    /// DRIVE, which the display's prompt reads (`hud.Readiness`).
    ready: hud.Readiness = .{},
    _unknown_2: [2]u32 = @splat(0),
    /// `player_missiles_left`: the missile display's counts together.
    player_missiles_left: u32 = 0,
    _unknown_5: [4]u32 = @splat(0),
    /// `mission_over`: set once the camera has watched the mission's end long enough.
    mission_over: u32 = 0,
    _unknown_10: [28]u32 = @splat(0),
    /// Room for every number a byte names. In the game these are the globals after the block,
    /// which no shipped mission touches.
    beyond: [218]u32 = @splat(0),

    /// Variable `index`, as the script numbers them.
    pub fn slot(variables: *Variables, index: u8) *u32 {
        return &@as(*[256]u32, @ptrCast(variables))[index];
    }

    comptime {
        assert(@offsetOf(Variables, "player_missiles_left") == 0x0052A400 - 0x0052A3F0);
        assert(@offsetOf(Variables, "mission_over") == 0x0052A414 - 0x0052A3F0);
        assert(@sizeOf(Variables) == 256 * @sizeOf(u32));
    }
};

test Variables {
    var variables: Variables = .{};
    variables.slot(0).* = 1;
    variables.slot(9).* = 1;
    variables.slot(255).* = 7;
    try std.testing.expectEqual(.newly, variables.ready.jump);
    try std.testing.expectEqual(1, variables.mission_over);
    try std.testing.expectEqual(7, variables.beyond[217]);
}

/// One condition of the catalogue at `condition_descriptors`.
pub const ConditionDescriptor = extern struct {
    /// The developers' `TT_*` name, without the prefix.
    name: Pointer(u8),
    /// **Unknown.** Zero, except `0x400` for the internal `ExplosionShip`.
    _unknown_04: u16,
    /// The kinds of object whose triggers can have this condition.
    subjects: dte.Object.KindSet,
    /// The values an event of this condition carries, in order, up to an entry with a null label.
    /// Null for none.
    values: Pointer(EventValue),
    /// Index into `ObjectEvents` under which the matcher keeps each object's last event, for
    /// `push_event_value`. `0xFF` for none.
    slot: u8,
    /// Triggers with this repeat mode fire even when `verdict` vetoes the event.
    veto_exempt: dte.Trigger.Repeat,
    _unknown_0e: u16,
    /// Called before an event on a flight group or squad is counted.
    begin: Pointer(anyopaque),
    /// Called once for each member of the flight group.
    add_member: Pointer(anyopaque),
    /// Returns whether the event goes ahead: the value of `condition_verdict`.
    verdict: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ConditionDescriptor, "subjects") == 0x06);
        assert(@offsetOf(ConditionDescriptor, "slot") == 0x0C);
        assert(@offsetOf(ConditionDescriptor, "begin") == 0x10);
        assert(@sizeOf(ConditionDescriptor) == 0x1C);
    }
};

/// One value an event carries: an entry of a condition's `values` list.
pub const EventValue = extern struct {
    label: Pointer(u8),
    kinds: commands.Kinds,
    /// **Unknown.** `0xFF`, or `0x09` for the weapon of `ShotAt`.
    _unknown_08: u8,
    /// Whether a trigger's operand for this value is checked against the event's.
    checked: bool,
    _unknown_0a: u16,

    comptime {
        assert(@sizeOf(EventValue) == 0x0C);
    }
};

/// The component `push_component` named for a value it pushed. The list at `vm_component_tags`
/// holds one per such value since the last command, up to a terminating slot of -1.
pub const ComponentTag = extern struct {
    /// The stack slot the value is in.
    slot: Pointer(u32),
    component: u8,
    _unknown_05: [3]u8,

    /// Tags the list holds, not counting the terminator.
    pub const max = 8;

    comptime {
        assert(@sizeOf(ComponentTag) == 8);
    }
};

/// An event waiting in the queue at `event_queue` for `events_flush`, which raises it on the ship
/// and, for `groups`, on its flight group and the squads that hold it.
pub const QueuedEvent = extern struct {
    groups: bool,
    _unknown_01: [3]u8,
    ship: Pointer(dte.Ship),
    condition: dte.Condition,
    value_count: u8,
    _unknown_0a: u16,
    /// Room for eight; an event carries at most five.
    values: [8]u32,
    /// The component of the ship the event concerns, or `dte.Trigger.whole_object`.
    qualifier: u8,
    _unknown_2d: [3]u8,

    comptime {
        assert(@offsetOf(QueuedEvent, "ship") == 0x04);
        assert(@offsetOf(QueuedEvent, "values") == 0x0C);
        assert(@offsetOf(QueuedEvent, "qualifier") == 0x2C);
        assert(@sizeOf(QueuedEvent) == 0x30);
    }
};

/// The last events of the conditions that have a `slot`, kept for each object at `event_values`.
pub const ObjectEvents = extern struct {
    shot_at: [5]u32,
    destroyed: [5]u32,

    comptime {
        assert(@sizeOf(ObjectEvents) == 0x28);
    }
};

test {
    std.testing.refAllDecls(@This());
}
