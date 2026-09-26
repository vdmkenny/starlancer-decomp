# The cloak

`cloak.cpp` hides a ship behind a shimmer while its hull fades from sight. Its asserting code runs
from `0x00462B80` to `0x00463773`. OpenReliant is
[`game/cloak.zig`](../../src/engine/game/cloak.zig), which also holds the
[countermeasures](missiles.md#countermeasures). **Unverified:** that `object_uncloak` (`0x00463780`)
to `cloak_node_cloaks` (`0x00463C30`), which lie after that code, and `cloak_node_reveal`
(`0x004629D0`), which lies before it among the countermeasures', are this file's.

## Which objects cloak

An object can cloak where its model's header has flag `0x02` ([`shp.md`](../formats/shp.md)). For
such a model, and for every ship type's model in a multiplayer mission, `model_load` builds two
more sets of meshes and gives each part colours of its own
([Meshes](rendering.md#meshes)):

- The see-through set: the part's own meshes, each group's first pass blended by alpha.
- The shimmer set (`cloak_mesh_build`, `0x004A3CB0`): one group over every polygon, added, lit
  under a hardware renderer, its texture `cloak64` with the model's prefix letter. The shimmer's
  object carries texture coordinates of its own, which the cloak turns each frame.

The part's own colours (`+0x110`, flag `0x80000`) start cleared and stay so until a hit shows the
hull through the cloak. The renderer takes them in place of the mesh's baked colours, so the static
lights such a model carries never show, which OpenReliant fixes
([Static lights](rendering.md#static-lights)).

Beside the ships that cloak, the models of the guns and the missile pods have the flag, and cloak
with the ship that carries them. On the Kafelnikof only seven parts cloak
(`kafelnikof_cloaking_parts`, `0x004E1998`, 20 bytes a name): `Kaf bot vent`, `Kaf comms twr`,
`Kaf ext vent`, `Kaf frnt vent`, `Kaf land plat`, `Kaf shield gen` and `Kaf top vent`
(`cloak_node_cloaks`).

## The cloak's record

`object_cloak` allocates `0x2C` bytes at `GameObject + 0x63C`, which stay until the cloak has gone.

| Off | Field |
|---|---|
| `0x00` | Whether it is going |
| `0x01` | Whether it is still coming on or going, which refuses a change of mind |
| `0x04` | The shimmer's strength, 0 to 1 |
| `0x08` | How solid the hull is, 0 to 1 |
| `0x0C` | The tick it began to come on |
| `0x10` | The tick it began to go |
| `0x14` | The tick a hit last showed the hull |
| `0x1C`, `0x20` | The ticks the shimmer was drawn at, the frame before and this one |
| `0x24`, `0x28` | The same for the hull |

## Coming on and going

`object_set_cloak` (`0x00463560`) cloaks or uncloaks an object whose model can cloak, where it isn't
already so, through `object_toggle_cloak` (`0x00463600`). For the player's ship it also sets the
display's cloak (`cloak_state`, [Devices](hud.md#the-devices)), whether or not the toggle went
through. Every ship whose current order is Launch from the object follows it.

`object_toggle_cloak` does nothing while the cloak is still coming on or going. Otherwise it
uncloaks a cloaked object and cloaks another:

- `object_cloak` (`0x00463640`) sets the object's flag `0x100`, makes the record, from now, and
  draws each part that cloaks see-through (`cloak_node_see_through`, `0x00462B80`) with a shimmer
  (`cloak_node_shimmer`, `0x00462EB0`) whose texture coordinates are random, 0 to 1. The object
  sounds `CLOAK01`, on the player's own voices for the player's ship.
- `object_uncloak` (`0x00463780`) marks the cloak going from now, and sounds `CLOAK01` the same way.

`cloak_frame` (`0x00463810`) runs in `mission_frame`'s pass that draws the objects, for each object
with a cloak, hidden or not. The ticks it has drawn the shimmer and the hull at move back a frame.
For 250 ticks from the start of the change, the shimmer's strength is the share of them gone, and
the hull's solidity the rest; going, the other way round. Once the cloak has come on, every part's
hull is clear and its shimmer whole, as 250 ticks since they were drawn would leave them. Once it
has gone, each part has its own meshes back, solid (`cloak_node_restore`, `0x00462D30`), and the
cloak is dropped.

`cloak_drop` (`0x00463420`) frees the parts' callbacks (`cloak_node_free`, `0x00463470`), clears
the flag and frees the record, leaving the parts as they are. An exploding ship's blast
(`0x0046C980`) and burst (`0x00471DB0`) drop its cloak first, and `object_free` drops what it has.

## What is drawn

The pass draws a cloaked object with its lights and engine glows out, its parts through two
per-object callbacks the mesh pipeline runs after culling and before lighting. A callback that
returns non-zero leaves its object undrawn.

The hull (`cloak_hull_callback`, `0x00463B90`) is left undrawn under the software renderer. Unless
the game is paused, or the part doesn't cloak, `cloak_hull_fade` (`0x004632F0`) runs for the ticks
since it was last drawn: while the hull is clear, what hits showed of it fades by 0.01 a tick;
otherwise its alpha is the hull's solidity. The see-through groups blend by the vertex alpha, which
is the object's colour's plus its own colours'.

The shimmer (`cloak_shimmer_callback`, `0x00463B20`) stands where its part does. Unless the game
is paused it is left undrawn while its strength is nothing, and on the Kafelnikof; otherwise
`cloak_shimmer_swirl` (`0x00463050`) turns each texture coordinate about (0, 0) by 0.008 a tick,
over its squared distance from there, for the ticks since it was last drawn, and gives every
vertex the shimmer's colour, unlit. The colour (`cloak_colour_at`, `0x004631E0`) eases by
`cosine_ease` from black to (185, 203, 82) / 256 as the strength reaches 0.3, then to
(0, 0, 80) / 256 at full strength. `cloak_init` (`0x00463500`) fills a table of 1024 of them
(`cloak_colours`, `0x0054142C`), which `cloak_colour` (`0x004632B0`) reads, and holds `cloak64` for
the mission (`cloak_texture`, `0x00541428`), which `cloak_free` (`0x00463550`) lets go.

In `mission_frame`'s pass before the camera's frame, a cloaked object other than the Kafelnikof
wobbles while its cloak changes (`cloak_wobble`, `0x004639B0`). With `t` the share of the 250
ticks gone, its frame is multiplied by three shears in turn, each `0.15 * sin(pi * t)` times
`sin(20 * t)`, `sin(26 * t + 2.8)` and `sin(14 * t + 0.9)`: of Y by X (`mat3_shear_x`,
`0x004C24F0`), of X by Y (`mat3_shear_y`, `0x004C2550`) and of X by Z (`mat3_shear_z`,
`0x004C25B0`).

## Hits

`cloak_reveal` (`0x00463AF0`) shows a cloaked object's hull where a hit strikes it. It sets the
record's hit tick, and `cloak_node_reveal` (`0x004629D0`) walks the parts that cloak: each vertex of
a part's drawn level within 1.123 times the object's radius of the point gains alpha in the part's
own colours of `(reach - distance) / (0.45 * radius)`, no more than 1 and up to 1 in all. On the
Kafelnikof a part goes by its mesh's smallest extent in place of the radius. What it shows then
fades as the hull is drawn.

- A shot spent on the shields (`bullet_hit`) shows it, and the shields don't flare.
- A shot on a component, but a Huge Gun's, shows it once the component takes its damage.
- The Nova Cannon's beam shows it on each part it strikes (`nova_strike_parts`).
- A shield flare (`shield_flare`, `0x0049F1E0`) on a cloaked ship shows it, and nothing more.

## Who cloaks

The player cloaks with CLOAK SHIP (`0x00413CB2`, once a press), outside view 13, on a ship whose
model can cloak: the ship uncloaks where it is cloaked and cloaks where it isn't
(`player_cloak_set`, `0x004153E0`). Unless the cloak is still coming on or going, the display
beeps (`hud_beep` 4 on, 5 off) and Betty says so (`0x10`, `0x11`). `player_cloak_set` does nothing
in a multiplayer game, nor where the display has no cloak. The ship also uncloaks:

- With FIRE LASERS held, in place of firing, outside a multiplayer game.
- With LAUNCH MISSILE, in place of the launch, once the armed missile's lock allows it, outside a
  multiplayer game; and as the Kamov lets go of the craft it carries.
- As the display's cloak runs out of charge ([Devices](hud.md#the-devices)).
- With EJECT ([Ejection](ejection.md#ejecting)), and as a player's ship jumps out (Jump Out,
  `0x00416D50`).

A ship flying the Fight order cloaks as its maneuver asks (`fight_update_cloak`, `0x00409EC0`): the
maneuver's `Cloak` command asks for the cloak 500 ticks on ([Maneuvers](maneuvers.md)), and a new
maneuver asks for none until it does. Each update after calling for help, a ship whose model can
cloak cloaks once that tick has come, and uncloaks while none is asked for. The mission's
`Cloak_ship` command (`cmd_Cloak_ship`, `0x00459F60`) cloaks or uncloaks a ship too.

## In OpenReliant

[`cloak.zig`](../../src/engine/game/cloak.zig) ports the cloak, with these differences:

- OpenReliant updates a part's shimmer and hull as it adds them to the scene, not after culling, so
  a part out of sight changes too.
- The display has no world to reach the ship through, so as the cloak's charge runs out OpenReliant
  marks it spent (`hud.State.uncloakSpent`), and the next frame's orders uncloak the ship, a frame
  late.
- **Improvement:** the shimmer's colour is worked out for its strength, not read from the table
  of 1024.
- **Improvement:** OpenReliant's shadows ([Shadows](../port/renderer.md#shadows)) fade with the
  hull: a cloaking part's see-through hull casts as strongly as it is solid, and none once it is
  clear. The ship the camera sits in isn't drawn, so its parts take the hull's solidity for their
  shadow alone (`cloak.shadeUnseen`).

Cloaking posts the ship's Cloaked event first, and uncloaking a ship with a cloak its Decloaked
([Script VM](script-vm.md#events)).

Not ported: the mission's `Cloak_ship`
([#36](https://github.com/vdmkenny/openreliant/issues/36)); the Jump Out order's uncloak
([#30](https://github.com/vdmkenny/openreliant/issues/30)); the Kamov's craft; and the multiplayer
game's cloak ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
