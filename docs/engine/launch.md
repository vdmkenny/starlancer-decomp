# Launches

A ship leaves the ship it launches from, its carrier, under order 104, Launch (`launch.cpp`):
`order_launch_init` (`0x00418EB0`) readies it, and `order_launch` (`0x004191C0`) runs it an update
at a time. The carrier's type picks how the launch goes, its style. OpenReliant runs the Reliant's
style and the torpedoes'; [`launch.zig`](../../src/engine/game/launch.zig) holds the order,
[`launch/reliant.zig`](../../src/engine/game/launch/reliant.zig) and
[`launch/torpedo.zig`](../../src/engine/game/launch/torpedo.zig) the two styles.

## How a launch is given

A mission's ship record that names a gate (`launch_gate`, [DTE](../formats/dte.md)) launches from
the first of the mission's ships of the kind it names (`launch_from`): as the ship is made
(`mission_ship_create`), it takes a Launch order aimed at that ship through the gate, which starts at
once ([Missions](missions.md#the-ships)). Every campaign mission launches the player's wing so, from
the Reliant or the Yamato, and the Badanov too in missions 27 and 271. A mission's script gives a
launch with `SetupLaunch` (command `0x13`): each ship its first argument names takes a Launch aimed
at what the second names. A ship there goes through the gate the third gives, one on for each ship
the command reached before it; a flight group or a squad is searched for a gate (below), each order
numbered in turn as it is given ([Orders](orders.md#the-stack)).

A launch waits until `StartLaunch` (command `0x14`) starts it: `launch_start` (`0x00418DB0`) sets
the first byte of the data of the first Launch among the ship's orders. In mission 25 the player's
Kamov starts the launch of a torpedo waiting in its tubes with LAUNCH MISSILE
(`player_launch_missile`, `0x00412820`), and a multiplayer game's packets start launches too.
`WaitForJumpOrLaunch` (command `0x3A`) holds its thread while any
ship it names, one the AI's searches reach, is on a jump, a warp or a launch: Jump In and Jump Out
under both their numbers, Warp In, Warp Out, Fixed Gate Jump In and Out, and Launch. The command
then runs again with the push of its argument before it.

## The order

`order_launch_init`:

1. Where the order is aimed at a flight group or a squad, or at a ship with no gate, the search for a
   gate walks the ships the target names (`order_target_walk`, `0x00401CB0`, and `squad_walk`,
   `0x00401D80`, [Orders](orders.md#targets-that-name-several-ships)) with `launch_find_gate`
   (`0x00418DF0`): each ship it reaches becomes the carrier, its gate counted from 0 again, and each
   of its [launch points](#launch-points) takes one off the order's number, which counts on from
   ship to ship. The point that takes it below 0 is the gate. The carrier's slot and the gate go
   into the order's target, whose kind stays as it was: from then on the launch takes the target's
   index for the carrier's slot.
2. The style follows from the ship's type and its carrier's:

   | Style | Of | Routines |
   |---|---|---|
   | 0 | A ship from the Victorious, the Endeavour, the Mitchell (`0x13`, `0xA0`), the Bremen, the Ramases (`0x34`, `0x9C`), the Pukov, the Kronstadt, the Krasnaya, the Varyag or the Kiev, and from the rogue base's seventh gate on | `0x0041A610`, `0x0041A9C0` |
   | 1 | A ship from the Yamato | `0x004192C0`, `0x00419840` |
   | 2 | A ship from the Badanov or the Krasny | `0x00419F60`, `0x0041A100` |
   | 3 | A torpedo (`0x4A`, `0x5C`), from anything | `launch_torpedo_init` (`0x0041A360`), `launch_torpedo_run` (`0x0041A390`) |
   | 4 | An escape pod (`0x4D`) | `0x0041A4B0`, `0x0041A4D0` |
   | 5 | A ship from the Stork | `0x0041A4B0`, `0x0041AD10` |
   | 6 | A ship from the Reliant | `launch_reliant_init` (`0x0041AE20`), `launch_reliant_run` (`0x0041B240`) |
   | 7 | The other escape pod (`0x90`) | `0x0041A4B0`, `0x0041B690` |
   | 8 | A ship from the rogue base's first six gates | `0x0041B770`, `0x0041B7F0` |
   | 9 | A ship from the Zakov | `0x0041B8B0`, `0x0041B940` |

   The table of the styles' routines is at `0x004E3C98`, 24 bytes a style. From any other carrier,
   the game stops with the assertion "Error: Trying to launch from %s".
3. The style's first routine places the ship and names the node it rides: its carrier's root, or the
   part of a model that holds a launch point.
4. The ship rides the node: the order keeps where it stands in the node's frame and how it is turned
   there, it passes through its carrier (its first pass-through slot), and it cannot be targeted.

`order_launch`, before the style's own steps: a carrier gone, a stand-in or exploding, ends the ship
with it (`object_destroyed_net`), save an escape pod leaving the Ulysses as it is lost. Once
`StartLaunch` has it go, the launch waits a moment, up to 200 ticks, drawn from the ship's own
numbers (`object_random15`), and then the style runs it from step 2. As the player's launch goes,
the radio has its line (`0x00456E50`).

Each frame, `mission_frame`'s pass over the objects places a ship that rides its node (`0x00492C14`),
where its current order is Launch and its carrier is not exploding: it stands on the node where its
launch put it, turned as it was there.

The order's state (`LaunchState`): the style at `+0x00`, the tick after which the next step runs at
`+0x04`, the step at `+0x08`, where the ship stands in the node's frame at `+0x0C` and how it is
turned there at `+0x18`, whether it rides the node at `+0x3C`, the node's address at `+0x40`, the
order's number the search counts down at `+0x44`, and the carrier and the gate the search found at
`+0x48` and `+0x4C`.

## Launch points

A launch point is a model's attachment of kind 8 ([SHP](../formats/shp.md#attachment-point-tag-0x09)),
or of kind 5, a pod's, where the pod table holds no model for the place of the part that holds it.
**Quirk:** the game looks the pod table up by the part's place rather than by the attachment's id,
which names the pod it mounts. The points are counted part by part as the root's child list holds
them, each part's attachments in order.

`launch_attach` (`0x0041B9F0`) places a ship at the point of an object that its order's target names
by its component: the ship's centre of mass stands at the point, and it is turned as the point is.
The part that holds the point becomes the node the ship rides. The torpedoes' style, the escape
pods', the Stork's, the Zakov's, and the Reliant's for the player's ship place their ships so.

## The Reliant's launch

The Reliant has six tubes, each between a door below and a door above: parts `gate` and `gate + 6` of
its root's child list. `launch_reliant_init` stands the ship halfway between the middles of the two
doors, each the middle of the bounds of the level its part last drew, moved 400 across in the door's
frame (`0x004DC5A8`), to the right for a gate of even number and to the left for an odd, and turns
it as the Reliant turns next. The ship rides the Reliant's root, its steering and its throttle
nothing.

For the player's ship, the Reliant becomes the ship the player launched from (`0x0057E05C`). The
hangar (`reliant_hang.shp`, type `0xD6`) is made in the cutaway slot, colliding with nothing, its
hull and its two doors reached by no light of the backdrop's but the first ambient (light mask
`0x3B`), so that their baked colours and their own lights light them. The hangar has two launch
points on its retainer, turned half a turn from each other: the ship stands at the first for a gate
of odd number, and at the second, the hangar turned half a turn with it, for an even. The hangar is
laid over the tube: the ship is placed at the point with the hangar at the origin, the hangar moves
by the way from there to the tube, and the ship is placed at the point again, riding the retainer.
The camera takes view 0 in the cockpit mode, held there, and the scene shows the launch's cutaway,
which leaves the Reliant out (`mission_showing`, `0x00587CD4`, set to 2).

`launch_reliant_run` runs a step each time the wait the last set has passed:

| Step | What it does | Wait |
|---|---|---|
| 2 | For the player's ship: the engine starts sounding, with a shake of 0.1; a cutaway is picked from the C runtime's `rand`, one of three, the bay's view taking the camera at once; the tube's upper door shows | 100 |
| 3 | For the player's ship: the hangar's retainer lowers it, playing its `deploy` track at speed 2, with standard sample 6 | 250 |
| 4 | For the player's ship: the retainer rises again, its track backwards. The ship rides its node no more | 50 |
| 5 | The tube's lower door opens (`opendoor` at speed 2). For the player's ship: the cutaway shows, the hangar's lower door opens (speed 4), with standard sample 5; with the aside cutaway, the camera takes that view and the hangar goes | 150 |
| 6 | The ship drops (`motion_downward`), at full throttle. For the player's ship, the mission's date is typed out on the display | 50 |
| 7 | For the player's ship, out of the bay's view: the cutaway ends and the hangar goes; with the cutaway from below, the camera takes that view | 150 |
| 8 | The ship drops on | 300 |
| 9 | The ship flies ahead again (`motion_forward`), steering nothing, at no throttle | 200, none for the player's |
| 10 | For the player's ship: the date goes, the cockpit mode becomes the one the options' setting picks, the camera leaves a launch view for view 0, no longer held, and the hangar goes. The ship stops passing through the Reliant, its order pops, it can be targeted, and its Launched event is queued | |

`motion_downward` (`0x004744E0`) is the plain flight model along the ship's Y axis, which points
below it ([Objects](objects.md#motion)): every fighter drops by the first ship type's flight model,
the Predator's, so that each leaves its carrier alike.

### The cutaways

Three views watch the player's ship go ([Camera](camera.md#the-views)):

- **The bay** (view `0x20`), picked at step 2: from within the bay, 750 to the ship's side of its
  gate, 600 above it and 300 behind, projected wide over the whole screen, looking 54 degrees down
  from the ship's nose, and tilting further down by 0.0007 radians a tick once the lower door opens.
  The hangar shows until the launch ends.
- **From below** (view `0x21`), from step 7: 600 to the right of the ship, 10000 below it and 100
  ahead, looking at it as it goes.
- **Aside** (view `0x22`), from step 5: 1700 to the left of the ship and 6000 below it, looking at
  it as it goes, the whole scene shown, the Reliant among it.

With the second and the third, the camera stays in the cockpit until its view takes it.

### The date

From step 6 to step 10 of the player's launch, the display types out the date of the mission being
flown, its language string one of a table of the dates of missions 1 to 28 (`0x005023D6`): at the
foot of the screen, 50 from the left and 30 up, a letter more each time 8 of the game's ticks have
passed, with a cursor after it until the whole date shows ([Display](hud.md#the-launchs-date)).

## The torpedoes

A torpedo's launch (`launch_torpedo_init`) places it at the launch point of its carrier its gate
names, colliding with nothing. At step 2 (`launch_torpedo_run`) it lets go of its tube, heard (3D
sound `0x18`), and boosts away along its nose at throttle 2 (`motion_plain`), steering nothing, from
its carrier's velocity, trailing smoke as a torpedo does. After 200 ticks it flies itself again, its
order pops, it can be targeted and collides again, and its Launched event is queued; it still
passes through the ship that launched it.

## In OpenReliant

OpenReliant keeps the node a ship rides as its object and its part (`create.Slot.riding`), where
the game keeps the node's address.

**Fix:** a carrier no ship launches from, which the game stops for, is taken as one whose style is
not ported. A Launch aimed at nothing, which the game reads from before its objects with the
assertion "Launch Crash Imminent", lets the ship go at once. A style that names no node, and a
Reliant whose model lacks a tube's door, leave the ship where it stands.

**Improvement:** OpenReliant's shadows leave out a mesh that keeps the sun out by its light mask, so
the hangar's walls cast none over the ship, which shows lit within them as in the original
([Renderer](../port/renderer.md#improvements)).

Not ported:

- The other styles ([#304](https://github.com/vdmkenny/openreliant/issues/304)). A ship that
  launches in one rides its carrier's root while it waits, as every launching ship does, and is let
  go where it stands as its style's steps would begin, passing through its carrier no more.
- The Kamov's LAUNCH MISSILE, which starts its torpedoes' launches
  ([#305](https://github.com/vdmkenny/openreliant/issues/305)), and a multiplayer game's
  ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
- The Launched event each style's end queues (`event_launched`, `0x0045A9B0`,
  [#37](https://github.com/vdmkenny/openreliant/issues/37)).
- The radio's line as the player's launch goes (`0x00456E50`,
  [#48](https://github.com/vdmkenny/openreliant/issues/48)).
- When the ship the player launched from explodes, the first Yamato among the objects takes its
  place (`mission_frame`, `0x004932D4`), which OpenReliant does; what reads it, the radio's
  speakers, is not ported.
