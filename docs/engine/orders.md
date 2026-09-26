# Orders

What each object is doing: flying in formation, escorting, docking, exploding, or following the player's controls. An object keeps a stack of orders, the current one on top, which the AI, the mission scripts and the player's controls push and pop, and `object_orders` runs the current one.

[`aigeneric.zig`](../../src/engine/game/aigeneric.zig) holds the stack and runs the orders, [`ai.zig`](../../src/engine/game/ai.zig) the steering they turn by, [`aiorders.zig`](../../src/engine/game/aiorders.zig) the orders that fly a ship, [`aieject.zig`](../../src/engine/game/aieject.zig) and [`tractor.zig`](../../src/engine/game/tractor.zig) those of the [ejection](ejection.md), and [`ai/orders.zig`](../../src/engine/game/ai/orders.zig) lists every order with its flags, priorities and routines; `make order-tables` transcribes that table from the executable. The names below are those `make ghidra-annotate` gives the Ghidra project, which names each order's routines `order_` and the order's name, with `_init` and `_exit` for those two.

Ported so far: the stack (`order_push`, `order_pop`, `orders_clear`, `orders_pop_all`), what runs it (`object_orders`, `orders_update`, `order_retaliate`), the steering (`ai_steer`, `ai_roll_upright`) with its avoidance, and the orders Do Nothing, Fly, Run Away, Slow Rotate, the Random Spins, Match Speed, 44 and 45, Explode, the ejection's (Eject, 106, Scoop Up, Eject Spin, Eject Fighter Attack and Eject Player) and Fight with its [combat maneuvers](maneuvers.md), with Player Control being the player's [controls](controls.md). An order OpenReliant does not run yet still holds its place on the stack, and pushing it still pops and starts what it should ([#30](https://github.com/vdmkenny/openreliant/issues/30)). Not ported: the orders other players' machines queue ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

OpenReliant keeps each object's stack and order state in its slot rather than allocating them with its first order, and hands a fatal "Cannot set ai" back to its caller as an error.

## The order table

`order_groups` (`0x4E06E0`) points at the records of each hundred order numbers: order `n` is
record `n % 100` of group `n / 100`. Group 0 holds orders 0 to 45, group 1 orders 100 to 122, and
group 2 one empty record, order 200. Each record is an `OrderRecord`:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | `init`: runs before the order's first update; null for none |
| `0x04` | 4 | `update`: runs each time `object_orders` runs the order |
| `0x08` | 4 | `exit`: runs when the order is popped or replaced after it has started; null for none |
| `0x0C` | 4 | Flags |
| `0x10` | 4 | Name: the developers' name, which fatal errors show |
| `0x14` | 4 | Priority |

| Flag | Name | Meaning |
|---|---|---|
| `0x1` | `players` | The order may be given to a player's ship. A player's ship refuses the other orders numbered below 100. |
| `0x2` to `0x10` | | **Unknown.** Set on some orders; nothing in the payload tests them. |
| `0x20` | `one_shot` | The order runs its update once and pops itself, and the order below carries on without starting again. Its `init` never runs. |
| `0x40` | `retaliate` | While it runs, the ship can turn on its attacker (see [Retaliation](#retaliation)). |
| `0x80` | `avoidance` | While it runs, `avoidance_scan` (`0x00492190`) lists the objects the ship could hit, unless the object has `no_avoidance`, which `SetShipAvoidance` sets to disable "Avoidance code": up to ten objects with listed components whose collision spheres, widened by a constant, overlap its own, at `GameObject` offsets `0x6B4` (the count) and `0x6B8`, and up to ten others for which `0x00401980`, which projects the two objects' motion, answers yes for a time of 50 updates and a margin of 2000 units, at `0x6E0` and `0x6E4`. |
| `0x400` | `send_flight` | While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and velocity. |

Most orders have priority 0. Warp In, Warp Out, Land, Jump In, Jump Out, the fixed gate jumps,
Launch, Dock and Friendly Fire have 1; Eject Player 97, Eject and Eject Spin 98, and Explode 99.

## The stack

An object's stack, `orders` (`0x684`), holds up to 20 `OrderEntry` records, the current order
first, with `order_count` (`0x680`) saying how many. It is allocated with the object's first order,
together with 0x90 bytes at `order_state` (`0x68C`) where the current order keeps whatever it
needs between updates.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | The order's number |
| `0x02` | 2 | Target kind: 0 a ship, 1 a flight group, 2 a squad, as in the mission's [object table](../formats/dte.md) |
| `0x04` | 2 | Target: the ship's slot, or the flight group's or squad's index; -1 for none |
| `0x06` | 2 | Target component, or -1 for the whole ship |
| `0x08` | 2 | A running count from `0x5185A8` while the byte at `0x5185B1` is set, as `SetAI` and `SetupLaunch` number the orders they give, otherwise zero |
| `0x0A` | 16 | The order's own data, zero when the order is pushed |

`player_controls` keeps the mouse's stick position in the first two words of its data.

`order_push` (`0x0040CC10`) takes a slot, an order and its target, and:

1. fails if the ship refuses the order (`order_refused`, `0x0040CA00`): the ship is a player's,
   its slot being below `player_slots` (`0x58832C`), which is 1 in a single-player game and the
   player count or 8 in multiplayer, and the order is numbered below 100 without `players`;
2. succeeds at once if the current order is the same order with the same target;
3. fails unless the current order gives way (`order_give_way`, `0x0040CA50`);
4. removes any equal order, with the same target, from deeper in the stack;
5. fails if the stack holds 20 orders;
6. pushes the order with its data zeroed. Unless the order is one-shot, it marks the order as
   starting (`order_starting`, `0x688`), sets the word at `0x620` to -1 and zeroes the state.

An object that is exploding, whose pilot has ejected, or with object flag `0x10000000` takes no
order. Otherwise the current order gives way at once when there is none, when it has yet to
start, or when the new order is one-shot. A started order gives way to Explode, and to any order
when its own priority is zero or the new order's is higher, running its `exit` as it does. Pushing
any other order on it is a fatal error, "Cannot set ai %s on ship %s: Still %s".

`order_pop` (`0x0040CE70`) runs the current order's `exit` if it has started and removes it. Unless
the popped order was one-shot, the order below starts again: it is marked as starting and the state
is zeroed. `orders_pop_all` (`0x0040CF80`) pops every order, and `orders_clear` (`0x0040CF50`) drops
them all at once when the current order gives way to clearing, so only that order's `exit` runs.

The script command `SetAI` pushes an order aimed at the ship, flight group or squad it names, on
each ship it applies to, and `ClearAI` clears the orders of each ship that is not a player's.

### Targets that name several ships

`order_target_walk` (`0x00401CB0`) hands each ship an order's target names to a routine, until the
routine says to stop: the ship itself, as the target names it; each ship of a flight group, whole;
and each ship of a squad (`squad_walk`, `0x00401D80`): its members in turn from its first, while
they are its own, a ship as the member names its component, a flight group's ships whole, and a
squad's own walk. Dock, Escort, the search for a new target, the search for a pod to scoop up, the
Dark Reign's guns and [Launch](launch.md#the-order) walk their targets so. **Fix:** the game walks a
squad that holds itself round for ever, takes a member no record stands for as the ship at address
zero, and stops with a fatal error at a member of a kind it does not know; OpenReliant stops once
the walk has gone down more squads than the mission has, and passes over the member.

## Running orders

`object_orders` (`0x0040C5F0`) runs an object's current order:

1. It starts the queued orders from other players that are due (see [below](#orders-from-other-players)).
2. With a `retaliate` order, it runs `order_retaliate`.
3. It clears the object's `afterburner` and `reverse_thrust`, so an order that burns sets them
   again each time it runs.
4. A one-shot order runs its update and pops itself, and `object_orders` then runs the order below.
   Any other order runs its `init` first if it is starting, then its update.
5. Afterwards it clears the throttle and both burns while the object's engines are disabled
   (`DisableEngines`), both burns when it has no afterburner fuel, and reverse thrust unless the
   object has `can_reverse`.

It runs from two places:

- `orders_update` (`0x0040C8F0`) runs `object_orders` once a frame for every object that is not
  disabled (`DisableObject`), the player's ship included, and after it, where the object's guns
  are not disabled, its [turrets](guns.md#each-frame) (`object_step_turrets`).
  `mission_frame` (`0x004924B0`), `mission_run`'s work for each frame, calls it (see
  [the game loop](loop.md)).
- `simulation_step` runs it for the player's ship, before the objects move, while the ship's
  current order is `Player Control`.

So the orders of AI ships run once a frame, and the player's [controls](controls.md) once a frame
and once each simulation step.

## Retaliation

Damage of kinds 0, 1 and 5 adds to an object's `recent_damage` (`0x690`), which `orders_update`
zeroes every 500 ticks, and each hit records the attacker's slot in `last_attacker` (`0x694`).
While the current order has `retaliate`, `order_retaliate` (`0x0040C520`) pushes Fight (105),
aimed at the attacker, once `recent_damage` reaches 4.2 times the ship's armor class. It does so
only when the attacker is on the other side, is not already the current order's target, and both
ships' combat stats hold 1 at `+0x28`, and not while the ship has `do_not_disturb`
(`DoNotDisturb`).
**Unknown:** what the word at `+0x28` of the combat stats means.

## Orders from other players

In a multiplayer game, orders from the other machines wait in a queue of up to 20, `queued_orders`
(`0xB90`) with `queued_order_count` (`0xB8C`). A `QueuedOrder` is the order's entry, a value the
sender passes, and the tick it is due. `order_queue` (`0x00402660`) adds one due a given number of
ticks after `frame_start` (see [the game loop](loop.md#ticks)). An equal order already queued stays
if it is due no sooner, and is replaced otherwise; a full queue is a fatal error.

`object_orders` takes each queued order that is due by `mission_ticks` and has a priority no lower
than the current order's, pushes it with its data, and removes it from the queue. It removes a due
order without pushing it while the object has not been created.

## Steering

Most orders that fly a ship steer with `ai_steer` (`0x00401380`), which takes a point to aim at,
a limit, an ease and flags. It sets the pitch, yaw and roll inputs from the point's direction in
the ship's frame, through `0x00401710`, or `0x00401690` when the word at `+0x24` of the ship's
flight stats is nonzero. It takes `(1 - ease) * 6` times each turn rate off its input and
multiplies the result by 11.46, which is a fifth of a degree's worth of radians, so an input fills
at five degrees off; then it holds each input within the limit, at most 1. While frames take more
than 10 ticks, turns of less than an eighth of a turn are halved first, along with the limit.

`0x00401710` banks the ship round: within 18 degrees of the nose it simply yaws at the point,
further off it rolls to bring the point overhead, and it pitches only once the roll is within 0.8
radians of where it wants it. A ship flying backwards turns toward the other way about.

| Flag | Meaning |
|---|---|
| `0x1` | First `avoid_near` (`0x004028F0`) moves the point around the objects with components in the ship's first avoidance list. |
| `0x2` | First `avoid_ahead` (`0x00402DC0`) moves the point around the objects in the second list, projected along their motion. |
| `0x4` | Unless avoidance took over, the ship also rolls toward the world's Y axis (`ai_roll_upright`). |
| `0x8` | Pitch stays at 0.2 or more. |

When avoidance moves the point, `ai_steer` steers with a limit of 1, no ease and without flag
`0x8`, and returns true. The lists are what [`avoidance_scan`](#avoidance) builds, and a ship with
`no_avoidance` avoids nothing.

### Avoidance

`avoidance_scan` (`0x00492190`) runs for each object in `mission_frame`'s pass that draws them, the
ones it draws, while the object's current order has the `avoidance` flag and it has no
`no_avoidance`. It empties the ship's two lists (`GameObject + 0x6B4` and `+0x6E0`, a count and ten
slots each) and fills them from the objects that are not standing in, disabled or jumping, not
planets, not the ship itself or what it fights, and where neither names the other in its first
pass-through slot:

- an object that lists components goes on the first list while its sphere, 10000 wider than the two
  radii, overlaps the ship's where the step takes them both;
- any other goes on the second, where the ship lists no components, while the ship is on course to
  hit it within 50 steps by 2000 (`ai_collision_course`, `0x00401980`).

`avoid_near` (`0x004028F0`) works the first list, from the line between where the ship goes next
and the point it steers at. For each object not standing in, exploding or disabled, not farther
behind along that line than both radii, closing along it, and to be met within 250 steps: it
takes the object's box where it will then be, widened by the ship's radius, in the object's frame
and scaled by its visibility. Where the line crosses it, the point moves onto the box widened again
by the ship's radius: onto the face nearest where the line enters, at whichever is nearest the point
of four spots of it, each at the entry along one of the face's two axes and at an edge of the box
along the other. The point is scaled by the visibility again on its way back to the world, rather
than unscaled. The heading stays the one to the first point, but each object after the first tests
the line to the point the one before moved.

`avoid_ahead` (`0x00402DC0`), for a ship that lists no components, works the second list: each
object is taken where it will be once the ship has flown to where it is now at the ship's cruise
speed. Where the line to the point passes within 1000 of it, or 500 for an object of another side,
the point moves as far ahead of the ship as the object will be, and above or below the ship, away
from the object along the ship's own up and down axis, by both radii and 2000, or 1000 for another
side's.

## The orders

Each order's routines are named after it: `order_fly_init` and `order_fly` for Fly, for example.
Many take their target's validity from `order_target_valid` (`0x00401870`): a targetable object
that is not cloaked, exploding, disabled or ejected, nor has object flag `0x10000000`, and, when the
target is a component, one that is there and neither hidden nor has node flag `0x10`. Random
choices come from `object_random` (`0x004ADD10`), each object's own generator: a seed at `+0x638`,
set from C's `rand()` when the object is created, that steps as `seed * 0x343FD + 0x269EC3`, bits
16 to 30 of it over 32767 giving a number from 0 to 1.

| Order | What it does |
|---|---|
| Do Nothing (0) | Zeroes the throttle and the turning inputs. |
| Explode (11) | A destroyed object's end, by what it is and in one of three styles ([Destruction](objects.md#destruction)). |
| Launch Missile (2) | One-shot: launches a missile at the target from the first of the ship's racks with missiles left that is not a Jack Hammer's ([Missiles](missiles.md#the-ais-missiles)). |
| 3, nameless | One-shot: as Launch Missile, from the first rack of Jack Hammers. |
| Fly (6) | Flies at the speed in its data, or at full throttle for zero. With a target it flies to it and pops within 2000 units; otherwise it keeps the heading it had when it started, steering at a point 20000 units along it. It steers with flags `0x7` and halves the throttle while avoiding. An object without flight stats is moved along that heading instead. |
| Run Away (7) | Flies away from the target at half throttle, steering with flags `0x3`. Pops when the target's slot holds a stand-in. |
| Toggle Cloak (16) | One-shot: cloaks or uncloaks the ship if its model's header allows a cloak, and the ships being launched from it do the same. |
| Slow Rotate (18) | Zero throttle, yaw input 0.1. |
| Random Spin Slow, Medium, Fast (22 to 24) | On starting, zero throttle and each turning input 0.1 plus a random number times 0.3, 0.5 or 0.9. Its update does nothing. |
| Match Speed (32) | Sets the throttle to the target's speed over the ship's cruise speed. Pops when the target is no longer valid. |
| Turns object lights on (35) | Switches on the lights of the parts with the lightmap flag, with a sound, and pops. Ship type 165 instead switches on the first part's four lights one by one, then those of every lightmap part, a step each 100 ticks with a sound at each, and pops after 500 ticks. While the setting at `0x5D5618` is not 1 it pops at once. |
| Turns object lights off (42) | Switches them off. |
| Huuuuuuuge explosion (43) | The Uber Explode at the object, of size 50000 over 1500 ticks ([Effects](effects.md#the-uber-explode)), then it pops. |
| Immediately set ship to zero velocity and rotation (44) | `object_stop` (`0x00403000`), then it pops. |
| Fly ship backwards (45) | Throttle -0.5, no turning. |
| Multiplayer Control (101) | Disables the object once it has object flag `0x10000000`. |
| Fight (105) | Fights its target by running [combat maneuvers](maneuvers.md), one after another. |
| Launch (104) | The ship leaves its carrier, in the style the carrier's type picks ([Launches](launch.md)). |
| Disrupted (114) | A Havoc's shockwave gives it ([Effects](effects.md#shockwaves)). On starting, sets object flag `0x8` (unpowered), keeps the tick to end at, the duration in its data (a word) after `frame_start`, takes the push in its data after that (three floats) as a knock in the ship's own frame, though the shockwave gives it in the world's, and knocks each turn rate by up to 0.05 either way at random, which the ship tumbles by. It also plays fifteen [electric rays](effects.md#electric-rays) over the ship, each from its centre out to its radius in a random direction, 90 either way, with a jitter of 0.6, flickering, dimming as they go dark, and lasting as long as the order, white (0.8, 0.8, 1) and blue (0.3, 0.5, 1) in turn. It pops past that tick, and its `exit` clears the flag. |
| Eject (30) | The pilot leaves the ship in its cockpit, which becomes the pod, and the rest of the ship a new object; the pod clears the ship, and the player's waits to be picked up ([Ejection](ejection.md#the-pod)). |
| Eject (106) | The ship a pilot has left: destroyed 200 ticks on. |
| Scoop Up (107) | A nanny ship or the Antanov takes the player's pod aboard with its tractor beams ([Ejection](ejection.md#scoop-up)). |
| Eject Spin (108) | An AI pilot's ship spins, unpowered, for 200 ticks; then the pilot ejects (Eject). |
| Eject fighter attack (113) | A Sabre flies at the player's pod and shoots it down ([Ejection](ejection.md#eject-fighter-attack)). |
| Eject Player (118) | The player's ship drifts, unpowered, for 400 to 599 ticks, then explodes, unless the pilot ejects first ([Destruction](objects.md#destruction), [Ejection](ejection.md#ejecting)). |

**Unknown:** what the other orders do.
