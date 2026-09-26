# Jumps

Ships come and go by jumps (`jump.cpp`). Jump Out, orders 20 and 41, takes a ship away:
`order_jump_out_init` (`0x00416D50`) readies it, and `order_jump_out` (`0x00416E00`) runs it an
update at a time. Jump In, orders 19 and 40, brings a ship in beside an object: `order_jump_in_init`
(`0x00416540`) and `order_jump_in` (`0x00416570`). [`jump.zig`](../../src/engine/game/jump.zig)
holds the four. They are `jump.cpp`'s by the assertion `order_jump_in` makes with its path
(`0x004165EC`), which [the source map](../binary/sources.md) misses, as it lies in a case of a switch
([#310](https://github.com/vdmkenny/openreliant/issues/310)).

A mission's script gives the jumps with `SetAI`, most often to a flight group or a squad, each ship
numbered in turn among them ([Orders](orders.md#the-stack)): that number places it among the ships
that jump with it. JUMP DRIVE, once the mission has a jump ready, posts PlayerReadyToJump
([Script VM](script-vm.md#events)), whose trigger has the script give the player's wing its Jump
Out. `WaitForJumpOrLaunch` holds a script's thread while a ship it names is on a jump
([Launches](launch.md#how-a-launch-is-given)).

The two orders share a state (`JumpState`):

| Offset | What it holds |
|---|---|
| `+0x04` | The step |
| `+0x08` | The frame's tick the step began, from which the motions count |
| `+0x0C` | Where the ship goes: Jump Out's destination, Jump In's arrival |
| `+0x18` | How it is turned: Jump Out's as it begins to charge, Jump In's its target's |
| `+0x3C` | Where it stood then |
| `+0x50` | The frame's tick of the last update |
| `+0x54` | How far through its step it is, from 0 to past 1 |
| `+0x58` | **Unknown.** The number of lights of its effect, which only the effect reads |
| `+0x5C`, `+0x68` | Where Jump Out's motion takes it from and to |
| `+0x74` | The motion it puts aside while it flies a jump's own |
| `+0x78` | Its effect record ([What a jump shows](#what-a-jump-shows)) |
| `+0x7C` | Whether it jumps out with the player's ship |

Each update adds to the progress at `+0x54` the ticks since the last update times 0.001 times the
step's rate, and holds the ship's Nova Cannon's charge at nothing.

## Jump Out

`order_jump_out_init` lets the ship's throttle go, places it for its jump (below), and sounds
`jumponline` (sound `0x1D`) from it, among the player's own sounds for the player's ship. For the
player's ship the camera switches to view `0x27`, held ([Camera](camera.md#the-jumps-views)). The
ship of a player uncloaks ([Cloak](cloak.md)).

`0x004184F0` places it. Where the player's ship's current order is Jump Out and names the same
target by its index, the ship goes with it, in formation: it collides with nothing, and the target,
or 100000 ahead of the player's ship where the order names nothing or the player's ship, is where
it goes. It is turned to face it from the player's ship, and stands in row `r` of the formation, `r`
times 3000 behind the player's ship, which holds `r` ships abreast, 6000 apart and centred on the
player's line; the order's number counts through the rows from the first, which holds one ship, up
to nine rows. It is stopped, and set flying 150 ahead, its throttle what that is of its cruise speed.
The player's ship takes its place so too, by its own number: the first, 3000 back from where it
was. Each object
the ship's way crosses within 500000 ahead of it (`segment_meets_box`), but those on the same jump,
stand-ins and disabled and jumping ones, is marked jumping (`0x00418470`): so is every fuel pod
(type `0xE1`), and every ship launching from the object or docking with it, and those in turn. A
jumping object stays where it is, and the frame passes it over until the player's jump ends.

A ship that does not go with the player's goes to its target, where it stood last update, or 1e7
ahead of itself where the order names nothing or the ship itself.

`order_jump_out` runs a step at a time. Every update of the player's ship clears the jump the
mission has ready (`jump_ready`, `0x0052A3F0`).

| Step | What it does |
|---|---|
| 0 | It steers to face where it goes (`ai_steer`, at most 0.8 of each turn, with no ease), until its rates of turn are within 0.05 and its steering inputs within 0.02; a ship of the player's wing goes on after 1000 ticks whatever. A ship in the player's formation holds its place 100 ticks instead. Then it sounds `jumpout` (sound `0x19`) |
| 1 | It is held still: its steering inputs, its rates of turn, its turn and its speed nothing (the speed's figure alone: its velocity carries it on, slowing as its throttle has gone). The frame after, its effect begins, which keeps how it is turned and where it stands, and aims its motion 500000 along the way to where it goes |
| 2 | It charges at 6 |
| 3 | At full charge it goes: its motion is put aside for Jump Out's, it collides with nothing and draws at its finest (`0x00417DC0`), and its motion starts from where it stands. It fades at 4 for 250 ticks |
| 4 | It flies ahead again, jumping, while its flare fades at 10; then it collides again |
| 5 | It is turned back as it was, powered and free to move, and flies its own motion again at its usual detail. The player's jump ends every object's jumping. An order that names another object gives way to Jump In at it, 19 for 20 and 40 for 41, at the same number; one that names nothing leaves the mission: the ship stops jumping, is disabled, but for a player's ship in a multiplayer game's way (object flag `0x10000000`), and is put 9.9e6 below where it went, its order done |

In step 1 the Boridin's breakaway (`boridin_breakaway`) lets go of the sprite of its core.

While the player's ship jumps out, `order_jump_out` counts `0x0051D0B4` down from 15 every 10 game
ticks (`0x0051CFA0`), which nothing reads; `order_jump_out_init` sets it, with 1/15 at
`0x0051D0A4`.

## Jump In

`order_jump_in_init` has the ship collide with nothing and jump, and places it (`0x00418850`):
abreast of its target, turned as the target is, where the target is drawn, the order's number `n`
putting it `(n + 1) / 2` times 3000 to the target's right for even `n` and to its left for odd: the
first at the target, the second to its left, the third to its right, and so on.

| Step | What it does |
|---|---|
| 0 | It is turned as its target is, set where it arrives, stopped, and moved back from there along its nose by 25000, or 100000 for a ship that lists components, to fly in from. It sounds `jumpin` (sound `0x1A`). For the player's ship, the camera switches to one of three views, held, picked from the C runtime's `rand`: twice its share of 32767, rounded, 0 for view `0x17`, 1 for `0x18` and 2 for `0x19` ([Camera](camera.md#the-jumps-views)); the mission's space takes on what its script asked of it (`environment_update`); and `0x005E82F0` is set, which cuts the space dust's streaks shorter ([Backdrop](backdrop.md#dust)) |
| 1 | It flashes in at 50. Then its motion is put aside for Jump In's, and it no longer jumps |
| 2 | It flies in at 3, the player's camera shaking by 1 less the progress (`hit_shake`). Then it flies its own motion again at full throttle, colliding, powered and free to move, and `0x005E82F0` is cleared |
| 3 | Its order ends: for the player's ship the camera goes back to view 0, free, the display's brightness to 1, its effect record is let go, and JumpedIn is posted (`event_jumped_in`, `0x0045B300`), with the groups ([Script VM](script-vm.md#events)). Order 40 first holds 200 ticks, its roll input `s * (n + 1) / 2` times 0.5 and its pitch input `(n + 1) / 2` times 0.5, with `s` 1 for even `n` and -1 for odd |

In a multiplayer game, as the ship of the first player still flying jumps in, JumpedIn is posted
for the first player's ship too, before its own.

## The motions

Each takes the order's state ([Objects](objects.md#the-orders-motion-functions)):

- Jump Out's (`motion_jump_out`, `0x00474640`) moves the ship to the point between where its motion
  starts and where it goes, `+0x5C` and `+0x68`, by the square of the share of 250 ticks since it
  went: 0.004 for each of the mission's ticks. It does not turn, and its last throttle is nothing.
- Jump In's (`motion_jump_in`, `0x004746D0`) flies the ship along its nose at 600, or 2400 for one
  that lists components, less 0.003 of that for each tick since it was placed, and at its cruise
  speed at least. It does not turn, and its last throttle is nothing.

## What a jump shows

**Unknown**, and not ported ([#309](https://github.com/vdmkenny/openreliant/issues/309)): what each
jump shows, from its effect record, `0x94` bytes, which one of the 64 pointers at `0x0051CFA4` holds;
Jump In stops the game with "Jump has overrun array" when all are taken. `0x00416490`, as a mission loads, makes the
flare's mesh (`0x0051D0A8`) and loads the trails' texture (`0x0051D0AC`), and clears the flags at
`0x005E82F0` and `0x0051D0B0`; `0x00416510` frees the mesh as it ends. `0x00417670` begins Jump
Out's effect: a burst's mesh behind the ship, a trail at each of its attachments of kind 7, five at
most, and a light at each of kind 8, twenty at most. `0x00417AF0` makes a trail's mesh,
`0x00417E30` a burst's, `0x00418120` the flare, `0x00418150` and `0x004181C0` fade and light the
burst, and `0x00418390` stretches the trails.
