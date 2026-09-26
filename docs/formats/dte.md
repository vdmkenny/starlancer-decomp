# `.DTE` missions

Each of the 44 missions is one image: the ships it places, the globals it seeds, the triggers it
arms, and the script they run.

```bash
sltool dte info <mission>        # counts and sizes
sltool dte sections <mission>    # the 27-entry directory
sltool dte ships <mission>       # placed ships and nav points
sltool dte triggers <mission>    # triggers, with the object whose slice holds each
sltool dte strings <mission>     # the string pool
sltool dte parts <mission>       # the script's named routines
sltool dte script <mission>      # every trigger block and part, disassembled
make check-missions              # parse all 44
```

## Container

A mission inside a `.HOG` is RefPack compressed; one loose in `missions\` is stored expanded. The
archive's reader expands a member that begins `10 FB`, but a loose file is read as it is, so it
must be stored expanded ([Missions](../engine/missions.md#the-file)). A retail install carries two
loose missions, `mission18.dte` and `mission25.dte`, which begin `08 33` where their archive copies
begin `10 FB`. `sltool hog` expands members as it extracts.

## Directory

The image opens with **27 entries of 8 bytes**:

| Offset | Type | Field |
|---|---|---|
| 0 | u16 | Records in use, except where noted below |
| 2 | u8 | Unused |
| 3 | u8 | Four format flags, in the low bits, which the binder notes and nothing reads. Every entry of a shipped mission holds the same: 15 in most, 7 in `mission191` and `mission271`, 3 in `mission801` and 1 in `mission88` |
| 4 | u32 | Offset of the section, or `0xFFFF` when unused |

Capacity is fixed: a section's offset is the same in every mission built from the same template, and
the count says how much of the reserved room is filled, so most missions are exactly the same size.

| # | Section | Stride | Contents |
|---|---|---|---|
| 0 | strings | | String pool |
| 1 | operands_a | 2 | Operand resolution |
| 2 | globals | `0x0C` | Named values the script reads and writes |
| 3 | ships | `0x4C` | Placed ships, stations and nav points |
| 4 | flight_groups | `0x14` | Flight groups |
| 5 | triggers | `0x30` | |
| 6 | script | | Bytecode. **The count is in halfwords** |
| 7 | objects | 8 | The object table, indexed by object ID: see [Objects](#objects) |
| 8 | parts | `0x1C` | One descriptor per named script routine |
| 10 | script_flags | 1 | One flag per script byte, which the interpreter consults for the script debugger |
| 12 | squads | `0x0C` | Squads |
| 13 | squad_members | `0x0C` | Squad membership records |
| 14 | formations | 8 | Ship formations: the first of each one's points in section 15 at `+4` |
| 15 | formation_points | `0x10` | The formations' points |
| 16 | curves | `0x44` | The curves the director's camera flies along: see [Curves](#curves) |
| 17 | parts_b | `0x1C` | Part descriptors for section 18 |
| 18 | script_b | | A second bytecode section |
| 21 | openreliant_name | 1 | **OpenReliant's own:** the mission's name, see [OpenReliant's mission name](#openreliants-mission-name) |
| 22 | operands_b | 2 | |
| 24 | command_flags | 2 | One `u16` per Executor command |
| 25 | command_flags_b | 2 | The same for the second command catalogue |
| 26 | operands_c | 2 | A third operand table, beside sections 1 and 22: `0x004529D0` picks one of the three by a bank number |

Sections 17 to 21 and 25 are empty in all 44 missions. The engine reads nothing of sections 9, 20,
21 and 23: the binder binds 21 into a local variable of its own, and the rest into globals nothing
reads. Sections 9 and 23 hold records in some missions, likely the original editor's. Of the
directory's 128 slots before the first section, at `0x400`, the binder reads the first 27. Slot 27
holds the file's size in most missions and is unused in the rest, and slots 28 on are unused in
all of them. Section 24, where a mission has it, holds one
entry per command of the [catalogue](#commands): `command` passes bit 0 of the entry, inverted, to
the engine before each call, and with the bit clear `for_each_ship` passes over the players' ships
in a flight group or a squad ([Script VM](../engine/script-vm.md)). In the 36 missions of the
template each entry has a bit for each of the command's parameters, save the entries of
`ClearAI`, `SetPatrolRoute`, `SetTriggerState`, `SetAnyTriggerState`, `MovingShipFollowCurve` and
`MovingShipBackupCurve`, which are 0. The other 8 missions leave the section empty, which clears
the bit for every command. In every mission `script_flags` holds twice the count of section 6: one
entry per script byte.

## OpenReliant's mission name

**This is OpenReliant's convention, not the game's.** OpenReliant keeps a name for a mission in
section 21, which the game binds but never reads and no shipped mission uses. OpenReliant shows it
(`openreliant missions`); the game plays a mission with it as it plays any other, and a mission is
complete without it.

The section's count is its size in bytes. It holds an 8-byte header, then the name:

| Offset | Type | Field |
|---|---|---|
| `0x00` | char x4 | Tag: `ORMN` |
| `0x04` | u16 | Version: 1 |
| `0x06` | u16 | The name's length in bytes |
| `0x08` | | The name, in UTF-8, then a NUL |

OpenReliant reads a name only where the tag is `ORMN`, the version 1, and the name fits in the
section; anything else in section 21 it leaves alone. Other mission tools may not keep the section
when they write a mission out.

## String pool

A run of NUL-terminated names, **referenced by byte offset into the pool, not by index**, which is
why a `u16` suffices: the pool reserves 65,535 bytes. Byte offsets resolve every ship name in all 44
missions, for example `Player_Ship`, `(A1)Naginata`, `(WL)Viper's Coyote`, `Convoy Nav Point`.

## Ships

Stride `0x4C`, one per placed object, nav points included.

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Object ID |
| `0x04` | u16 | Name, as a string pool offset |
| `0x08` | f32 x3 | Position, copied from `0x1C` when the mission loads |
| `0x14` | u8 | Flight group, or `0xFF` for none |
| `0x15` | u8 | Pilot: the record of `pilotstats.bin` that flies the ship, or `0xFF` for none, as the player's own record, the nav points and the planets have |
| `0x17` | u8 | Flags, the engine's own: bit 0 marks the ship destroyed. Zero in the files |
| `0x18` | u16 | Kind: the ship's type below `0x100`; nav points and markers use 999 and `0x3E3` to `0x3E8`, waypoints `0x3E5` |
| `0x1B` | u8 | Set for a waypoint once binding the mission has listed it |
| `0x1C` | f32 x3 | Position as authored |
| `0x28` | u16 | The kind of the ship it launches from, the first of the mission's ships of that kind |
| `0x2B` | u8 | The gate of that ship it launches through, or `0xFF` for a ship that does not launch |
| `0x2E`, `0x3A`, `0x4A` | i16 | Yaw, pitch, roll, in whole degrees |
| `0x30` | u32 | The ship's intact components, a bit each |
| `0x34` | u16 | The formation point Formation Regroup flies the ship to, or `0xFFFF` for none |
| `0x3D` | u8 | The loadout tier its missile racks are fitted by (`create.settledTier`): 0 or 255, as most records hold, asks for the campaign's |
| `0x40` | i16 | For a point of kind `0x3E3`, the index of the curve it marks a place on, or -1 for none |
| `0x44` | f32 | The share of the way along that curve the place lies at |

When the mission's script starts, the engine clears the flags at `0x17` and sets every bit at
`0x30`. Destroying component `n` of the ship clears bit `n & 31`, and destroying the ship sets bit 0
of the flags and raises its Destroyed event, which it raises no more.

Each angle sits two bytes after its runtime copy, at `0x2C`, `0x38` and `0x48`. Every record holds
angles within [-360, 360]. Positions are absolute, on the order of 10^7. `in_flight_group` reads
the flight group byte.

## Flight groups

Stride `0x14`.

| Offset | Type | Field |
|---|---|---|
| `0x00` | u16 | Object ID |
| `0x04` | u16 | Name, as a string pool offset, such as `(FG)Reliant` |
| `0x08` | u8 | The wing the mission lists the group's ships in: 0 the player's, 1 and 2 two more, `0xFF` none |
| `0x09` | u8 | How many of the mission's ships are in the group |
| `0x0C` | u32 | Where the group's first ship stands in the list of the groups' ships, or -1 |

Binding the mission works out `0x09` and `0x0C`, whatever the file holds
([Missions](../engine/missions.md#binding)).

## Curves

Stride `0x44`: a cubic Hermite spline from one of the mission's ships to another, which the
director's camera flies along ([The director's camera](../engine/director.md)).

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | The ship it starts at, as a trigger operand names it ([Operands](#operands)) |
| `0x04` | u32 | The ship it ends at, or `0xFFFF` in the low halfword for none |
| `0x08` | f32 x3 | Where it starts |
| `0x14` | f32 x3 | Where it ends |
| `0x20` | u32 | The ship its leaving tangent is drawn to |
| `0x24` | u32 | The ship its arriving tangent is drawn from |
| `0x28` | f32 x3 | Its leaving tangent: from where it starts to the first of those ships |
| `0x34` | f32 x3 | Its arriving tangent: from the second of them to where it ends |
| `0x40` | u32 | **Unknown** |

Its ships are points of kind `0x3E4` in the shipped missions, and the record holds their places as
the mission placed them. The engine weighs each tangent ten times as it stands.

## Objects

Ships, flight groups and squads each start with an **object ID**, and events name their subject by
one. Section 7 is indexed by it:

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | Kind: 0 ship, 1 flight group, 2 squad |
| 1 | u8 | Number of triggers in the object's slice |
| 2 | u16 | Index of the first |
| 4 | u32 | **Unknown** |

In all 44 missions every ship's ID is unique within its mission and lands on a kind-0 entry, and the
kind-1 and kind-2 entries correspond one for one to the flight groups and squads. The squad
membership walk behind `in_squad` reads the kind: a flight group member is tested with
`in_flight_group`, and a squad member recursively.

A squad's `+0x08` is the index of its first record in section 13, or `0xFFFF`. A membership record
holds the member's object ID at `+0`, the owning squad's index at `+4`, and at `+8` one of the
member's components by index, or `0xFF` for the whole member. A squad's records are consecutive.
Members may be ships, flight groups, other squads, or single components of a ship, such as a capital
ship's turrets.

## Triggers

Stride `0x30`. A trigger runs a block of script when an event it watches happens to its subject.

| Offset | Field |
|---|---|
| `0x00` | Condition |
| `0x01` | Repeat mode |
| `0x02` | Link: the block to run, as a halfword offset into the script; `0xFFFF` for none |
| `0x14` | Armed, set at mission start for every trigger an object's slice holds |
| `0x15` | Qualifier: the component of the subject watched, by index; `0xFF` for the subject itself |
| `0x16` | Zero runs the block's thread at once, inside the event; otherwise the scheduler does |
| `0x19` | Firings left, for repeat mode 2 |
| `0x1A` | The firings repeat mode 2 has each time the script arms the trigger (`SetTriggerState`), which `0x19` takes again then |
| `0x1C` | Operands, four bytes each, one for each value the condition's events carry: see [Operands](#operands) |

A trigger holds no subject: it sits in its subject's slice of the trigger list, in the
[object table](#objects). When an event happens to an object, `trigger_match` (`0x0045CEA0`) walks
the slice and fires each trigger that is armed, has the event's condition and qualifier, and whose
operands pass. Firing starts a thread at `script + link * 2`, unless a thread the trigger started
is still running. An operand whose low halfword is `0xFFFF` is not checked. The
[VM at run time](../engine/script-vm.md#events) describes the matching in full.

No trigger is in two slices, and a trigger in no slice can never fire. The condition decides which
kinds of object a trigger can belong to, and every trigger agrees with its condition's.

Repeat mode `0` disarms the trigger when it fires, `1` never disarms it, and `2` disarms it when the
counter at `0x19` runs out. A trigger whose operands fail a check stays as it is.

The qualifier must equal the event's. A ship's components, such as a capital ship's turrets and
subsystems, are numbered among the
[components of its live object](../engine/objects.md#components). A hit on one raises ShotAt with
its index and, except for hits of one kind, ShotAt for the ship; destroying one raises Destroyed
with its index. Every other event carries `0xFF`, the subject itself.

An event on a ship is raised on its flight group and on the squads that hold it too. Destroyed on a
flight group or squad goes ahead only once every member, or the member's named component, is
destroyed; until then it fires only the group's triggers with repeat mode 1. For ShotAt the group's
event carries the members' average damage value instead of the ship's. See
[Events](../engine/script-vm.md#events).

### Operands

Operand `n` goes with value `n` of the condition's events, such as the attacker of ShotAt or the
distance of Proximity. The matcher checks an operand against the event's value when the condition
marks the value as checked and the operand's low halfword is not `0xFFFF`. It reads the operand by
the value's kind mask (`trigger_operand_value`, `0x004530A0`):

- A number is taken as it is.
- For a ship value, bit `0x2000` of the low halfword matches any of the players' ships: in a game
  of one, the player's.
- Anything else is a reference to a ship, a flight group or a squad, which the matcher turns into
  the address of its record, the form in which events pass them:

| Bits | Field |
|---|---|
| 0 to 15 | Index into the section the tag selects |
| 16 to 23 | Tag: `0x00` ships, `0x01` flight groups, `0x16` squads |
| 24 to 31 | **Unknown.** Ignored |

Any other tag in a checked operand is a fatal error: the game reports `NULL entity referenced in
script`, or `oh dear dear`, and exits. `sltool dte triggers` lists each trigger's set operands under
their values' labels, naming referenced objects by object ID.

### Conditions

The engine's descriptor table at `0x4F6698` lists 35 conditions, named in the payload as `TT_*`
constants; the last two are internal. A descriptor gives the kinds of object the condition applies
to, the values its events carry, and the handlers that can veto them: see
[Conditions](../engine/script-vm.md#conditions). The table lies just past the VM's dispatch table,
followed by the lists of event values. `make vm-conditions` regenerates
[`src/engine/vm/conditions.zig`](../../src/engine/vm/conditions.zig) from the binary alone.

## Script

Section 6 is the mission's bytecode: `count * 2` bytes. The interpreter is a dispatch loop:

```
handler = table[code[ip]]      // 86 entries at 0x004F6350
ip += 1
continue while handler() != 0
```

### Instruction set

**71 opcodes: `0x02` to `0x07` and `0x14` to `0x55`, less `0x50`.** The other entries of the
86-entry table are null. The condition descriptor table follows it, and its handler pointers look
like further entries.

Five opcodes run the same handler as another and are the same operation: `0x24` and `0x23`, `0x2B`
and `0x2A`, `0x25` and `0x43`, `0x32` and `0x2E`, `0x55` and `0x47`.

Every opcode's size and effect on the instruction pointer is read from its handler. The dispatcher
calls a handler with `ECX` pointing at the cell holding the instruction pointer, already advanced
past the opcode, and execution resumes wherever the handler leaves that cell. `src/tools/tablegen`
reads the dispatch table from the binary, parses each handler from Ghidra's exported disassembly,
and symbolically executes every path through it, tracking that cell. Paths must agree, or it reports
the handler instead of guessing. Its output is
[`src/engine/vm/opcodes.zig`](../../src/engine/vm/opcodes.zig):

```bash
make ghidra-annotate   # define and name the handlers, among the rest
make ghidra-export-game
make vm-opcodes
```

Nothing calls a handler directly, so auto-analysis leaves most of them undefined; `make
ghidra-annotate` defines each one from the committed opcode table.

| Form | Opcodes | Next instruction |
|---|---|---|
| `sequential` | the rest | After the operands |
| `branch` | `0x23`, `0x24`, `0x42` | The operands are a displacement |
| `inline_data` | `0x2A`, `0x2B` | After the run the operand byte measures |
| `transfer` | `0x22`, `0x25`, `0x43`, `0x4A`, `0x51` | Not known statically |

The rest are a fixed size, with up to three operand bytes. Three carry their own length:

- **`0x2A` push_string** (and `0x2B`) takes a length byte that counts itself, pushes a pointer to
  the bytes after it, and steps over them. They are a NUL-terminated string, usually the name of a
  `.wav` of speech or a `.ut` cutscene: `mission81` opens by cueing `new_sim02.wav`.
- **`0x51` random_branch** takes a count, a big-endian default target, then that many four-byte
  arms of big-endian target, threshold and one unidentified byte: `3 + 4n` bytes. It rolls a number
  below 100 and takes the first arm whose threshold exceeds it, or the default. Its targets count
  from the opcode. This is the one encoding read by hand: its length depends on a byte the analysis
  cannot follow.

The analysis also records whether any path leaves the instruction pointer just past the operands.
None does for `0x42` jump, so it never falls through. The transfers are classified by name, and a
compile-time check rejects any transfer in the table without a classification:

| Transfer | Opcodes | Next |
|---|---|---|
| Call | `0x22` call_part, `0x4A` call_part_b | Into a part, then the following instruction |
| Return | `0x43` return, `0x25` | Out of the part, or out of the thread |
| Random branch | `0x51` | One of its arms |

The analysis cannot classify these itself: a call's only sequential path is its missing-part
early-out, and return's path that leaves the pointer alone is the one that ends the thread, which it
signals through its return value.

### Opcodes

A stack machine. Names follow the handlers; `a` is the second value from the top, `b` the top.

| Opcodes | Names | Effect |
|---|---|---|
| `0x02` to `0x07` | `equal`, `not_equal`, `greater`, `greater_equal`, `less`, `less_equal` | Pop `b` and `a`; push the unsigned comparison |
| `0x33` to `0x36` | `greater_f` ... `less_equal_f` | The same through the FPU, with the same results |
| `0x1B` to `0x1E` | `add`, `sub`, `mul`, `div` | Pop `b` and `a`; push the result |
| `0x3B` to `0x3E` | `add_f` ... `div_f` | The same computed in floating point and truncated |
| `0x1F`, `0x20` | `logical_and`, `logical_or` | |
| `0x14`, `0x15` | `in_flight_group`, `not_in_flight_group` | Whether ship `a` is in flight group `b` |
| `0x45`, `0x46` | `in_squad`, `not_in_squad` | Whether object `a` is in squad `b`, following nested squads |
| `0x3F` to `0x41` | `select_array`, `select_global`, `select_argument` | Make slot `n` the store target; push its value |
| `0x16` to `0x1A` | `assign`, `add_assign`, `sub_assign`, `mul_assign`, `div_assign` | Pop the value and the target's old value; store into the target |
| `0x37` to `0x3A` | `add_assign_f` ... `div_assign_f` | The same into a float target |
| `0x26`, `0x27`, `0x30`, `0x31` | `push_array`, `push_global`, `push_local`, `push_argument` | Push slot `n`'s value. A trigger block's locals hold its event's arguments |
| `0x28`, `0x29` | `push_constant`, `push_constant_wide` | Push constant `n` of the running block |
| `0x2A` (`0x2B`) | `push_string` | Push a pointer to inline text and step over it |
| `0x2C`, `0x52` | `push_ship`, `push_ship_wide` | Push a pointer to ship `n` |
| `0x47` (`0x55`) | `push_component` | The same, naming the ship's component given by a second operand |
| `0x2D`, `0x44`, `0x49`, `0x54` | `push_flight_group`, `push_squad`, `push_curve`, `push_section_19` | Push a pointer to record `n` of sections 4, 12, 16 and 19 |
| `0x32` (`0x2E`) | `push_byte` | Push the operand byte |
| `0x2F` | `push_percent` | Push `n` percent of the top value |
| `0x48` | `push_null` | Push `-1`, for parameters labelled "can be NULL" |
| `0x4C` | `push_result` | Push the last command's result |
| `0x4B` | `push_event_value` | Push a value the event matcher stored for an object |
| `0x21`, `0x4F` | `command`, `command_b` | Call an Executor command, popping its arguments |
| `0x22`, `0x4A` | `call_part`, `call_part_b` | Call a part |
| `0x4D`, `0x4E` | `spawn_part`, `spawn_part_b` | Start a part on a new thread and carry on |
| `0x43` (`0x25`) | `return` | Leave the part, or end the thread |
| `0x23` (`0x24`) | `branch_if_zero` | Pop a value; branch if zero |
| `0x42` | `jump` | |
| `0x51` | `random_branch` | |
| `0x53` | `nop` | |

A compile-time check in [`src/formats/dte.zig`](../../src/formats/dte.zig) keeps the names and the
derived table in step.

`push_component` tags the stack slot it fills with the component, in a list at `0x537420` that
empties after every command. A command whose argument can be a component, such as
`DestroySubObject`, `ReplaceSubObject`, `SetPrimaryTarget` or `SetPlayerTarget`, looks its
arguments up there (`vm_argument_component`, `0x0045D950`) to learn which component they name.

### Control flow

- **`call_part`** takes a part index into the runtime part table (stride `0x74`: block pointer at
  `+0`, argument count at `+4`), pushes the argument count, return address, frame base and block
  end, sets the frame base to `stack - (4n + 16)`, and enters the block. **`return`** unwinds that,
  or ends the thread when the call depth is zero.
- **`spawn_part`** moves the part's arguments from this thread's stack to a new thread's, starts the
  new thread on the part, and carries on. At most 32 threads run at once.
- **`call_part_b`** and **`spawn_part_b`** do the same through the second part table, which serves
  section 18; **`command_b`** uses a second command table, which is empty.
- **`branch_if_zero`** and **`jump`** take a **big-endian** displacement, counted from its own
  position. The handler loads it as an unsigned 16-bit number and adds it to the instruction
  pointer (`vm_jump`, `0x0045C2B0`), so a branch only goes forward. The script's other two-byte
  operands, the wide indices of `push_constant_wide` and `push_ship_wide`, are big-endian too;
  the rest of the format is little-endian.

A thread keeps its block's end in `[0x5373F0]`, which is where `push_constant` reads from.

### Commands

`command n` calls entry `n` of the Executor catalogue at `0x4F0F50`, which `vm_install_commands`
(`0x0045CE30`) installs and counts up to the first entry with no implementation: **95 commands**.
An entry is `0x74` bytes and describes itself in the developers' words:

| Offset | Field |
|---|---|
| `0x00` | Implementation |
| `0x04` | Parameter count |
| `0x08` | Name, such as `CreateTimer` |
| `0x0C` | Up to eight parameters of 12 bytes: a kind mask, an unidentified word, a label |
| `0x6C` | Description, such as `Creates a timer to invoke a function` |
| `0x70` | **Unknown.** Set on seven commands |

A parameter's kind mask says what it accepts. The bits are named from the labels that carry them:

| Bit | Accepts |
|---|---|
| `0x80` | A number: an ID, a count, seconds |
| `0x100` | A speech or movie file name |
| `0x200` | Text, or an animation name |
| `0x400` | A ship |
| `0x800` | A flight group or patrol route |
| `0x4000` | A function, meaning a part |
| `0x80000` | A named constant: a pilot, an AI mode, a text ID |
| `0x100000` | **Unknown**; set in entity parameters alongside ship and flight group |
| `0x200000` | A trigger condition |
| `0x400000` | A camera or flight curve |

`make vm-commands` regenerates
[`src/engine/game/executor/commands.zig`](../../src/engine/game/executor/commands.zig) from the
binary alone. Every command call in the 44 missions resolves.

### Parts

Section 8 holds one 28-byte descriptor per **part**, a named routine. The loader expands it into the
256-entry runtime part table.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | Name, as a string pool offset |
| `0x0A` | 2 | Start, in halfwords from the start of the script; `0xFFFF` for none |
| `0x0C` | 1 | Flags; bit 0 runs the part when the mission starts |
| `0x0D` | 1 | Argument count |
| `0x10` | 2 | Extent, in halfwords |
| `0x19` | 1 | Passed by the loader to the routine that fills the runtime entry |

The loader sets `block = script + start * 2`, which fixes the halfword unit. In every mission the
parts are in address order and contiguous, each one's `start + extent` being the next one's `start`,
and the last ends at the end of section 6.

Missions carry their authors' names for them, as in `mission1`:

```
  #  offset  bytes  args  block  name
  0    1740    192     0    168  (F)launchfunction
  1    1932    160     0    144  (F)Jumping to CONVOY
  2    2092    252     0    220  (F)Arrival at CONVOY
  ...
 31    7524     28     0     20  <F>Objective window
```

Nearly every part takes no arguments. Every mission has exactly one start part, with names such as
`<F>Start Launch`, `(F)start` or `(F)setup`: `mission_script_start`, `0x0045CBC0`, runs it before
arming the triggers.

### Blocks

A block is a `u16` length, which **counts its own two bytes**, then instructions: the engine starts
a thread at `block + 2` with its limit at `block + length`. The instructions end with a `return`,
padded with up to three bytes to a four-byte boundary.

### Routines

The script section is a sequence of **routines**, each a block followed by its **constant table**:
dwords that `push_constant n` reads, starting at the block's end. First come the blocks triggers
run, then the parts:

- A part's extent covers its block and its constants.
- A trigger block's constants run to the next routine. In `mission1` the trigger blocks start at
  bytes 0, 36, 72 and so on, and the first part follows the last of them.

In every mission this tiles the section exactly, with one trigger block for each trigger that can
fire and has a link; a trigger that can fire may also have no link and run nothing. Each constant
table is exactly as long as the highest index its block pushes, rounded up to 8 bytes; the filler
dword that rounding adds is not read.

```
sltool dte script <mission>    # every routine, with its constants
```

`sltool dte script` follows control flow from each block's entry rather than sweeping, because
`jump`, `return` and `random_branch` never fall through, and shows the value behind each
`push_constant`, the name of each command, and the part, ship or global an index names. **Every
routine disassembles completely**, except the regions listed under [Open](#open). The first block of
`mission1`, which its first trigger runs, calls one of two parts depending on a global:

```
0 to 36: trigger 0
       2  22 01       call_part   1  (F)Jumping to CONVOY
       4  21 17       command   InterruptTriggerCode
       6  27 00       push_global   0  (GV)convoykilled
       8  28 00       push_constant   = 1
      10  02          equal
      11  24 00 07    branch_if_zero_alt   -> 19 if zero
      14  22 15       call_part   21  (F)GO HOME (Total Loss)
      16  42 00 04    jump   -> 21
      19  22 18       call_part   24  (F)Jumping to Sherman
      21  21 17       command   InterruptTriggerCode
      23  32 01       push_byte   1
      25  43          return
  constants: 1 220332040
```

The links of the triggers no slice holds are never followed, and most of them do not point at a
block.

### Open

- Four 32-byte regions that nothing reaches, two in one part of `mission15` and one each in
  `mission18` and `mission23`. Each follows a random_branch whose two arms split 50/50 and target
  the bytes after the gap: `51 02 00 43` in three cases, `51 02 00 45` in the fourth.
- What the qualifier byte selects.

## Writing

[`dte/write.zig`](../../src/formats/dte/write.zig) writes a mission file laid out as 36 of the
shipped missions are, `mission1` among them: a directory of 128 slots, `0x400` bytes, each section
at the same offset with the same room up to the next, and 850,919 bytes in all. The directory's 28th
slot holds the file's size, and the rest are unused, as in those missions; every entry carries the
flags 15. Section 21 has no room there, starting where section 22 does, so OpenReliant's name goes
after the template's end, which a loose file's buffer of `0xFA000` bytes still holds.

A section's records are its count times its stride: bytes for the string pool, the script flags and
OpenReliant's name, halfwords for the scripts, and the records' sizes for the rest. The strides of
sections 9, 11 and 23, 4, 4 and 2 bytes, are **Unverified**: the engine reads nothing of 9 and 23,
and 11 holds one record in every mission. Section 20's is not known, and no mission uses it.

`sltool dte check <mission>` writes a mission again and checks what comes back. The 36 missions of
the template, written again from their sections' whole rooms, stale bytes and all, come back byte for
byte. Every mission, written again from its records alone, reads back the same records.

A mission of OpenReliant's making holds what the template's missions hold: its section 24 is theirs
(`write.template.command_flags`), and its records carry the values most of theirs carry where their
fields are not known. Mission 0, the sandbox, is written so by the build
([`mission0.zig`](../../src/openreliant/mission0.zig)).

### Writing the script

[`dte/assemble.zig`](../../src/formats/dte/assemble.zig) builds a routine as the shipped scripts
are built: the block's length word, which counts itself, the instructions, and zeros to a four-byte
boundary; then the constant table, each constant once in the order first pushed, and zeros to an
eight-byte boundary. Labels stand for the branches' targets: a branch's displacement counts from its
own position and a `random_branch`'s targets from its opcode, both big-endian, and a branch
backwards is refused, since the engine would take it 64 KiB forward. `push_string`'s length byte
counts itself and the NUL after the text.

Assembled again from its disassembly, every routine of the 44 missions comes back the same, but for
the padding after its last instruction, which in the shipped missions holds stale bytes, and the
three routines with bytes nothing reaches (see [Open](#open)).

## Prior art

The container, directory, record strides and condition list are from [Starlancer-OSS
`docs/dte-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/dte-format.md)
and its scripting reference, which build on Captain Foster's Starlancer ME work. Everything above
was re-checked against the 44 shipped missions and the engine's own code. Where the two differ,
this document follows the code: the trigger's condition is at `0x00` and its subject implicit,
sections 4, 12 and 13 hold flight groups, squads and squad members, a ship's `0x00` is its object
ID, `0x02` tests equality and `0x03` inequality, `0x28` pushes a constant, and `0x32` pushes a byte.
The byte-offset string pool, the object table and everything about the script beyond the dispatch
loop are additions. [StarLancerEditor](https://src.ug.gg/mini/starlancereditor), which reads and
writes missions through YAML, names sections 14 and 15 the ships' formations and their points, which
the engine's formation code bears out, and its writer lays missions out on the same template.
