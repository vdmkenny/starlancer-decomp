# The script VM at run time

How the payload runs mission scripts: threads, the interpreter loop, calls, commands, the clock, timers and events. The bytecode, and the triggers and parts that point into it, are described with the [mission format](../formats/dte.md#script). The structures below are defined in [`src/engine/vm.zig`](../../src/engine/vm.zig), and `make ghidra-annotate` applies them to the Ghidra project together with the names used here.

## Threads

Every block runs on a thread, a `0xB8`-byte context from the pool at `vm_thread_pool` (`0x537590`), which holds 32. `vm_thread_start` (`0x0045B8D0`) takes a block, points the thread's instruction pointer past the block's length halfword and its block end at `block + length`, and runs it at once unless told to defer it. It starts none while 31 are running.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Stack pointer, saved while the thread is suspended |
| `0x04` | 4 | Block end, where the block's constants start; saved likewise |
| `0x08` | 4 | Frame pointer: the running part's first argument |
| `0x0C` | 4 | Clock value to resume at; zero when not waiting |
| `0x10` | 4 | Instruction pointer; null marks a free slot |
| `0x14` | 4 | Block end at which the script debugger's step-over stops |
| `0x18` | 20 | The values of the event that started the thread, which `push_local` reads |
| `0x2C` | 128 | The stack |
| `0xAC` | 1 | **Unknown.** `0xFF` when the thread starts |
| `0xAD` | 1 | Call depth |
| `0xAE` | 1 | Set by `InterruptTriggerCode`: the thread waits for its trigger to fire again, which clears it |
| `0xAF` | 1 | Index of the trigger that started the thread; `0xFF` for none |
| `0xB0` | 4 | The last command's result, or the last part's return value, for `push_result` |
| `0xB4` | 4 | **Unknown.** Zero when the thread starts |

`vm_thread_run` (`0x0045BA30`) leaves a thread alone until the clock passes its wake time. Otherwise
it loads the thread's stack pointer and block end into `vm_stack_top` and `vm_block_end`, makes it
`vm_thread`, and calls the interpreter. The thread then has either finished, and its slot is freed,
or yielded, and its stack pointer and block end are saved for the next run.

Once a frame, `process_mission` (`0x0045A570`), which `mission_frame` calls after `events_flush`,
runs the script: `vm_threads_run` (`0x0045B9B0`) runs on each thread that was running as the pass
began, from the pool's first slot, but those `InterruptTriggerCode` holds. A thread the pass starts
in a later slot runs in the same pass while the pass has threads still to count. `process_mission`
then copies the live objects' places into the mission's ships (`mission_ships_sync`), and once the
clock has ticked since, runs the timers and checks the proximity conditions (`0x0045AF60`).

`mission_bind_tables` (`0x00453050`) fills the part tables as the mission is bound: section 8's
parts, whose blocks lie in the script, then section 17's, whose blocks lie in `script_b`. A part
whose offset is `0xFFFF` has no block. `mission_script_start` (`0x0045CBC0`) runs each part flagged
to run at the start, at once, before any trigger is armed; then it arms every object's triggers, and
marks each ship not destroyed and all its components intact.

## The interpreter

`vm_run` (`0x0045C980`) fetches an opcode, advances the instruction pointer past it, and calls the
opcode's handler from `vm_dispatch_table` (`0x4F6350`):

```c
uint __fastcall handler(byte **ip, uint **frame, uint previous);
```

`ip` points at the thread's instruction pointer and `frame` at its frame pointer. `previous` is what
the last handler returned, 1 for the first. A handler returns `previous` to carry on, and the loop
ends when one returns zero. The thread has then finished if a `return` ran at call depth zero,
which sets `vm_finished`; otherwise it has yielded, and resumes at its instruction pointer on its
next run.

The opcodes take the stack's values as unsigned: the comparisons test with `CMP` and `SBB`, the
divisions are `DIV`, and the sums and products wrap. The float opcodes load a value with `FILD`, as
an exact whole number, so the float comparisons compare as the others do. The float arithmetic
takes the value lower on the stack unsigned and the top value signed for a difference or a
quotient, and the top value unsigned and the lower one signed for a sum or a product, then truncates
with `__ftol`. The float stores apply a value, loaded unsigned, to the float the store target holds.
While a mission runs, Direct3D leaves the FPU at single precision, so each of these results is the
exact one rounded to a float. `push_percent n` pushes the top value times `n` times 0.01
(`0x004DC730`), each product rounded.

`select_array`, `select_global` and `select_argument` make a place the store target
(`vm_store_target`) and push its value; `assign` and the compound stores write it and pop both. The
array is a block of the game's variables from `jump_ready` (`0x0052A3F0`) on, which scripts use by
number: 0 is `jump_ready`, 1 `warp_ready`, 4 `player_missiles_left` and 9 `mission_over`.
**Unknown:** most of the others, and where the block ends; the shipped missions use the first 38.

The loop also serves a script debugger. With one attached, it can stop a thread at a byte that
section 10, one flag per script byte, marks, and report the position. **Unknown:** the debugger's
protocol.

## Calls

`call_part n` calls entry `n` of the part table. Above the arguments the caller pushed, it pushes a
call record, then points the frame at the first argument and enters the part's block:

| Offset | Field |
|---|---|
| `0x00` | Argument count |
| `0x04` | Return address |
| `0x08` | The caller's frame pointer |
| `0x0C` | The caller's block end |

`return` at a call depth above zero pops the part's return value into the thread's result, then the
record, then the arguments.

The part table and the command table share one `0x74`-byte record: the part's block or the command's
implementation at `0x00`, and the argument count in the byte at `0x04`. The command catalogue also
fills the name, parameters and description that follow; the loader fills only those two fields of a
part's entry.

## Commands

`command n` lowers the stack pointer by the command's argument count, so that it points at the
first argument, and calls the implementation:

```c
uint __fastcall command(byte **ip, uint *args);
```

The arguments are popped, and the result is written where the first was and stored as the thread's
result. It is also the handler's return value, so a zero result ends the loop: `Wait` sets the
thread's wake time to the clock plus its argument and returns zero, which suspends the thread until
then.

A command pops as many arguments as the catalogue gives it, whatever the script pushed. Mission
801's script calls `StartDirectorCam` with four where it takes five, so the command takes the
caller's block end for its first, and the part's `return` goes astray.

Before each call, `command` sets `vm_command_flag` (`0x00537584`) to bit 0 of the command's word in
section 24, inverted ([`.DTE` missions](../formats/dte.md)).

Many commands act on a ship, a flight group or a squad, which their first argument names by its
record's address. They hand `for_each_ship` (`0x0045D460`) a routine of their own for one ship, with
their arguments after the first, and it walks the entity (`0x0045D480`):

- A ship runs the routine once.
- A flight group runs it for each of its ships, in the mission's order (`flight_group_ships`),
  passing over the players' ships while `vm_command_flag` is set.
- A squad runs it for each of its members in turn, from its first in `squad_members`, until a record
  of another squad: a member that is a ship for the ship, with the component the member names
  tagged on the first argument (`vm_tag_component`) and untagged after (`0x0045D8E0`); a flight
  group for each of its ships, as above; and a squad for each of its own, a squad down.

Before the routine runs for a ship, its object's `+0x698` becomes a reference (`dte.Reference`) to
the first ship the walk ran for, none for the first (`0x0045D720`). **Unknown:** what reads it.

`SetAI` and `SetupLaunch` number the orders they give from 0 as they walk (`0x0040CBC0`,
`0x0040CBE0`): each order pushed takes the next number (`0x005185A8`) while the byte at
`0x005185B1` is set, and 0 otherwise. The escort, the formations, the jumps, Launch and Warp Out
read the number, a ship's place among its group's.

A command that waits runs again when its thread runs next: it moves the thread's instruction
pointer back over itself and returns zero. `WaitForMovie` moves it back 2 bytes, over the command
alone; `WaitForJumpOrLaunch` 4, over the push of its argument too, which then pushes it afresh.

Some of the commands mission 1 runs:

| Command | What it does |
|---|---|
| `SetInvulnerability` (`0x1A`) | Each ship the first argument names takes the invulnerability the second gives, or the component `push_component` named for it does. Only ships past the players' slots are reached, save in missions 30 to 35 and in the game's mode `0x00524FE4` 1 ([Objects](objects.md)) |
| `PlayMusic` (`0x23`) | Plays `music\` and the name the first argument points at, for ever at level 80, at once where the second is set, or once the music playing has faded out ([Sound](sound.md#music)) |
| `DisableTaunts` (`0x27`), `DisableGenericComms` (`0x2E`) | Keep the enemy's taunts on the radio (`0x00529CB4`), and the remarks the radio makes by itself (`0x00529538`), quiet while the argument is set |
| `UpdateEnvironmentFXState` (`0x38`) | Applies what the script asks of its space at once rather than at the next jump (`environment_update`), and aims the sun, the lights and the nebula again from the markers (`backdrop_place`) ([Backdrop](backdrop.md)) |
| `SetEnvironmentFXNebula` (`0x3C`) | Asks for the nebula the argument numbers (`nebula_requested`, `0x0058A6B8`) |
| `WaitForMovie` (`0x09`) | Waits while a film of the radio's plays (`0x0057C3A8`) |
| `OpenInstrument` (`0x40`), `CloseInstrument` (`0x41`) | Open the display's window the argument numbers, held open, or close it ([Display](hud.md#the-windows)) |
| `SetObjective` (`0x43`) | Sets the state of one of the mission's objectives ([Display](hud.md#the-objectives)) |
| `SetShipAvoidance` (`0x49`) | Each ship the first argument names, unless a stand-in, keeps clear of others no more while the second is set (`no_avoidance`, [Orders](orders.md#avoidance)) |
| `MultiplayerScriptSync` (`0x56`) | In a multiplayer game, holds the players' scripts in step; in a game of one, runs on |

## The clock and timers

`vm_clock` (`0x538C9C`) counts the seconds of the mission: `vm_clock_start` (`0x00457C10`) zeroes it
and starts a periodic multimedia timer at one second, whose callback (`0x00458910`) increments it
unless the script debugger holds it or the game is [paused](loop.md).

`CreateTimer` fills one of the 16 timers at `vm_timer_table` (`0x537470`), first destroying any
timer with the same ID:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The part to start; -1 for a free entry |
| `0x04` | 2 | Period, in seconds |
| `0x06` | 2 | Firings left; zero for no limit |
| `0x08` | 2 | Countdown to the next firing |
| `0x0A` | 2 | The timer's ID |
| `0x0C` | 4 | The clock value it last counted down at |

`vm_run_timers` (`0x0045D140`) counts each timer down once per clock value. At zero it starts the
part on a new thread for the scheduler, then reloads the countdown, or after the last firing
destroys the timer.

## Events

The game queues events as they happen, in the `0x30`-byte records at `event_queue` (`0x52ABD8`):
`event_post` (`0x0045B7C0`) for the ship alone, `event_post_group` (`0x0045B690`) for the ship, its
flight group and the squads that hold it. `events_flush` (`0x0045B840`), which `mission_frame`
calls once a frame, raises them all and empties the queue. Each carries a condition, up to five values, and a qualifier: the component of the ship
the event concerns, by its index among the components of the ship's live object, or `0xFF` for the
ship itself. A hit on a component queues ShotAt for the component and, except for hits of one kind,
for the ship; destroying one queues Destroyed for the component.

`trigger_match` (`0x0045CEA0`) handles an event on an object: its condition, its qualifier and the
values it carries. It walks the triggers in the object's slice of the trigger list, and takes each
one that is armed, has the event's condition and qualifier, links to a block and is not held back
by a veto:

1. It copies the event's values into a free thread's locals.
2. It checks the trigger's operands against the values: those the condition marks as checked, and
   of those, the ones whose low halfword is not `0xFFFF`. A failed check skips the trigger.
3. Unless a thread the trigger started is still running, it starts one on the trigger's block.
4. It disarms the trigger as its repeat mode says.

A condition with a slot also has its last event kept for each object, in the `0x28`-byte records at
`event_values`: ShotAt's five values, then Destroyed's. `push_event_value` reads them.

`condition_raise` (`0x00453210`) raises a group event on the ship's flight group and on the squads
that hold the ship; a squad member that names a component counts only for events on that
component. For ShotAt, Destroyed, Cloaked and Decloaked it first calls the condition's handlers:
one before, one for each member of the group, and one for a verdict. A vetoed event fires only the
triggers with the repeat mode the condition exempts.

- **Destroyed:** the verdict holds only once every member, or the member's named component, is
  destroyed. Until then the event fires only the group's triggers with repeat mode 1.
- **ShotAt:** the handlers replace the two damage values with the members' average and never veto.
- **Cloaked**, **Decloaked:** the handlers pass every event.

ShotAt's damage values both carry the victim's damage value (`ship_damage_value`, `0x00452CB0`): the
lowest of the four armor values of the ship's [live object](objects.md), or the component's own,
truncated. Its weapon value is always -1.

### Conditions

`condition_descriptors` (`0x4F6698`) describes each condition in `0x1C` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Name, as in `ShotAt` |
| `0x04` | 2 | **Unknown.** Zero, but `0x400` for the internal `ExplosionShip` |
| `0x06` | 2 | The kinds of object whose triggers can have the condition: bit 0 ships, 1 flight groups, 2 squads |
| `0x08` | 4 | The values an event carries, a list ending with a null label; null for none |
| `0x0C` | 1 | Slot in each object's kept events; `0xFF` for none |
| `0x0D` | 1 | The repeat mode exempt from a veto; `0xFF` for none |
| `0x10` | 12 | Handlers: before the members, per member, and the verdict |

Every trigger in the shipped missions belongs to a kind of object its condition allows.

An event value is 12 bytes: a label pointer, a kind mask of the kind the commands' parameters use, a
byte that is `0xFF` except `0x09` for ShotAt's weapon, and a byte saying whether a trigger's operand
is checked against the value. ShotAt carries the attacker, the shield damage, the hull damage, the
victim and the weapon; Destroyed the killer and the victim. The damage values set kind bit `0x1000`,
which no command parameter uses.

Events pass ships as the addresses of their records, and the matcher turns a trigger's operands into
the same form: the [mission format](../formats/dte.md#operands) gives the encoding.
`trigger_check_operand` (`0x0045D810`) compares a number operand of the proximity conditions as an
upper bound rather than for equality, but their distance value is not marked as checked, so the
matcher never compares it. The catalogue is also generated into
[`src/engine/vm/conditions.zig`](../../src/engine/vm/conditions.zig).

## In OpenReliant

[`vm/machine.zig`](../../src/engine/vm/machine.zig) runs the VM: the threads, the interpreter, the
clock, the timers, `for_each_ship`, and the commands that lie beside the interpreter
(`CreateTimer`, `DestroyTimer`, `Wait`, `InterruptTriggerCode` and
`KillAllScriptExecutionExecptMe`). [`game/executor.zig`](../../src/engine/game/executor.zig) has
the commands that act on the game: `CreateFlightGroup` ([Missions](missions.md#the-missions-ships)),
`SetAI`, `Fly`, `SetRescueProbabilities`, the launch's `SetupLaunch`, `StartLaunch` and
`WaitForJumpOrLaunch` ([Launches](launch.md#how-a-launch-is-given)), `SetInvulnerability`,
`SetShipAvoidance`, the radio's `DisableTaunts` and `DisableGenericComms`, `PlayMusic`, the
display's `OpenInstrument`, `CloseInstrument` and `SetObjective`, the space's
`SetEnvironmentFXNebula` and `UpdateEnvironmentFXState`, `WaitForMovie` and
`MultiplayerScriptSync`. They act on it through the world the mission's start and its frame give
the machine, which the game reaches through its globals. A command not ported
yet does nothing and gives 1, which lets the thread run on, and is logged the first time it runs
([#36](https://github.com/vdmkenny/openreliant/issues/36),
[#281](https://github.com/vdmkenny/openreliant/issues/281)).

Where the game holds an address on a thread's stack, OpenReliant holds where the place lies in the
mission image, which holds the script, its strings and every record a script names. The
instruction pointer and a block's end are such places, and a frame is a place on the thread's own
stack.

**Improvement:** the clock ticks from the game's own clock, once every 100 ticks the pause does not
hold, in the place of a timer of its own.

**Fix:** where the game faults or reads past a table, OpenReliant ends the thread and logs why: an
integer division by zero, a stack that runs past its 32 places or below its first, an opcode with no
handler, an instruction or a record past the image, an argument read with no frame, a store with no
target, a local past the fifth, and squads that hold one another round in a circle. The entries of a
part table past the mission's parts have no block, where the game leaves them as `malloc` gave them.
`for_each_ship` stops at a squad that holds itself round, which the game walks for ever, and passes
over a member no record stands for, and a ship past the last object's slot.

Not ported: the script debugger, the table of curve weights `mission_script_start` fills
(`0x00456F00`), and the ships the mission's sub-objects name, which it makes after the start part
where the part has not (`0x004571D0`), with the sub-objects
([#281](https://github.com/vdmkenny/openreliant/issues/281)).
