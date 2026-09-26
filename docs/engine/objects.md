# Live objects

The ships, stations, gates, missiles and markers of a running mission. Each is a `0xB98`-byte object
from `gameobj.cpp`, and each embeds the root of a hierarchy of nodes standing for the parts of its
model. The layouts are defined in [`gameobj.zig`](../../src/engine/game/gameobj.zig),
[`objects.zig`](../../src/engine/game/objects.zig), [`create.zig`](../../src/engine/game/create.zig)
and [`srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig), and `make
ghidra-annotate` applies them to the Ghidra project with the names used here.

## The object array

`game_objects` (`0x587CE0`) holds 400 object pointers, which the engine calls the GO array. No
slot is ever empty. As a mission starts, `objects_reset` (`0x00466630`) gives every slot a
stand-in of type 1001, flagged `stand_in` and not created, sets `game_object_count` (`0x539AA0`) to
0, and forgets every ship type's objects and model. `create_object` (`0x00466C10`) fills a slot:
the one it is given, such as a mission ship's index among the mission's ship records, or for -1 the
next, which counts `game_object_count` up. It stops the game with a fatal error past the last slot
or for a slot filled already. `object_reset` (`0x004688B0`) pops a slot's orders and puts a new
stand-in in it, flagged `0x3C`.

`player_slots` (`0x58832C`) counts the slots from the first that belong to players, one in a
single-player game, and `player_index` (`0x5883FA`) is the player's own, the first in a
single-player game.

Every loop over the objects walks the slots from the first up to `game_object_count`, then the
cutaway slot (`0x57E04E`), which the mission's start sets to 399, the last, reading the count afresh
at every slot. The loops pass over objects by their flags: the simulation's updates and
`objects_update` skip `stand_in` and `disabled` ones, and `mission_frame`'s framing and drawing
`jumping` ones as well. **Improvement:** with every slot handed out, the cutaway slot comes round
again and again, and the game's loops never end; OpenReliant walks it once.

| Offset | Size | Field |
|---|---|---|
| `0x000` | 4 | Type: the ship's record in `shipstats.bin`. Types above 255, markers and nav points among them, have no stats |
| `0x004` | 4 | Slot in `game_objects` |
| `0x008` | 4 | [Flags](#flags) |
| `0x010` | 4 | The type's entry in `ship_combat_stats` |
| `0x014` | 4 | The type's entry in `ship_flight_stats`, or a missile's in `missile_flight_stats` |
| `0x018` | 4 | The type's model, as loaded |
| `0x01C` | 4 | Data kept for the type and shared by its objects |
| `0x020` | 4 | The renderer's object for it, or null |
| `0x024` | 2 | The shape the [wing status](hud.md#the-wing-status) window shows it by; 0 for none, as created |
| `0x028` | `0x104` | The root node of its model hierarchy |
| `0x150` | 2 | [Missile racks](missiles.md#the-loadout) fitted |
| `0x152` | 2 | Components listed |
| `0x158` | `0xF0` | Up to 20 missile racks, 12 bytes each |
| `0x248` | `0x2D0` | Up to 60 components, 12 bytes each |
| `0x5D0` | 4 | Engines in its model: parts of subsystem class 5 |
| `0x5D4` | 4 | The share of its engines left: 1.0 when created, less `1 / engines` for each one destroyed |
| `0x5E8` | 4 | Afterburner fuel: `100 * afterburner_fuel` from its stats when created, or zero in one of the game's modes; 5000 more for each fuel pod |
| `0x5EC` | 2 | [Countermeasures](missiles.md#countermeasures) left: 29 when created |
| `0x5F0` | 16 | Shields: four values, each `6 * shield_power - 1` when created |
| `0x600` | 16 | Armor: four values, each `6 * armor_class - 1` when created |
| `0x634` | 2 | Where its lights stand in their [blinks](rendering.md#static-lights), in ticks added to the mission's clock: `rand()` over its largest value, times 100 and truncated, when allocated (`object_alloc`, `0x00475DD0`) |
| `0x618` | 8 | The slots of two objects it passes through: the collision sweep tests no pair where either names the other. -1 when created |
| `0x644` | 4 | Its side: 0 friendly, 1 hostile, 2 neutral. Its type's when created; `SetHostile` makes it hostile or friendly |
| `0x648` | 4 | The tier a re-arm fits its racks by; nothing writes it |
| `0x64C` | 4 | Set while a missile homes on it: `mission_frame` clears it on every object, and `missiles_update` sets it |
| `0x658`, `0x65C` | 8 | Its [smoke](effects.md#smoke)'s template and emitter, or null for none |
| `0x660` | 1 | Its smoke's level, 0 to 3, by its damage |
| `0x664` | 4 | The shields' condition, how well they [recharge](#shields) as the armor wears: 1.0 when created |
| `0x668` | 4 | The cruise speed's condition, which `object_cruise_speed` scales the speed by: 1.0 when created |
| `0x66C` | 4 | The guns' condition: 1.0 when created. The guns recharge by it, and below 0.9 each shot goes off only as often as it plus a tenth (`guns_step`, `0x004770E0`) |
| `0x680` to `0x697` | | Its [orders](orders.md): the stack and what the current order keeps, the damage it has taken lately and its last attacker |
| `0x70C` | 4 | Its pilot's eject roll, 0 to 99 from `object_random15` when created: where a mission lets the pilot eject, it does below 40 ([Destruction](#destruction)). The `WillsBlag` command sets it to 100 |
| `0x728` | 12 | The [power distribution](controls.md#the-power-distribution)'s point on the power ball: (1, 1, 1) when created |
| `0x734` | 4 | The guns' share of the power as a factor on how fast they recharge: 1.0 when created |
| `0x73C` | 4 | The shields' share of the power as a factor on how fast they [recharge](#shields): 1.0 when created |
| `0x740` | 4 | Its pilot, a record of `pilotstats.bin` (`object_set_pilot`, `0x0049CCE0`) |
| `0x748` | 4 | The pilot's entry in `pilot_stats` |
| `0x74C` | 2 | The wing a mission lists it in: 0 the player's, 1 and 2 two more, `0xFFFF` none, as created ([The wings](hud.md#the-wing-status)) |
| `0x754` | 4 | The deathmatch power-up it holds (`gameobj.PowerUp`), -1 for none: a record of the table at `0x0050C510` |
| `0x75C` | 4 | The frame the power-up runs out at, or -1 for never |
| `0x760` | 4 | The frame the power-up was handed out at |
| `0xB8C`, `0xB90` | 8 | Orders from other players waiting for their frame, in a multiplayer game |
| `0xB94` | 1 | Set once `create_object` has filled the slot |
| `0xB95` | 1 | Nonzero while invulnerable: `SetInvulnerability` |
| `0xB96` | 2 | The 3D voice it holds, `0xFFFF` for none |

## Creating an object

`create_object(slot, type, tier, x, y, z)` fills the slot's object and returns the slot. It clears
the flags and sets the object up at rest at the place given, facing along the world's Z axis, with
no orders and no attacker, `motion_forward` as its motion, its armor whole and its own seed drawn
from `rand()`. A type above 255 stops there, as a stand-in for a marker or a nav point: flagged
`0x3C`, with a radius of 4000 and no shields or armor.

A few types are another ship under a number of their own: the Krasnaya (`0x35`, `0xDB` and `0xDC`,
for `0x78`), the Kiev (`0x36`, `0x40`, `0xDD` and `0xDE`, for `0xC2`), the Mitchell (`0xA0`, for
`0x13`), the Zakov (`0xA1`, `0xA2` and `0xE2`, for `0xB0`), the Kestrel (`0xDA`, for `0x0F`) and the
Mammoth (`0xE3` to `0xEF`, for `0x21`). Such a type takes the other's flight model and combat stats
into its own entries, keeping its gun groups and its name, and its object takes the other's number
once it is made.

The object points at its type's stats and takes the type's side from them. The type's model is
loaded with its first object (`ship_type_load`, `0x00466740`), with the type's schematic as its
data. OpenReliant's [`create/library.zig`](../../src/engine/game/create/library.zig) reads each
type's model and the models its attachment points mount once, and lets a type's go once no object is
of it. Each part of the model gets a node that plays its `startup` track from the start at 4 a step;
a part of class 6 gives the object `shield_generator`, one of class 5 counts as an engine, and an
attachment of kind 6 sets flag `0x2000000`. The parts are then linked, each posed as its track has
it at the start, and the object's origin moves to their centre of mass (`object_link_parts`). A
piece of debris takes a tenth of its mass, and a mine a radius of 2000.

Then come the pilot, record 66 of `pilotstats.bin` for the Coalition's types and 0 for the rest;
each quadrant's shields and armor full, `6 * shield_power - 1` and `6 * armor_class - 1`, and the
conditions that armor gives ([Shields](#shields)); for a model that lists no components the
shield's effect and, in every slot past the players', the `ecm` flag, and for one that does, the
`components` and `attached` flags; the afterburner's fuel, `100 * afterburner_fuel`, and 29
countermeasures; the power shared evenly. The gun and component counts are cleared, then the
components are listed and the [guns fitted](guns.md) from the model's muzzles, which sets the gun
count again; then come the guns' charge and rounds, their groups and the gun mode, the loadout, and
`targetable`, where the type allows it. Capital ships, planets, gates,
asteroids and a few other types get more set up for their kind.

The words of each `ship_combat_stats` entry from `+0x1C` on come from the executable rather than
from `shipstats.bin`: the gun groups, which the gun code fills in at run time (`gun_groups_build`,
`0x004667F0`), then whether the type can be targeted, the string that names it, its class and its
side. `make combat-tables` transcribes them into
[`create/combat.zig`](../../src/engine/game/create/combat.zig).

| Class | What it is |
|---|---|
| 1 | Fighters: the player's ships, their twins, and the Coalition's fighters |
| 2 | Capital ships and their wrecks, and other large bodies such as asteroids |
| 3 | Bombers, transports, tugs, escape pods and some stations |
| 4 | Gates, containers, satellites, beacons, pods, rock chunks and the like |
| 5 | Torpedoes |
| 6 | Debris |
| 7 | The proximity mine |
| 8 | Planets |

A type's side is 0 for the Alliance's, which start friendly, 1 for the Coalition's, which start
hostile, and 2 for the rest, which are neutral. Two objects on different sides are enemies.

[`create.zig`](../../src/engine/game/create.zig) ports `create_object` as `createObject`, and
`Objects` is OpenReliant's GO array: each slot the object's record, and what OpenReliant keeps
beside it where the record holds the original's pointers. Not ported yet: the tier, which chooses
the guns; the guns and their groups, the loadout and its pods
([#131](https://github.com/vdmkenny/openreliant/issues/131),
[#38](https://github.com/vdmkenny/openreliant/issues/38),
[#39](https://github.com/vdmkenny/openreliant/issues/39)); the shield's effect
([#133](https://github.com/vdmkenny/openreliant/issues/133)); the special types; the ship a player
chose for the mission; and the multiplayer cases.

## Flags

The word at `0x008` is a `GameObject.Flags`. Many of its bits are what the script's `Disable`
commands and their like set; the names in quotes are the developers' labels for their arguments.

| Bit | Name | Meaning |
|---|---|---|
| `0x2` | `components` | Its components are listed, as its model's header asks. The collision code treats such objects apart. |
| `0x4` | `no_collisions` | The collision sweep of `objects_update` leaves it out. |
| `0x8` | `unpowered` | `object_move` runs no motion function for it, so it drifts; knocks still move it. Set while it is disrupted and once it is wrecked, and with `0x10` during gate jumps and warps and by `object_reset`. |
| `0x10` | `frozen` | `object_move` isn't run for it. |
| `0x20` | `stand_in` | Set on objects of types above 255, such as the type-1001 stand-in an empty slot holds. The per-object loops skip them. |
| `0x40` | `exploding` | Set as it starts to explode (`object_destroyed`). It takes no more orders. |
| `0x80` | `can_reverse` | Reverse thrust works only while it is set. |
| `0x100` | `cloaked` | Set by `object_cloak` (`0x00463640`), which posts the Cloaked event ([The cloak](cloak.md)). |
| `0x200` | `targetable` | `SetTargetable` for the whole object, which sets it only when the word at `+0x24` of its combat stats is nonzero. |
| `0x400` | `disabled` | Not processed: `DisableObject`, "Stops entities from being processed", and `DisableObjectAtNextJump` at the next jump. |
| `0x800` | `ejected` | Set once its pilot ejects. It takes no more orders, and destroying it now makes it explode. |
| `0x1000` | `tractored` | Set while a ship's Scoop Up claims it, so no other ship takes it in ([Ejection](ejection.md#scoop-up)). |
| `0x2000` | `lights_disabled` | `DisableLights`. |
| `0x4000` | `shield_generator` | It has a shield generator, which destroying the part clears. |
| `0x8000` | `guns_disabled` | `DisableGuns`. `orders_update` skips `0x0047C950` for it. |
| `0x10000` | `missiles_disabled` | `DisableMissiles`. |
| `0x20000` | `engines_disabled` | `DisableEngines`. `object_orders` holds its throttle at zero and stops both burns. |
| `0x40000` | `eject_disabled` | `DisableEject`. The player cannot eject. |
| `0x80000` | `do_not_disturb` | `DoNotDisturb`, "dont disturb", which the command describes as keeping comms from disturbing it. It does not retaliate either. |
| `0x100000` | `no_avoidance` | `SetShipAvoidance` with "Disable Avoidance code": the avoidance code passes it over. |
| `0x200000` | `jumping` | Set during the jump orders. It cannot fire, and the avoidance code passes it over. |
| `0x400000` | `attached` | Set while the Dock and Ripper orders hold it to another object; their ends clear it. |
| `0x10000000` | | **Unknown.** Set by `0x00474B40` as it sends a ship off, the player's into Friendly Fire and others into Jump Out, and cleared by Friendly Fire. It takes no orders while it is set. |
| `0x20000000` | `unlisted` | `DisableListing`, "stop listing". |

**Unknown:** the other bits.

## The model hierarchy

A node (`objects.cpp`, `node_alloc` at `0x004991D0`) is `0x104` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Kind: 1 for a model part's node |
| `0x04` | 4 | Flags, a `Node.Flags`: `0x1` a next place pending; `0x2` a new place committed this step, `0x4` one the frame hasn't taken up yet, and `0x8` a next place worked out from a pose, which [drawing between steps](#drawing-between-steps) reads; `0x800` animating, or carrying a node that is; `0x20` hidden; `0x40` a component's holder once `component_damage` (`0x004645C0`) takes the component's armor below zero; `0x100` listed among the components; `0x400` the base of a [turret](guns.md#turrets), whose gun stops for good when the node is destroyed (`node_forget`, `0x00499BB0`); `0x2000` targetable, for the parts whose part flag `0x1000` says so, and changed by `SetTargetable`. Cycling subtargets (`0x00414F90`) stops only at components that are targetable and have neither `0x10` nor `0x20` |
| `0x08` | 4 | Its frame, the transform the renderer uses |
| `0x14` | 12 | Position, relative to the node it hangs from |
| `0x20` | 36 | Orientation, a 3x3 matrix, relative likewise |
| `0x44` | 24 | The [pose](#animation) the committed place came from: angles, then an offset |
| `0x5C` | 12 | The next position, which the next simulation step commits |
| `0x68` | 36 | The next orientation |
| `0x8C` | 24 | The pose the next place came from |
| `0xA4` | 4 | The model part it stands for: the part's record as loaded, which starts with the [`.SHP` part record](../formats/shp.md#part-tag-0x01) |
| `0xA8` | 4 | The object that owns it, set in the root |
| `0xB4` | 4 | How it plays its animation track: 0 not at all, 1 once, 2 looping, 3 back and forth |
| `0xB8` | 4 | Which of its part's tracks it plays |
| `0xBC` | 4 | Where it is in the track |
| `0xC0` | 4 | How far it moves on through the track each simulation step |
| `0xC4` | 12 | The angles the track has it at |
| `0xD0` | 12 | The offset the track has it at |
| `0xDC` | 12 | Angles a turret turns it by (`node_turn`), added to the track's |
| `0xE8` | 4 | A component's counterpart of the object's armor |
| `0xEC` | 4 | The node it hangs from; null for a root |
| `0xF4` | 4 | Capacity of the child list: 100 once created |
| `0xF8` | 4 | Children |
| `0x100` | 4 | The child list |

`node_owner` (`0x00499F20`) finds a node's object by climbing to its root. `node_world_place`
(`0x004AD960`) and `node_next_place` (`0x004AD8D0`) find where a node stands in the world, at its
committed place or at its next: its own place in the node it hangs from, turned and moved by each
parent's in turn, up through a mounted object's root to the ship's. They skip a parent's turn where
its diagonal reads 1, 1 and anything but 1, which no turn does.

A part's node holds no turn: `node_add_part` (`0x00499430`) copies the part's position and leaves
the node's orientation the identity it was allocated with. It hides a part whose part flag `0x04`
marks it damaged. `create_object` hangs every part's node from the root (`object_add_part`,
`0x004760C0`, which takes the object's centre at `0x524` off the position), then
`object_link_parts` (`0x00476130`) hangs each from its parent part's node, keeping it where it is,
and moves the object's origin to its parts' centre of mass (`object_recentre`, `0x004769F0`).

A part keeps its origin in the model whatever it hangs from, so hanging it somewhere else has to
work that origin out again in the new frame, which `node_place` (`0x0049A140`) does (see
[Animation](#animation)). `object_link_part` (`0x00476180`) runs it through `node_animate`
(`0x00499F40`) at time zero, which poses it as the part's first track has it at its start, and
copies the place, but not the pose, into the node and its frame. With no pose the sums cancel and
the part stands where it stood; a part whose first track starts it posed, such as a gun barrel
drawn back, stands so from the start.

The centre of mass:

- `node_mass_add` (`0x004764A0`) sums over the shown part nodes, a node's children first, the
  density times the part's first moment about the root: its origin there times its volume, plus its
  own first moment. Over the sum of density times volume, that is the centre.
- The centre is added to the object's centre at `0x524` and, turned, to its position, and
  `object_bounds` (`0x00476680`) takes it off the position of each part hung from the root.
- `object_bounds` then finds the object's bounding box and radius, its farthest vertex from the
  origin, over the vertices of every part node's current level, and sums its moment of inertia.

An object's root holds the object's place in the world: `object_set_position` (`0x0049B600`) and
`object_set_orientation` (`0x0049B650`) set it, together with the root's frame and further copies
at `0x768` and `0x798`, and `mission_ships_sync` (`0x0045A5F0`) copies it into the mission ship's
runtime position.

A frame is Surrender's `0xB4`-byte transform, which `frame_create` (`0x004C51C0`) allocates with a
name, such as `GOroot object` for an object's root. It holds a parent frame at `+0x10`, an
orientation at `+0x18` and a position at `+0x3C`. A part's frame hangs from its parent part's, and
the root frame of an object mounted on an attachment point from the part's.

## Animation

A part can carry animation tracks, which move it about its place ([`.SHP`
clips](../formats/shp.md#animation-clip-tag-0x0a)): each has a length, a mode it plays in unless
told otherwise, a name, keyframes and events. The loader (`model_load`, `0x004A44D0`) files the last
track named `startup`, `fire` and `deploy`, whatever the case, in three slots on the loaded part
(`+0x234` to `+0x23C`), and a node starts one by its slot (`node_play`, `0x0049A2D0`) or by its name
(`node_play_named`, `0x0049A340`): from a time, unless that is below zero, in a mode, the track's
own for -1, at a speed. Any mode but 0 marks the node and every node it hangs from as animating
(flag `0x800`, `0x0049A2A0`). `create_object` plays each part's `startup` track from its start in
its own mode at a speed of 4, which is how the radar dishes of some capital ships and stations turn
from the start.

`node_tree_update`, once a simulation step, walks from the object's root into the children that are
animating, not hidden and not flagged `0x80`, as the nodes of lights, engine glows and muzzle
flashes are. It keeps them on a stack of 500: a node pushes those of its children, in order, and the
last pushed is visited next. The root's children are every part of the model, whatever part each is
linked to, so a part is visited while its parent part is hidden; a part's own children are the roots
of the models it carries. A node it visits commits its pending place. One that plays no track, or
plays at no speed, loses its mark, which it keeps while it pushes a child that has one. One that
plays moves its time on by its speed and, for a track of some length:

- **Once** (1): stopping at the end, time and speed then set to the length and zero, or at the
  start, going backwards.
- **Looping** (2): past the end, starting again.
- **Back and forth** (3): out over the length and back over the next, round and round.

It then poses the node for the time (`node_animate`) and sets off the track's events whose time it
passed: from the whole number the old time rounds to up to, but not including, the new one's, and
for a looping track that went round, from the old time to the end and from zero to the new time.
Going back and forth sets off none. An event of kind 0 fires a shot from each of the part's
muzzles, its nodes of kind 4 (`clip_event_muzzles`, `0x0047C7B0`), which is how an aimed
[turret](guns.md#turrets) fires; one of kind 2 puffs particles from its attachments of kind 7
(`0x0047C800`); the update knows no others. A track of no length, or a mode past 3, sets off the
events of whatever span the last node visited left.

`node_animate` takes the pose between the keyframes either side of the time, in a straight line,
from no pose at time zero before the first, and holds the last past them all. `node_place` then
takes off the pose's angles about any axis whose flag the part has at `+0xC8`, adds the turret's
(`+0xDC`), and works out the next place: the part's origin plus the offset, less the origin of its
parent's part or the object's centre, turned about the part's mount point by
`Oᵀ · R · O`, where `O` is the part's orientation and `R` the turn `mat3_from_angles` makes of the
angles. The part turns in its own frame, and with no angles stays unturned.

`node_turn` (`0x0049B520`) turns a node by angles of its own, as a [turret](guns.md#turrets) turns:
it adds them to `+0xDC` and marks the node animating. About each axis whose limits the part holds
(`+0xD8` to `+0xEC`, in degrees) the angle then stays within them; about one whose two limits are
equal it comes round to within a half turn either way. `node_place` places the node by them.
**Improvement:** the game turns the degrees to radians by a rounded 0.0174533 and a half turn by
3.14159; OpenReliant by the exact values.

## Drawing between steps

The simulation steps 25 times a second, but `mission_frame` draws each object where it stands that
far into the step (`0x0049A880`, for every object before the camera is placed): each node that a
step committed a new place for is drawn `simulation_counter / 4` of the way from that place to the
next (`node_frame_update`, `0x0049A460`). At the start of a step it is drawn at the committed
place. A node posed by `node_place` is drawn between its two poses, the angles turning the short
way round, so a dish that loops a full turn doesn't spin back at the end of its track. Any other,
an object's root among them, moves along the straight line between its places and turns by that
share of the angles that turn one into the other (`mat3_angles`). The camera follows the root's
frame, so it moves with the object as drawn. A node no step has moved keeps its frame. The walk
(`node_tree_frames`) goes into each child that is neither hidden nor flagged `0x80`: the root's
children are every part of the model, so a part is drawn between steps while the part it is linked
to is hidden, and a hidden part's own children, the models it carries, keep their frames.

In a multiplayer game another player's ship is drawn between the places its last two messages gave
it (`+0x768`, `+0x798`) instead.

## What an attachment point holds

`node_mount` (`0x00499A10`) mounts what a part's attachment points carry, by the attachment's kind:
an engine glow for kind 2, a muzzle's flash for kind 3 ([Guns](guns.md#muzzle-flashes)) and a light
for kind 4, which are nodes of the part's own, and for a gun
or a pod an object of its own, whose model `attachment_models` names by the attachment's kind and
id, twenty ids to a kind.

Each node has a kind, which `node_draw` (`0x0049A8C0`) draws it by: 1 a model part
(`node_add_part`), 2 an engine glow (`node_mount_glow`, `0x00499540`), 3 a light's two sprites and
5 the point light a blinking light casts (`node_mount_light`), 4 a muzzle's flash
(`node_mount_muzzle`, `0x00499680`), and 6 what a hit leaves where it struck (`node_add_effect`,
`0x004992D0`; [Effects](effects.md)).

A mounted object is built the way any other is: a node for each part of its model, then
`object_link_parts`, which also moves its origin to its own centre of mass. Its root then hangs
from the node of the part that carries the attachment, and stands where the attachment does: the
attachment's position, plus that centre turned by the attachment's orientation, so its geometry
stands where its own model puts it. Its orientation is the attachment's.

A capital ship carries its turrets this way, where a fighter carries its own as a model part of
subsystem class 3 with its own yaw and pitch limits.

## Motion

`object_move` (`0x00473FF0`) moves an object for one update. It calls the object's motion function,
the code at `0x640`, then sets the root's next orientation to its orientation times the object's
rotation (`0x56C`), and its next position to its position plus the object's velocity (`0x590`),
and records the length of the velocity as the speed (`0x5D8`). The root keeps that next place at
`+0x5C` and `+0x68`.

Before that, it checks the flags:

- A `frozen` object isn't moved at all.
- If the object has taken knocks since its last move, they are applied in place of the motion
  function (see [Knocks](#knocks)). An `unpowered` object has no motion function run either.
- A `jumping` object that isn't knocked or `unpowered` stays where it is.

After the move, it sets bit 0 of the network flags (`0x00C`) if the object is moving and bit 1 if
any of its angular rates is nonzero. The multiplayer code (`0x004BB2D0`) then sends the object's
position and orientation. Bit 2 is set while the Scoop Up order runs, and the multiplayer code
skips such objects.

For the player's ship, `object_move` raises the camera's shake (`hit_shake`) to at least
`0.2 * (speed / cruise speed - 1)`, so the view shakes when the ship flies faster than its cruise
speed, as it does under afterburner. It also stores the change in the player's speed at
`0x00562CE4`, which nothing reads.

`object_move` also sets bit 0 of the root's node flags, marking the next place as pending. At the
start of the next simulation step, before the objects move, `simulation_step` runs
`node_tree_update` (`0x00476C90`) for every live object. It commits the pending next place by
copying the 0x48 bytes from `+0x5C` over those from `+0x14` (the next position and orientation
over the current ones), clears bit 0 and sets bits 1 and 2. It does the same for each animating
part, whose animation it also advances. So an object moves on from the place the previous step
worked out, and between steps its `position` is one step behind `next_position`, which the rest
of the game reads as the object's place.

Each step, before the node updates, `simulation_step` also orthonormalizes the root's next
orientation (`0x004C2690`) of one object, the one `simulation_turn` (`0x00562FFC`) names. The turn
moves on by one each step and goes round the live objects, so rounding never builds up in any
object's orientation. The same object's orientation at `0x7A4`, which a multiplayer game draws
other players' ships by, is orthonormalized too.

`create_object` gives every object `motion_forward` (`0x004744C0`), which runs the flight model,
`object_fly` (`0x004742E0`), with a thrust of 1; `motion_backward` runs it with -1. The orders
select the others (see [The orders' motion functions](#the-orders-motion-functions)).

| Offset | Size | Field |
|---|---|---|
| `0x00C` | 4 | Network flags |
| `0x51C` | 4 | Knocks since the last move |
| `0x520` | 4 | Mass: the sum of the parts' masses (`object_recentre`) |
| `0x524` | 12 | How far `object_recentre` moved the origin to the centre of mass |
| `0x530` | 12 | Impulse: the sum of the knocks' forces |
| `0x53C` | 12 | Angular impulse: the sum of the knocks' force × lever |
| `0x548` | 36 | The inverse of the inertia tensor |
| `0x56C` | 36 | Rotation: the turn applied each update, a 3x3 matrix |
| `0x590` | 12 | Velocity, added to the position each update |
| `0x5B8` | 4 | Throttle |
| `0x5BC`, `0x5C0`, `0x5C4` | 4 each | Roll, pitch and yaw inputs, between -1 and 1 |
| `0x5C8` | 4 | Lateral input |
| `0x5CC` | 1 | Afterburner |
| `0x5CD` | 1 | Reverse thrust |
| `0x59C` | 4 | Collision radius |
| `0x5D8` | 4 | Speed |
| `0x5DC`, `0x5E0`, `0x5E4` | 4 each | Roll, pitch and yaw rates |
| `0x640` | 4 | Motion function |
| `0x650` | 4 | The last update's throttle |
| `0x668` | 4 | `armor_speed_factor`: scales the cruise speed as the armor falls |
| `0x738` | 4 | `speed_factor`: scales the cruise speed. The engines' share of the power ([Controls](controls.md#the-power-distribution)); 1.0 when created |

For the player's ship, the [controls](controls.md) set the inputs, the throttle and the two burns;
for the others, the routines of their [orders](orders.md).

The flight model works in the ship's own frame, the
[model frame](../formats/shp.md#coordinate-frame): X lateral, Y down, Z forward. Each quantity
moves toward a target through an inertia from the ship's [flight stats](../formats/stats.md):
`new = old * inertia + target * (1 - inertia)`.

1. **Throttle.** It stays between 0 and 1, but is 2 while the afterburner burns and -1 under
   reverse thrust. Either burns 4 units of afterburner fuel an update, and fuel stops at zero.
2. **Turning** (`object_steer`, `0x00474150`). Each input is clamped to between -1 and 1, and each
   angular rate moves toward the ship's rate for that axis times the input, through that axis's
   inertia. For callers that ask, the target is divided by `3 - 2 * |throttle|` where that exceeds
   1, so the ship turns slower at low throttle. The three rates then make the rotation.
3. **Speed.** The velocity is turned into the ship's frame. Along Z, `v * |v|` moves toward
   `u * |u| * target * target`, where `u` is the thrust times the throttle and `target` the cruise
   speed, or `max_speed` under afterburner or reverse thrust; the square root, with its sign, is
   the new forward speed. Along X, the speed moves toward a quarter of the target times the lateral
   input. Along Y it only decays. All three use the ship's `inertia`, and the velocity is turned
   back.

The cruise speed (`object_cruise_speed`, `0x00403060`) is `max_speed` times `speed_factor`
(`0x738`), 1.0 when created, times the share of engines left, and, unless the camera is in view 13
or the object is invulnerable, times `armor_speed_factor` (`0x668`), which falls as the armor does.
So losing engines or armor slows a ship.

### Knocks

Collisions and explosions push objects with `object_knock` (`0x004763C0`), which takes a force and
the world point it acts at. It adds the force to the impulse (`0x530`), adds force × lever to the
angular impulse (`0x53C`), where the lever runs from the object's position to the point, and counts
the knock (`0x51C`). The engine takes the cross product in that order, which gives the opposite of
the torque. `object_knock_local` (`0x00476430`) does the same with the force in the object's own
frame and the lever given directly; the Disrupted order pushes a ship with it, with no lever.

The next `object_move` applies the knocks with `object_apply_knocks` (`0x00476270`) instead of
running the motion function:

1. The impulse times `1 / mass` is added to the velocity.
2. If the angular impulse isn't zero, it is converted to the object's frame and multiplied by the
   inverse inertia tensor (`0x548`), which `object_recentre` builds from the parts
   (`object_bounds`) and inverts (`0x004AD9F0`). The rotation is turned by the negative of the
   result, to first order, and orthonormalized (`0x004C2690`), and the angular rates are set to
   its angles (`0x004C2740`). So the object keeps spinning until its steering takes over again.
3. The count and both impulses are cleared.

`0x004C2740` takes its angles from `sr_atan2` (`0x004C3200`), which looks them up in a table of the
arctangents of 0 to 1 in steps of 1/4096 (`0x005DE344`), by the smaller of `y / x` and `x / y`
rounded to the nearest step.

**Improvement:** OpenReliant computes the angles instead, which is more precise by up to half a step.

### The orders' motion functions

The orders select eight more motion functions, which read the order's state (`0x68C`). OpenReliant
has the two the [ejection](ejection.md) selects, `motion_brake` (`0x00474610`) and `motion_drift`
(`0x00474B00`), and the two the [launches](launch.md) select, `motion_downward` (`0x004744E0`) and
`motion_plain` (`0x00474570`); the rest aren't ported yet
([#30](https://github.com/vdmkenny/openreliant/issues/30)).

| Address | Selected by | What it does |
|---|---|---|
| `0x004744E0` | The Reliant's launch, the Ripper | The plain flight model along the object's Y axis, which points below it: steers, the throttle slowing no turn, then moves the velocity through the flight stats' `inertia` toward the throttle times `max_speed`, the last update's throttle nothing. A fighter (class 1) flies by the first ship type's flight stats, the Predator's (`ship_flight_stats`, `0x004F9E70`), so that every fighter leaves its carrier alike. |
| `0x00474570` | A torpedo's launch, the Ripper, landing orders | The same along the Z axis, keeping the throttle as the last update's, and the Ripper flies by its own stats whatever its class. A flight model without the throttle rules or the burns. |
| `0x00474610` | Eject | Slows the velocity to 0.97 of itself each update. |
| `0x00474640` | Jump Out | Places the object between the two points of the order's state, each coordinate eased by the time since the jump started. No rotation. |
| `0x004746D0` | Jump In | Flies along the nose at 2400, or 600 for an object without components, less 0.003 of that per unit of time since the jump started, but never slower than the cruise speed. No rotation. |
| `0x00474770` | Follow Curve, Dock | Steers toward the point the order's state gives and moves toward it, no faster than the order's speed limit. |
| `0x00474930` | Follow Curve | The same, flying tail first. |
| `0x00474B00` | Jump In, and the ship a pilot has left (`eject_separate`) | Slows the velocity to 0.99 of itself each update. |

### Porting

[`motion.zig`](../../src/engine/game/motion.zig) holds the model, `steer`, `fly` and `move`, whose
file the binary doesn't name: it lies after `explode.cpp`'s code and before `gameflow.cpp`'s.
`cruiseSpeed` is in [`ai.zig`](../../src/engine/game/ai.zig), since `object_cruise_speed` lies after
`Ai.cpp`'s code, and [`gameobj.zig`](../../src/engine/game/gameobj.zig) has `knock`, `knockLocal`
and `applyKnocks`. OpenReliant passes the flight stats and the camera
view in, where the game reaches them through the object's own pointer and a global, because
`GameObject` keeps the binary's 32-bit pointers for its layout. For the same reason `move` takes
the camera's shake as a pointer, set only for the player's ship, where the game compares the slot
with the player's and writes the global. `Motion` is an `enum` of the two routines
`create_object` installs, in place of the function pointer at `0x640`, and the rule each quantity
settles by is one `settle` helper rather than the six copies the binary holds.

`gameobj.updateTree` ports `node_tree_update`, which `gameobj.simulationStep` runs for every live
object at the start of each step, after `gameobj.orthonormalizeTurn` on the object whose turn it is
(`gameobj.nextTurn`). `create.objectsUpdate` then moves them.

Not yet ported: the orders' motion functions
([#30](https://github.com/vdmkenny/openreliant/issues/30)), and the inertia tensor that
`object_recentre` inverts into `0x548` ([#87](https://github.com/vdmkenny/openreliant/issues/87)),
so knocks don't turn objects in OpenReliant yet.

## Shields

Each simulation step, `simulation_step` runs `object_recharge_shields` (`0x00476FC0`) for every
object, after its node update. Each of the four shields gains its full charge,
`6 * shield_power - 1`, times the shields' power factor (`0x73C`) and their condition (`0x664`),
over the type's `shield_recharge` seconds of steps, and stops at the full charge. For the player's
ship, the full charge of the fore shield, the third, is lower by however far the aft shield and its
[reserve](controls.md#the-shield-balance) together go beyond it, and the aft shield's likewise.

An object whose components are listed recharges no shields here, and neither does one holding
the `no_shield_recharge` power-up (8). One whose `0xB95` is 5 has its shields emptied instead. In a
multiplayer game, the player's shields don't recharge while `0x5D76F0` is 4 and `0x5DB538` names
the player. **Unknown:** what those values mean.

`object_armor_conditions` (`0x00492370`) works out three conditions from each quadrant's armor over
its full armor, `6 * armor_class - 1`, the fore quadrant being the third and the aft the fourth:
the shields' (`0x664`), a quarter of each quadrant's; the guns' (`0x66C`), half the fore one's and
a quarter of each side's; and the cruise speed's (`0x668`), a quarter plus three quarters of the
aft one's. `create_object` runs it once the armor is full. For the player's ship it also sounds a
warning, sound 1 of `betty.fat`, at most every 500 ticks (`0x00588334`), while a quadrant has lost
its shield and half its armor.

[`gameobj.zig`](../../src/engine/game/gameobj.zig) ports the recharge as `rechargeShields`, which
`simulationStep` runs, and [`main.zig`](../../src/engine/game/main.zig) the conditions as
`armorConditions` and the warning as `armorWarning`. Not ported: the multiplayer case.

## Destruction

What gets through a shield wears the quadrant's armour (`object_armor_damage`, `0x004641F0`). An
invulnerable object takes it only while it leaves armour to spare: one fully invulnerable from
anything, one that only a player can hit from anyone else. One in the last state, 4, takes none.
Armour below zero destroys the object (`object_destroyed`, `0x00401F30`), telling it that it may
spin out, and that a player's pilot has no time to eject where the blow was over 1000.

Outside multiplayer the game's difficulty (`0x00562F14`: 0 easy, 1 medium, 2 hard, which SET GAME
DIFFICULTY starts at medium) scales damage (`damage_by_difficulty`, `0x00463D70`):

| Difficulty | A shot on a hostile object | Anything on the player's ship |
|---|---|---|
| Easy | ×1.5 | ×0.375 |
| Medium | ×1 | ×0.5 |
| Hard | ×0.75 | ×0.75 |

`object_damage` (`0x00463EE0`) scales what the shield takes, but reckons what passes through from
the damage before the scaling. `object_armor_damage` scales its damage twice, once for
`recent_damage` and that again for the armour, and `component_damage` (`0x004645C0`) once. So at
medium a hit on the player's ship takes half off its shield and a quarter of what gets through off
its armour. The game tells a shot by comparing the damage's kind with the player's slot, which is
0, a shot's kind, in a single-player game. OpenReliant takes the difficulty from `--difficulty`,
medium by default.

- An AI ship's pilot ejects where the ship is in the player's wing, `0x74C` 0, and its roll at
  `0x70C` is below 40, or where the ship was told to eject before exploding. The ship spins on under
  Eject Spin (108).
- The player's pilot ejects, unless it has already, the blow was too heavy, or the ship is the
  Kamov: Eject Player (118) marks the ship ejected and unpowered and `mission_ending` (`0x00588394`)
  8. The ship drifts, the player's controls still running, for 400 to 599 ticks, and is then
  destroyed again, now without spinning out.
- Otherwise the object explodes: its stack becomes the one order Explode (11), whatever it was
  doing, and it is flagged `exploding`.

Explode's `init` (`0x00408610`) picks a mode by what the object is, with an `init` and an `update`
for each in `explode_modes` (`0x004E1798`): a ship, a ship that lists components going as a whole,
one of its components, an asteroid, and the limpet car. A ship (`0x004086F0`) is heard at once
within 20000 of the camera, sound 11 on a sure voice, and goes in one of three styles, by
`object_random15` over 3; the torpedoes always halt:

| Style | Init | What it does |
|---|---|---|
| 0, spin out | `0x00408BC0` | Unpowered, it drifts on, turning by a random spin a step, up to ±0.025 about its first two axes and ±0.15 about its third, which shrinks to nothing as its end comes: 200 to 399 ticks on. Near its end it trails burning bits. A torpedo, or a ship that may not spin, stops dead instead and blows up at once. |
| 1, burst | `0x004090F0` | Unpowered, no longer turning, it bursts at once. |
| 2, halt | `0x00408D20` | It stops dead and blows up at once. A torpedo sets off a chain of fireballs and a shockwave that harms the player. |

Having picked its style, a ship credits its end (`explode_kill_credit`, `0x00408500`): where the
player's ship struck it last (`last_attacker`) and it is hostile, and a fighter by its type's class,
a Kamov, a Kurgan or a Gurevich, the pilot has another kill (`kills_add`, which the display's skull
readout shows), and a wingman remarks on it. It does this only while `0x00529C6C` is set, as a
mission's start leaves it.

Past its end, a burst blows up in its own way (`explode_burst`, `0x00471DB0`), a torpedo not at all,
having gone up as it stopped, and anything else in a blast (`explode_blast`, `0x0046C980`); both
play sound 11 again. `object_retire` (`0x004688E0`) then leaves a stand-in, of type 1001, flagged as
one and exploding, not targetable and with no orders, which nothing moves, draws or collides with.

The other modes:

- A ship that lists components, going as a whole (`explode_hull_init`, `0x00409170`): each part of
  its hull hanging from the model's root, but a part of a damaged model, is left with -1 armour, and
  the root is flagged for the component losses to take it away ([Components](#components)). Its
  update (`0x004091E0`) ends a disabled ship as its hull holding it together does
  (`object_hull_lost`) and pops the order of any other.
- One of its components, the one the order is aimed at (`explode_component_init`, `0x00409200`):
  where it is shown, it is left with -1 armour, and the root of the model holding it is flagged.
  Its update (`explode_component`, `0x00409260`) pops the order.
- An asteroid, types `0x79` to `0x7F` (`explode_asteroid_init`, `0x00409270`): unpowered and
  frozen, it goes the frame after (`explode_asteroid`, `0x004092A0`) in a fireball as wide as 1.5
  times its radius, lighting what is round it, and is retired. Where its `visibility` times 0.4 is
  at least 0.16, three asteroids of types `0x7B` to `0x7E`, at random, take its place, that much of
  its size: `visibility`, and the scale of their first part's frame (`+0x48`). The first is turned
  three times 1.88496 about the X axis, the next twice and the last once, and each stands 3 of its
  own radii along its nose from where the rock was, still and colliding with nothing. A whole rock
  so leaves three of 0.4, and each of those three of 0.16. **Improvement:** 1.88496 is three fifths
  of a half turn, rounded; OpenReliant computes it.
- The limpet car, type `0x1D` (`explode_limpet_car_init`, `0x004094D0`): it stops dead, unpowered,
  with a random turn up to ±0.025 about its first two axes and ±0.15 about its third, and goes up in
  a fireball as wide as its radius. Its update (`explode_limpet_car`, `0x004095F0`), the same step,
  hides its first part, blows it up (`explode_blast`), and replaces it in its slot with a limpet
  pod, type `0xBC`, where that part was going; a car whose first part is already hidden blows up and
  is retired.

The player's ship has the camera watch its end, locked: a spin-out slower than 100 from behind,
pulling away (view 8), a faster one from where the camera was (view `0x1A`), a burst from there
watching where it burst (view `0x1B`), and a halt from behind. `mission_ending` becomes 1.

A ship's end, and the limpet car's, posts its Destroyed event for the mission's triggers
([Script VM](script-vm.md#events)).

[`ai.zig`](../../src/engine/game/ai.zig) ports `object_destroyed` as `objectDestroyed`,
[`collision.zig`](../../src/engine/game/collision.zig) the armour damage as `armorDamage`,
[`aiexplode.zig`](../../src/engine/game/aiexplode.zig) Explode,
[`aieject.zig`](../../src/engine/game/aieject.zig) the [ejection](ejection.md)'s orders,
[`explode.zig`](../../src/engine/game/explode.zig) the blasts, and
[`create.zig`](../../src/engine/game/create.zig) `object_retire` as `retire`.

The blasts' break-up, particles, fireballs, burning bits and shockwaves are in
[Effects](effects.md). Not ported: what a few types set off first
([#238](https://github.com/vdmkenny/openreliant/issues/238)); the Ulysses' own end
([#232](https://github.com/vdmkenny/openreliant/issues/232)); the radio's lines on the kill
([#48](https://github.com/vdmkenny/openreliant/issues/48)); and the pilots' records the end keeps,
its pilot taken off the wing's list (`0x0058A958`) and marked lost (`0x005047D0`)
([#301](https://github.com/vdmkenny/openreliant/issues/301)).

## Components

The parts whose [`.SHP` flags](../formats/shp.md#part-tag-0x01) have bit `0x02` are the object's
**components**, such as a capital ship's engines, shield generators and turrets. `create_object`
gives the object a node for each part of its model, all hanging from the root in part order, and a
part's node holds the roots of the objects mounted on the part's gun and pod
[attachment points](../formats/shp.md#attachment-point-tag-0x09). When the model's header asks for
components, `object_collect_components` (`0x00468760`) lists them from the root down: for each node,
first its children that are components, then, child by child, theirs. So the model's own components
come first, in part order, and then, part by part and mount by mount, those of the mounted models.
A component's entry holds its node, the slot of the parent's child list that holds it, and at `+8`
a halfword that is nonzero while the component is invulnerable.

A component's armour comes from its part's record (`0x104`), and `component_damage`
(`0x004645C0`) wears it down: the damage goes to the first part of the component's assembly that
still has armour, a part with more than 2499 takes only a hit of 500 or more, an object with a
shield generator keeps three quarters of a hit below 1000, and a component whose armour runs out
marks its root as destroyed (node flag `0x40`). A collision does none of this. Every part node
stays in its root's child list, whatever part `object_link_part` links it to, so the node holding
a component (`node_holder`, `0x00499EE0`) is always its model's root: the object's, or that of a
model mounted on it.

### A component's destruction

`node_draw` (`0x0049A8C0`) acts on a root flagged destroyed as `mission_frame`'s pass reaches it,
whether the object is in sight or not. For each of the root's parts whose armour is below zero and
that has no flag `0x10`, in part order:

1. It gets flag `0x10`, which neither targeting nor cycling subtargets accepts.
2. An engine takes `1 / engines` off the object's share of its engines (`+0x5D4`).
3. A shield generator, while the object has one, plays `SHLDDOWN` (sound `0x39`) at the part,
   facing its way, and clears the object's `shield_generator`, so hits are no longer cut to a
   quarter. For any other part, the routine at the object's `+0x614` runs, and where it answers
   false the pass over this root ends there, its flag left set.
4. `explode_component_lost` (`0x0046D090`) sets the assembly off: after a few types' own extras,
   each part of the assembly goes up with what is mounted on it (`explode_part_burst`, see
   [Effects](effects.md#a-components-destruction)), and the root sends out 200 of the flame and
   sound `0xB`.
5. Each part of the assembly (the same link id) that is shown queues Destroyed for its component
   index (`event_destroyed`) and is destroyed (`node_destroy`, `0x00499E30`), with every part
   linked to it and every model mounted on them. Where it is of class hull, the ship ends first:
   the player gets the kill of a Kurgan, an Antanov or a Gurevich, and `object_hull_lost`
   (`0x00401F00`) gives its order way as to Explode, empties its stack and marks it exploding.
   Each hidden part of the assembly, its damaged model, is shown.

Then the player's subtarget's red parts are put back and picked out again where the object is the
player's target, and the flag is cleared.

`node_forget` (`0x00499BB0`), as a node is destroyed, stops for good each of the owner's turrets
whose base the node is (turret kind -1) and takes the node out of the owner's components and the
table at `+0x518`.

`create_object` gives most capital ships, bases and stations `explode_capship_component`
(`0x0046F820`) at `+0x614`, by the type whose stats they take, and type `0x16`
`explode_ulysses_component` (`0x0046EA50`). The first answers true for any part but one of class
hull; for that one, it marks the ship unpowered and exploding, hides its force fields, splits it in
two ([Effects](effects.md#splits)), credits the kill as above and ends it with `object_hull_lost`.
The second answers false for every part.

Each part the pass takes out that the object lists as a component posts the component's Destroyed
event first ([Script VM](script-vm.md#events)).

[`objects.zig`](../../src/engine/game/objects.zig) ports the pass as `loseComponents` and
`node_destroy` as `destroyPart`. Not ported: the subtarget's red parts
([#45](https://github.com/vdmkenny/openreliant/issues/45)), the types' own extras
([#238](https://github.com/vdmkenny/openreliant/issues/238)) and the Ulysses' routine
([#232](https://github.com/vdmkenny/openreliant/issues/232)).

OpenReliant lists them in [`create.zig`](../../src/engine/game/create.zig) as the parts themselves,
since a mounted turret's parts are not the hull's, and marks each one as a component and, where the
model asks, as targetable. A model with more components than the object holds leaves the
rest unlisted, where the game stops with a fatal error.

`sltool shp components` lists a model's components in that order, with their armour, finding the
mounted models beside it, and `sltool dte triggers` and `sltool dte script` name the components
missions refer to. Every component a trigger names in the shipped missions is on its ship's list,
and nearly every one a squad member or `push_component` names. The rest point past the end of the
list, mostly by one; the missions do not always agree among themselves, as when one squad of the
Kiev Morzov in `mission19` holds its turrets as components 3 to 9 and others hold them one by one as
4 to 10.

Mission data names a component by its index in that list: a trigger's qualifier, a squad member's
component, the operand of `push_component`. Events on a component carry its index, and destroying
component `n` clears bit `n & 31` of the mission ship's word at `0x30`.

Commands act on a component through its assembly: the nodes beside it whose parts share its part's
link id, such as a turret and its barrels. The assembly can hold a damaged model too, parts whose
part flag `0x04` is set, which stay hidden (node flag `0x20`) while the component is intact.
`DisableObject` hides the intact parts and shows the damaged ones, and enabling does the reverse; on
a whole ship it sets the object's `disabled` flag instead. `DestroySubObject` destroys the assembly,
keeping and showing its damaged parts when its second argument asks for them. Destroying an engine
lowers the owner's share of engines left, and destroying a shield generator clears its
`shield_generator` flag.

`ship_damage_value` (`0x00452CB0`), the value ShotAt events carry, is the lowest of the object's
four armor values, or a component's own.

## The hit tests

`object_hit_test` (`0x0049BEF0`) walks an object's nodes with a test and a query. For a root node,
the object's or that of an object mounted on it, `node_hit_test` (`0x0049BD30`) hands the test the
object's bounding box, at the root's next place, and only where the test passes does the walk go on
into the root's children. For a part node it hands the test each box of the part's collision tree,
at the node's next place (`node_next_place`), from the root box down, going on into a box's children
only where the test passes, and then walks on into the node's own children, the roots of what the
part mounts, whatever the test said. A child that is hidden, or of flag `0x80`, the nodes the
attachment points make, is passed over with all it holds. The shots' candidates
(`bullet_candidate_test`), the shots' hits and the missiles' (`missile_hull_test`, `0x004959A0`)
and the collisions go through it.

For an object that lists components, `create_object` numbers its part nodes, its model's and those
of the models mounted on it, from the root down, depth first (`object_number_parts`, `0x00466BA0`):
each node's number goes at `+0xFC`, the count at `+0x154`, and a table of the nodes by number at
`+0x518`. A shot's candidates name its parts by these numbers; OpenReliant names a part by its model
and its index there (`objects.PartRef`), and walks the models mounted on a part after it.
