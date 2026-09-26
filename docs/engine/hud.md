# Head-up display

`C:\lancer\game\hud.cpp` holds the display drawn over the view: the panels, the gauges, the target display and the text. Its code lies between `hog_SND.CPP`'s and `hudmovie.cpp`'s, about 40KB of it; only `hud_init` asserts, so the source map places that stretch alone.

OpenReliant draws the readouts, the clock, the status lights with the devices' charges, the jump prompt, the player's target, the eject marker, the scanner, the ship status indicator, the targeting cluster, the radar's rings, the windows' frames and what the power distribution and the target display show ([`engine/game/hud.zig`](../../src/engine/game/hud.zig), [`engine/game/hud/windows.zig`](../../src/engine/game/hud/windows.zig)), reaching them as the engine does, through the overlay `srcore.render` runs after a frame's layers and before the scene ends.

## The elements

The display's elements as the game's manual names them, with where the code that draws each has been found. An element whose code is not found yet is marked so.

| Element | Where | Key | Shows | Code |
| --- | --- | --- | --- | --- |
| Targeting cluster | middle | | the reticle where the guns aim; speed on an arc to the left, the speed the throttle sets and the speed the ship is making; the weapons' charge on an arc to the right; an indicator pointing to the next nav point, and one pointing to the target, red for hostile and green for friendly | [The targeting cluster](#the-targeting-cluster): the arcs, the two markers with their figures, the fills and the reticle. The indicator for the target is the arrow `hud_target` draws for a target out of sight ([The target](#the-target)); the nav point's is drawn the same way and not ported ([#36](https://github.com/vdmkenny/openreliant/issues/36)) |
| Target ring | round the target | | a ring round a target in sight, red or green, with its range in metres under it; a lead cursor, a box with a line trailing from it, where to shoot | `hud_target` (`0x00489C70`): brackets at the corners of the target's box, its range in kilometres, and the lead cursor with its line ([The target](#the-target)) |
| Directional calipers | the display's edges | | the direction and range of a target out of sight | `hud_target`: a marker where a line toward the target leaves the screen, with the range ([The target](#the-target)) |
| Missile lock ring | round the target | | a ring that closes in round the target and turns white once a missile has locked, with a tone | `hud_missile_lock` (`0x00491520`), whose count dims the target's brackets as a lock builds ([The lock](missiles.md#the-lock)) |
| Jump icon | above the middle | J | the prompt to press JUMP DRIVE, once the mission has a jump ready | [The jump prompt](#the-jump-prompt-the-eject-marker-and-the-scanner) |
| Target display | foot, right | | the target's image with its shields and armour in a ring, its name, its type, its range and its speed; a larger form for a big target, with its current subtarget and a bar for each | [Windows](#the-windows) 3 and 8, [The target display](#the-target-display) |
| Subtarget | on the target's model | S, SHIFT+S | the parts of the subtarget picked out in red | `hud_subtarget` (`0x0048CC30`), which walks the target's assembly by `link_id` |
| Radar | foot, middle | V | three rings with the ship at their middle and a wedge for its view ahead; each object a dot, red for hostile, green for friendly, blue for one calling on the radio, on a line up or down from the rings by its height. V narrows and widens its range, the middle ring filling the display at the narrowest | `hud_radar` (`0x00488BD0`), [The radar](#the-radar). The rings and V's ranges are ported; the dots are not |
| Ship status | foot, left of middle | always shown | the ship's image in two rings of segments, forward, aft and the two sides: shields outside, armour inside. A shield dims as it wears; an armour segment goes as it is lost. Shifting power fore or aft doubles the shields there | `hud_ship_status` (`0x00489350`). For the player's own ship, what [SHIELD BALANCING](controls.md#the-shield-balance) shifted beyond the fore and aft shields shows as a second arc outside each: shapes `0xB2` less the level at `(-0x1A, -0x24)` from the point for the fore reserve, and `0xB7` less the level at `(-0x26, 0x1D)` for the aft one, the level worked out as for a shield. [The ship status indicator](#the-ship-status-indicator) |
| Missile display | top, middle | M | the missile's name, the ship's missiles in a ring, how many of the chosen one are left, and the one armed at six o'clock. Comma and full stop turn the ring | [Window](#the-windows) 2: the ring (`hud_missile_ring`, `0x00501CC8`, ten entries of five halfwords), its keys and what it shows ([The ring](missiles.md#the-ring)). LAUNCH MISSILE and the ring's keys open it held |
| Mission objectives | right | B | the mission's goals, the current one first; B pages through them | [Window](#the-windows) 10: the mission's objectives from the table at `0x00504120`, ten a mission. The frame is ported; what it shows is not |
| Gunnery display | foot, left | G | the gun's name, the ship as a wire frame with the gun lit, the rounds left for a gun that fires them, and whether the guns fire together or in turn. G picks the next gun, F fires them all, CTRL and G switches the two ways of firing them all | [Window](#the-windows) 1, [The gunnery display](#the-gunnery-display) |
| Damage display | top, right | D | a segmented bar each for the weapons, the engines and the shields, shortening with damage | [Window](#the-windows) 4, [The damage display](#the-damage-display) |
| Power distribution | left | P | the guns, the shields and the engines round a ball, each with its share of the power, a third each at first. P held with the stick moves power toward one; U, I and O give all of it to the guns, the engines or the shields, and `[` shares it out again | [Window](#the-windows) 7, [The power distribution](#the-power-distribution) |
| Communications | top, left | C | the units in range, numbered, which the number keys call. Landing, rearming and a nanny ship are asked of the base ship | [Window](#the-windows) 11, which draws the radio's menu with `0x00453A70`. The frame is ported; what it shows is not |
| Wing status | right | X | the fighters of the player's wing in a grid, the player first, each with a bar for its damage | [Window](#the-windows) 13, [The wing status](#the-wing-status) |
| Readouts | top, right of middle | | the seconds of afterburner fuel, the pilot's kills under a skull, and the countermeasures left | [The readouts](#the-readouts) |
| Status lights | top, left of middle | | the systems that are on: match speed, blind fire, smart targeting, which makes any ship fired on the target, reverse thrust, the spectral shields and the cloak with a bar for the time left, the ECM | [The status lights](#the-status-lights) |
| Clock | foot, middle, over the radar | | the time played | [`hud.zig`](../../src/engine/game/hud.zig) |

Each panel but the ship status is one of the display's [windows](#the-windows), which come and go as the game needs them; SHIFT with a panel's key holds it on.

## How it is reached

`hud_draw` (`0x004843B0`) draws the display once a frame. `mission_run` puts it in `sr + 0x88` and Surrender calls it while it renders, so no call reaches it in the listing and Ghidra does not find it without being told; `make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x004843b0"` does that. `hud_init` (`0x00483150`) sets the display up once, from the device reset at `0x004AD0A0` rather than per frame: it copies the element names into the table at `0x0057BC5C`, a hundred bytes each, allocates the file's work buffer, takes `oldpalette.tga` and `powerball.tga`, and works out the tables the [power ball](#the-power-distribution) is drawn from.

`mission_frame` itself calls only three of the file's routines: the windows' `hud_window_open` (`0x0048B510`) and `hud_window_close` (`0x0048B590`); the subtarget (`0x0048CC30`), which walks the target's assembly by `link_id`; and a utility (`0x0048CEB0`).

## Where an element stands

`hud_place` (`0x00482E90`) gives an element its place from a fraction of the screen, so the display keeps its layout at any resolution:

    x = round((screen_width  - 0x21) * across) + 0x10 + offset_x
    y = round((screen_height - 0x21) * down)   + 0x10 + offset_y

with the screen's size at `sr + 0x1666` and `sr + 0x166A`. Half of the way across comes to the middle of the screen, the inset and the margin cancelling. `hud_grid_place` (`0x00482F00`) places the item of an index in a grid from half-way across, `0x30` apart across and `0x26` down, two to a row, its first item `156` to the left.

The places move with the screen, but the shapes and the glyphs do not: the game draws them at their own size whatever the resolution, and the window it makes is 640 by 480 (`0x004A85BC`).

**Improvement:** OpenReliant draws the display as large against the window as it stood against a
1024 by 768 screen, a mode the hardware renderers run in and the size of the retail game's own
screenshots, by whichever side has room for less, so it keeps its shape. What the display measures
in its own pixels, the inset and the margin and an element's offset, is scaled with it; the fraction
of the window is not, so the display still reaches the edges of a window of any shape. At a scale of
1 the arithmetic is the game's own. Half of the way across then falls within a pixel or so of the
middle rather than exactly on it, the inset having grown. Since the offsets are fixed in pixels, the
screen chosen sets how far in the elements stand: at 640 by 480 the clock, 130 above the foot,
stands near two thirds of the way down, and at 1024 by 768 near four fifths.

## Text

`hud_text` (`0x00480E40`) draws a line through `VFX_string_draw`, left where its alignment is 0,
centred where it is 1 and right where it is 2; an empty string draws nothing. It leaves the line's
bounding box where the caller asks. `font_text_width` (`0x00480E10`) sums a string's widths out of
the cache `font_open` (`0x00480D70`) fills: a record of the font and a width for every code below
255, each taken from `VFX_character_width`.

`sprites.cpp` looks the drawing routines up out of `vfx.dll` by name into function pointers:
`VFX_string_draw` at `0x00594858`, `VFX_character_width` and `VFX_shape_draw_mirrored`.
`VFX_string_draw` draws each code with `VFX_character_draw` and moves along by what it returns, and
`VFX_character_draw` blits the glyph into a pane, clipped. The display is therefore drawn by the
processor into a buffer whichever renderer is running: `hud_draw` branches on `sr + 0x1AC` in six
places, but both sides reach the same `hud_text`.

A glyph's bytes are indices into the font's own palette. The shipped fonts run from those using its
first seventeen entries as levels of coverage, `FONT.FNT` and `ITACSML.FNT` among them, to
`BLUFONT.FNT` and `MED_RED.FNT` reaching past two hundred for glyphs of their own colours. A font
with no palette, as `SMLFONT.FNT`, draws with VFX's global palette, which `hud_draw` makes of the
display's set: its glyphs are all index `0xF7`, a pale tan there.

Every line of the display's own text is in `blufont.fnt` (`0x00595490`), orange despite its
name, which `0x004A2AF0` opens for the hardware renderers (`soft_blufont.fnt` for the software
one). The target's ranges are the exception ([The target](#the-target)).

`hud_text` hands `VFX_string_draw` a remap table as well, 256 bytes that the glyph's bytes go
through. `0x004A2AF0` builds them once, with the fonts it opens: most are each index itself, but
index 0, which is `0xFF`, and a few change an index or a range of them.

**Improvement:** the display is drawn over the finished frame, after the bloom, rather than into
it, so that nothing of it blooms. The game has no bloom to keep it out of; OpenReliant's is an
improvement over the scene alone. The device is told where the scene ends
(`device.Device.overlay`), and the GPU one draws what follows into the composed frame with
pipelines of a single sample. The software device adds nothing of its own and ignores the mark.

**Improvement:** OpenReliant draws a glyph as a textured rectangle through the device rather than
blitting it (`VFX_character_draw`), so on the GPU the display costs the processor nothing and scales
without blurring. What it draws is the same: the font's palette looked up for each byte, index 0
left clear, over the scene with the engine's own overlay-layer depth and alpha blend. The software
device draws the rectangles too, and `--original` draws the display the same way, since OpenReliant
draws the display larger on a larger window (`scaleFor`), where the game blitted it at its own size.

## Which views have it

`hud_draw` reads `camera_view_last` (`0x00539A64`) rather than the current view. The instruments
are drawn only while it is 0, the view ahead from the cockpit, in whichever cockpit mode: the chase
view the cockpit key cycles to is view 0 too, and has them all. The cockpit's own side and rear
views, 1 to 3, do not. In its order:

| Drawn | In |
| --- | --- |
| the launch's typed text, and a key's prompt | every view |
| the devices' charges, which run | every view |
| the jump prompt, the target, the radar, the eject marker, the scanner and the status lights | view 0 |
| the view's name, centred half of the way across and 10 down: the view table's string for it | every view but 0, and but the fly-bys, `0x24` to `0x26` |
| a string of `0x0057BF34`'s, `0x3C` above the foot, unless it is `0x90` | view `0xD` |
| the table of lines `0x0048CF20` draws, placed `(-110, -140)` from the middle | every view |
| the readouts, the ship status indicator, the targeting cluster's arcs and markers, the radar and the clock | view 0 |
| the reticle (`0xD7`) at the middle, and the blind fire sight (`0xD8`) that closes on a target | view 0, but not in the chase mode |
| in a multiplayer game, a shape of `dmicons.spr` for the player's power-up at the middle | view 0 |
| the panels the element state machine opens, sliding in and out | view 0 while they slide, every view once open |
| a line of text at the foot while `0x00529FB8` is set | every view |

The view's name is one of the strings `language_init` (`0x00490DC0`) reads out of `language.dll`
([`engine/game/language.zig`](../../src/engine/game/language.zig)): Cockpit View, Left View, Target
Camera, External Camera, Missile Camera and the like, or a single space for the chase views and
most cutaways. Its place is measured from the screen's edge rather than with `hud_place`.

OpenReliant draws the view's name, and in view 0 all it has ported of the rest. A mission's launch
ends in view 0 ([`camera.md`](camera.md)), and so does OpenReliant's start.

### The interference

`object_damage` (`0x00463EE0`) and `object_armor_damage` (`0x004641F0`), hitting the player's ship,
run `hud_interference_start` (`0x00494890`): `hud_interference` (`0x00588700`) goes to 0.3, and
sound 12 of the buffered sounds plays at the ship at a loudness of 10000 once more than 15 ticks
and a random share of 15 more have passed since the last (`0x00587CD0`). Once a frame
`screen_flash_draw` (`0x00494940`) shows the screen's flash sprite red at `hud_interference`, with
no green or blue, in view 0 unless `exhaust_burning` (`0x0054EA7C`) is set, while the player's ship
stands in a capital ship's engine exhaust and the flash shows white instead
([Effects](effects.md#engine-exhaust)), and then fades it by 0.005 for each tick since it last did
(`0x00588728`, `hud_interference_fade`, `0x004948F0`).

While it is above 0, the display draws much of what it shows through `hud_blit` (`0x0048C6E0`)
rather than `VFX_shape_draw`: under the hardware renderers each row of the shape moves right by a
random share of `10 * hit_shake` pixels (`0x004DC520`, `hit_shake` at `0x00588724`), or for a shape
flipped both ways of `10 * hud_interference`; the software renderer draws it still. Shaken this
way:

- in `hud_draw`, the status lights but reverse thrust, the readouts, the targeting cluster's arcs,
  and the reticle and blind fire's sight;
- the ship status indicator's schematic and its hits (`hud_ship_status`), the radar's rings
  (`hud_radar`);
- the windows' frames, and in `hud_window_draw` the gunnery display's shapes, the missile ring,
  the damage display's and the wing status's icons, the large target display's picture, and the
  radio window's pictures.

The rest, the bars, rules, brackets, markers and text among them, stand still.

**Fix:** while shaken, `hud_ship_status` draws the player's own schematic two pixels left and
two down of where it draws it still, apart from its hits. OpenReliant keeps it in place.

OpenReliant draws a shaken shape a row at a time (`hud.Shake`), a random number of the C runtime's
for each row, as the game does.

## The readouts

`hud_draw` puts three readouts in a row across the top of the screen, each a shape of the display's
set with a number centred `0x1E` below its point and across from it by as much as puts it under
the shape. All three stand half of the way across, at offsets of `0x39`, `0x5F` and `0x98`:

| Offset | Shape | Number | Shows |
| --- | --- | --- | --- |
| `0x39` | `0xCD`, a ship with its engines burning | `0x10` right | the seconds of afterburner fuel left: `afterburner_fuel`, which is in hundredths, over 100 |
| `0x5F` | `0xD0`, a skull and crossbones, drawn 4 left | `0x0B` right | `skull_count` (`0x00562DF4`), the pilot's kills over the campaign, which `kills_add` (`0x004B14F0`) counts as `explode_kill_credit` credits a kill: a hostile fighter, Kamov, Kurgan or Gurevich the player's ship struck last. The end of a mission the player comes through keeps it and promotes the pilot by it, at 0, 35, 72, 115, 150, 200, 255, 275 and 300 kills (`mission_end_record`, `0x00475A90`); the start of the next puts back what was kept, which undoes a failed attempt's kills. The end keeps them unless the player's ship was destroyed or the ejected pilot killed or captured (`mission_ending` 1 or 3). The kills of each mission are kept apart (`mission_kills`, `0x00562E64`). Each sandbox attempt ends and starts as a mission would |
| `0x98` | `0xCF`, a coil, drawn `0x1A` left | 9 left | the object's countermeasures left (`+0x5EC`), 29 when it is created, which `object_spend_countermeasure` (`0x00462550`) takes one at a time. It is drawn unless `ShowHudIcon` flashes icon 3 and the flash is dark |

OpenReliant draws all three ([`engine/game/hud.zig`](../../src/engine/game/hud.zig)).

## The targeting cluster

After the ship status indicator, `hud_draw` draws the cluster about the middle of the screen. Its
arcs stand a share of the screen's width from the middle, so they part as the screen widens; the
rest is in pixels:

| Drawn | Where |
| --- | --- |
| the right arc: shape `0x7F`, mirrored within its own bounds (`VFX_shape_draw_mirrored`) | `0.15625` of the width right of the middle, cut down to a whole number, less `0x43`, and `0x4A` above the middle |
| the left arc: shape `0x7F` | `0.15625` of the width left of the middle, and `0x4A` above it |
| the throttle's marker, shape `0xEA`, and the speed it asks, the top speed times the throttle, right-aligned 10 left of it and 8 above | on the circle below, at the throttle's size, to 1 |
| the speed's marker, shape `0xEA`, and the speed, right-aligned likewise | on the circle, at the speed over the top speed, to 1 |
| the speed arc's fill: shape `0xB8` lit below the speed's marker, `0xB9` unlit above it | 10 left of the left arc's point |
| the charge arc's fill: shape `0xF9` lit below the guns' charge, `0xF8` unlit above it | 14 right of the right arc's point |
| the radar | [The radar](#the-radar) |
| the reticle, shape `0xD7`, and blind fire's sight | the middle |

The markers ride a circle centred 100 right of the left arc's point and 80 below it, at 124 times
the sine and 94 times the cosine of an angle of 310 degrees at nothing and 210 at full. The
throttle's marker shows only while the throttle and the speed differ by more than 0.1 when
tripled; `hud_draw` makes the global palette that much dimmer for it, to full, and back to the
display's brightness after it.

A fill is two VFX panes a pixel above and left of where its shapes are drawn, `0x42` wide and down
to `0x89` below the arcs' top, whose edges `hud_draw` moves each frame: the lit shape is drawn
into the one from a pixel above the level to the foot and the unlit one into the one from a pixel
above the top to the level, so the row they share is unlit. The speed's level is its marker's
height; the charge's is `0x8A` less the guns' charge (`GameObject.gun_charge`, `+0x140`) times
`0x8A` over the most it holds (`ShipCombat.gun_energy`). For ship type `0x0B` or `0xFF`, the
Phoenix, with the guns not all firing and the chosen group's first gun of type 11, the Nova
Cannon, the level is the cannon's charge (`GameObject.nova_charge`, `+0x148`) times `0x8A`
instead, so the arc darkens as the cannon charges.

The reticle is drawn at the middle unless the cockpit mode is the chase view, and a second time:
at the middle when no lead cursor is drawn (`hud_target_x` is -1); on the lead cursor, bright
(`0xD8`), while blind fire aims at it, which it does for a target within `0x46` across and `0x32`
down of the middle while the ship carries blind fire, has it on, and has the guns not all firing
or only one group, unless the chosen group's first gun is of type 11; otherwise where blind fire's
sight stands (`hud_sight_x`, `hud_sight_y`), which glides back to the middle a pixel a tick and
rests within 2 of it, bright while the lead cursor stands within `0x10` of the middle. The
object's `blind_fire_aim` (`+0x674`) says whether blind fire aims, and the player's guns then aim
at the lead cursor's point (`hud_lead_point`, `0x0057C260`).

OpenReliant draws all of it, and aims the player's shots at the lead cursor's point
([Guns](guns.md#shots)).

### The chase view

In place of the reticle, the chase view shows objects in the scene, which `hud_init` builds with
`mesh_build_square` (`0x0044F000`): squares facing along Z, over the whole of their textures,
added to what is drawn, never culled and always drawn.

| Object | Size | Drawn |
| --- | --- | --- |
| `chase_sight_near` (`0x005799E4`) | 600 | at full strength |
| `chase_sight_far` (`0x00566780`) | 600 | by its own colours, half grey |
| `chase_blind_mark` (`0x00566784`) | 600 | by its own colours, white |
| `chase_target_pointer` (`0x0057BC58`) | 200, 400 below its middle | at full strength |
| `chase_nav_pointer` (`0x005667AC`) | 200, 400 below its middle | at full strength, `chasepointat` |

`camera_chase` stands the sight's squares 6000 and 12000 ahead of the player's ship, turned as it
is. In view 0 in the chase mode, `hud_missile_lock` gives the two squares `chasetarget2` while
`target_under_reticle` is set and blind fire doesn't aim, and `chasetarget` otherwise; while blind
fire aims, the mark stands 6000 from the ship toward `hud_lead_point`, turned as the ship is,
with `chasetarget2` where `target_under_reticle` is set and `chasetarget` where it is not. It
stands both pointers 6000 ahead, and adds all of them to the overlay, the mark only while blind
fire aims.

`hud_target` hides both pointers each frame. In the chase mode, for the target out of sight, and
for the nav point, it shows the pointer and turns it as the ship is and then about its nose by the
way's angle from straight up, going round to the right, and half a turn more (`chase_pointer_roll`,
`0x00566788`, worked out a quadrant at a time with `sr_atan`), with `chasepointat2` for a hostile
target and `chasepointat3` for the rest.

OpenReliant draws them (`hud.chase`). **Improvement:** it computes the pointer's angle with
`atan2`. Not ported: the nav point's pointer, which needs the nav points
([#36](https://github.com/vdmkenny/openreliant/issues/36)).

## The target

The player's target is the target of the player's Player Control order, wherever that order
stands on the stack (`player_control_entry`, `0x00402860`). `GameObject.nav_point` (`+0x720`) is
the nav point the display points to, not the target.

The display keeps a copy (`hud_shown_target`, `0x005799E8`, an order's entry of which only the
target's index and component are set). `hud_draw` first copies the target of the Player Control
order below the current order, or else the current order's, each frame, and a change of target
copies it at once (`hud_target_changed`, `0x0048C580`). It draws the target
(`hud_target_object`, `0x00569940`) while the player can aim at it (`order_target_valid`), and
outside a multiplayer game a friendly one that is cloaked too. A change of target also brings up
the target's form of the target display, held open, and closes the other: [window](#the-windows)
8, the large form, for a type whose combat stats' word at `+0x2C` is 1
(`ShipCombat.display`), most capital and support ships; window 3 for the rest. With no target it
closes both.

### Picking a target

`hud_target_keys` first finds the object under the reticle (`hud_under_reticle`, `0x00566664`): the
first other than the player's in front of the camera within `0x20` of the middle of the screen
either way. It then reads, in this order:

| Key | Does |
| --- | --- |
| TARGET TORPEDO | steps the target to the next hostile Russian torpedo, Kamov or Scimitar within 660000, twice `pick_range` (`0x00501CB4`); with none, leaves it be |
| TARGET NEAREST ENEMY, TARGET NEAREST FRIENDLY | from view 0 or the chase view, while the current order is Player Control: the nearest hostile ship neither exploding nor cloaked, or friendly one not exploding, within 660000 |
| SMART TARGET | flips `smart_targeting` |
| NEXT ENEMY TARGET, PREVIOUS ENEMY TARGET, NEXT FRIENDLY TARGET, PREVIOUS FRIENDLY TARGET | while the current order is Player Control: with neither form of the target display up and a target the player can aim at, brings up its form, held for NEXT ENEMY TARGET alone; otherwise steps the target (`player_target_cycle`, `0x004150D0`) |
| NEXT SUBTARGET, PREVIOUS SUBTARGET | while the current order is Player Control, steps the target's component (`player_subtarget_cycle`, `0x00414F90`) |
| TARGET UNDER RETICULE | makes the object under the reticle the target of the current order, while that is Player Control, and brings up its form of the target display |

The next and previous target and subtarget keys stop MATCH SPEED, but for PREVIOUS FRIENDLY
TARGET.

`player_target_cycle` steps round the objects, the last to the first, to the next that the player
can aim at, not the player's own ship, one ejected from included and, for a friendly one, one
cloaked: a hostile one within 660000 for the enemy keys, a friendly one for the friendly keys. The
component goes. With none to be found the player is left without a target.
`player_subtarget_cycle` first gives both forms of the target display their full time again. For a
target that lists components and is not friendly, it opens the target's form if it is shut and
steps the component round to the next that is targetable and not hidden, or to none.

PRIMARY TARGET (`frame_controls`) makes the mission's primary target (`primary_target`,
`0x005883DC`) the player's, which needs the mission's script; it is not ported yet
([#36](https://github.com/vdmkenny/openreliant/issues/36)).

Smart targeting answers the player's hits. A blow of the player's ship, except by colliding, to an
object's shields makes the object the player's target (`object_damage`). One to its armour makes
it the target of the current order (`object_armor_damage`), and a hit on that target's armour
brings up its form of the target display. A hit on a component of a hostile ship makes the
component the subtarget, where the ship lists it, or else the ship the target
(`component_damage`).

### Drawing it

`hud_target` (`0x00489C70`), which `hud_draw` runs in view 0 between the jump prompt and the eject
marker, draws the target. Where its node (`ai_target_node`: the component's for a subtarget) stands
off the screen or behind the camera:

- an arrow from the middle of the screen, pointing the way to the node in the player's ship's
  frame (`hud_pointer_direction`, `0x00489BC0`): three lines, the tip 32 from the middle and the
  wings 22 from it and 4 either side, in palette entry `0x26`, red, for a hostile target and
  `0x62`, green, for the rest. The chase view draws none, and shows a pointer in the scene instead
  ([The chase view](#the-chase-view));
- a marker where a line from the arrow out the target's way leaves the screen (`line_clip`,
  `0x004AAFC0`), one of shapes `0x16C` to `0x16F` for a hostile target and `0x170` to `0x173` for
  the rest, for the bottom, the left, the right and the top, with the range in kilometres beside
  it in `smlfont.fnt`.

On the screen:

- brackets, shapes `0x122` to `0x125`, or `0x126` to `0x129` for a hostile target, at the corners
  of the rectangle the camera sees its box in: the component's box for a subtarget, the object's
  bounds otherwise, turned as the node is. They stand at least 15 apart either way. The missile
  lock's count (`missile_lock_count`, `0x0057DFBC`), 100 while no lock builds, dims them to its
  hundredths, and at a tenth or less leaves them out;
- the range, `%dk` of the distance over 1000, right-aligned 10 right of the bottom right bracket
  and 9 below it, in `newfont.fnt`;
- for a target that lists no components and is not friendly, the lead cursor, shape `0x12F`, at
  the point `ai_lead_aim` aims the player's guns at, which is `hud_target_x` and `hud_target_y`,
  and a line in entry `0x26` from 5 out of it, along the axis the target lies farther on, toward
  the target, shorter by 0.28 for each unit the lock's count is short of 100.

The range in the game is the text of the tables `0x004A2AF0` builds: `friendly_text_colours`,
`hostile_text_colours` and `neutral_text_colours` by the target's side, which change only index
`0xF7`, and `text_colours` for the marker's. `newfont.fnt` uses none of `0xF7`, so the range by
the brackets is the font's own orange for every side; `smlfont.fnt`'s glyphs are all `0xF7`.

**Improvement:** the game clips the line that places the marker at the screen's edge from the
arrow's tip across, but from the tip of one of the arrow's wings across again for down: a slip
that starts the line as far down the screen as its middle is across, so the marker stands lower
on the side edges than the target lies, and the more the wider the window. OpenReliant starts the
line at the arrow's tip. `--original` starts it where the game does.

Not ported: the corners `hud_comms_marker` (`0x0048B0F0`) marks on the object the radio's window
names; the pointer to the nav point; the players' names over their ships in a multiplayer game;
and what `hud_target_keys` does while the radio's window is open, or while `0x00529FB8` is set,
which leaves out every key after the search under the reticle. The keys' sounds are in
[The display's sounds](#the-displays-sounds).

## The ship status indicator

`hud_ship_status` (`0x00489350`) draws a ship's schematic, its type's own sprite's first shape
(`type_data`), with the quadrants hits have worn flashing on it, and round it the ship's shields and
armour as two rings of four arcs, the shields outside. Each arc is five shapes, drawn by its level:
the shields' `0x99` to `0xAC`, the armour's `0x85` to `0x98`. A level is the quadrant's shield over
the ship's `shield_power`, or its armour over its `armor_class`, cut down to a whole number, less
one; an arc of 0 or less is left out. An invulnerable ship's armour levels are each
`(2 * level + 6) / 3`, which leaves at least two arcs of it. A comms relay and a deathmatch beacon
have no rings.

`object_armor_damage` marks the quadrant each hit on the armour wears: `ship_status_hits`
(`0x00563160`) for the player's own ship, `target_status_hits` (`0x005635D4`) for the target of its
current order. The indicator draws a marked quadrant once, as shape 1 to 4 of the schematic, and
clears the mark.

| Mode | Draws | From |
| --- | --- | --- |
| 0 | the player's own ship: the schematic; the hits, for a type of the target display's small form; the shields, what [SHIELD BALANCING](controls.md#the-shield-balance) shifted beyond the fore and aft shields (shapes `0xB2` and `0xB7` less the level, at `(-0x1A, -0x24)` and `(-0x26, 0x1D)`), then the armour | 0.3 of the way across the screen, at the foot, 2 right and 44 up; the schematic and the hits at `(-0x22, -0x1B)` from there |
| 1 | the target, in the target display's small form: for a type of the small form, the schematic and the hits, mirrored across unless the type is hostile, where a comms relay or a deathmatch beacon leaves out the hits; the shields and the armour mirrored across, the left arcs the player's right ones and on the left | `(-4, -0x2C)` from window 3's place; the schematic at `(-0x1C, -0x1A)` and the hits at `(-0x1E, -0x1B)` from there |

In mode 1 a stand-in target closes window 3. **Not ported:** in mission 25, a Kamov's schematic
drawn mirrored in mode 0.

## The target display

Windows 3 and 8 are the target display's small and large forms (`hud_window_draw`'s cases for
them, at `0x00487B72` and `0x004875C0`), which a change of target brings up
([The target](#the-target)). Each draws nothing but its frame while there is no target to draw.
All of their text is in the display's font.

| Form | Draws, from the window's place |
| --- | --- |
| Small, window 3 | the target's ship status, mode 1, at `(-4, -0x2C)`; its type's name at `(0x37, -0x43)`; its pilot's name, for a named pilot, at `(0x37, -0x37)`; its range, `%dk`, at `(0x37, -0x2B)`; its speed, `%d kps`, at `(0x37, -0x1F)`; all left-aligned. A cloaked hostile target closes it |
| Large, window 8 | the type's own picture, its sprite's first shape, at `(-0xD0, -0x80)`; its name, right-aligned at `(-2, -0x9D)`; the subtarget; the hull's bar; the range and the speed, right-aligned at `(-3, -0x1D)` and `(-3, -0x11)` |

The large form's subtarget is the component the player's current order names, for any type but
a proximity mine or a black box, where the target lists it and its part's class has an icon: the
class's name at `(-0x78, -0x33)`, its icon at `(-0xBA, -0x34)`, and for a part with armour a bar,
shape `0xDE` at `(-0xC6, -0x32)`, darkened from the top by shape `0xDB` over as many of its 38 rows
as the part's armour has lost of its first, rounded.

| Class | Icon | Name |
| --- | --- | --- |
| 3, 9 | `0x18C` | Laser Turret |
| 5 | `0x18A` | Engine |
| 6 | `0x192` | Shield Generator |
| 7 | `0x189` | Comms Transmitter |
| 8 | `0x18B` | Gravity Drive |
| 10 | `0x18D` | Missile Turret |
| 11 | `0x18E` | Power Core |
| 12 to 14 | `0x18F` to `0x191` | Satellite Dish, Service Door, Shaft |
| 15 to 22 | `0x193` to `0x19A` | Surface Building, Twin Power Cores, Vent Hatch, Ion Cannon, Armored Plate, Cap Gun, Warp Projector, Fuel Pod |

The hull's bar, shape `0xDC` with its top at `(-6, -0x7E)`, 98 rows, is lit from the foot as far as
the first of the ship's own parts that is hull and has armour keeps its armour (every part node
stays in its root's child list, whatever part it is linked to); for a torpedo, as far as its weakest
armour quadrant is from six times its armour class. Shape `0xDB` darkens the rest from the top, its
pane's top row `-0x75`, or `-0x78` for a torpedo. Each bar is cut to a pane four pixels wide
(`hud_bar_pane`, `0x0057BDFC`). A ship with neither has no bar.

As a form closes, `hud_window_close` draws what it shows once more into `hud_window_picture`
(`0x00566600`), for the target and subtarget it last drew (`hud_display_target`, `0x0057BF40`, and
`hud_display_component`, `0x0056992C`), and the window closes with that.

**Improvement:** the game keeps one picture for both forms and draws it as the form starts closing,
with the display's new target for the range, the name and the rest. OpenReliant keeps what each form
last showed and closes it with that.

**Not ported:** the pilot's name, which a mission gives (`GameObject.pilot_record`); and in a
multiplayer game the players' names and one more line of the small form.

## The radar

`hud_radar` (`0x00488BD0`) draws a contact for the display's nav point and for each object but
the display's own ship that is targetable and not exploding, disabled, ejected or a cloaked
hostile, within the reach of the range (`radar_range`, `0x0057BE00`, 0 to 2). It places each by
the object's offset in the ship's frame, times the range's scale and 66 across, 43 ahead as up the
screen, and 30 for the height, which lowers the dot for an object below the ship and raises it for
one above; the dot stays off the screen's last row. A contact is its dot's shape, 2 right of the
dot, and a line of pixels a pixel right of it to the rings' plane:

| Contact | Line | Shape |
| --- | --- | --- |
| the target of the player's current order | `0xFF` | `0x130` |
| the object the radio's window names, while it is open | `0xFD` | `0xE6` |
| a hostile object | `0x26` | `0xE5` |
| any other | `0x62` | `0xE4` |
| the nav point | a cross of four pixels round the dot, in the palette's nearest white | |

It draws the contacts level with the plane or below it first, then the rings, `hud_radar_rings`
(`0x0057BC50`), one of shapes `0x161` to `0x16B` with the wedge of the view ahead, `0x42` left and
`0x20` above a point placed half of the way across, at the foot of the screen, 1 right and 51 up,
then the contacts above it. The clock stands 79 above the radar's point.

| Range | Reach (`0x00501CA8`) | A pixel is (`0x00501CB8`) | Rings |
| --- | --- | --- | --- |
| 0, the closest | 90000 | a 150000th | `0x161`, one ring |
| 1 | 150000 | a 230000th | `0x166`, two |
| 2, the widest | 230000 | a 330000th | `0x16B`, three |

The game draws the nav point's cross before or after the rings by what an earlier frame left in
its entry of the list (`radar_contacts`, `0x005667B8`), which it does not fill for the nav point;
OpenReliant draws it after them.

`hud_init` starts the radar on range 2. RADAR RANGES (`frame_controls`, `0x00414060`), in the view
ahead from the cockpit with the rings still, moves it to the next range, round from 2 to 0, and
starts the rings moving to that range's: `0x00569714` is set while they move, `0x005799B4` holds
the shape they stop at, and `0x005656AC` whether they step down toward it, which they do only to
range 0. `hud_radar_zoom` (`0x004892F0`), which `hud_draw` runs after the radar, steps them a shape.
It steps while `game_ticks` is short of the tick at `0x005656A0`, which RADAR RANGES and each step
put 50 ahead of it, so the rings step once each frame the radar is drawn, and never wait the 50
ticks.

In the cockpit's view the radar stands on a dark backing, which `mission_frame` draws with the
cockpit's model rather than `hud_radar` ([`rendering.md`](rendering.md#the-cockpit)).

OpenReliant draws the rings, the contacts and changes the range. Not yet ported: the radio's
object, which the radio's window names.

## The status lights

Inside the block it draws only for the view ahead, `hud_draw` packs up to nine lights into the
grid, each shown only while its own condition holds. The index it hands `hud_grid_place` is a
running count that advances for each light whose condition holds, so one that is out takes no
place and those after it close up. A flashing light keeps its place while it is dark.

In the order it draws them:

| Shape | Light | Shown while |
| --- | --- | --- |
| `0xCC` | match speed | `matching_speed` |
| `0xCB` | blind fire | the ship carries blind fire (`blind_fire_fitted`, `0x00566F8C`), `blind_fire` (`0x00579990`) is on, and the guns are not all firing (`GunMode.all`, the object's word at `+0x144`) |
| `0xC5` | smart targeting | `smart_targeting` (`0x0056996C`), which SMART TARGET flips, or icon 4 |
| `0xC3` | enemy lock | `enemy_lock` (`0x00579988`) with no missile homing on the ship, or icon 0. It flashes for 50 ticks of every 100, and a warning sound loops while it is shown ([The display's sounds](#the-displays-sounds)) |
| `0xC4` | missile incoming | the object's `missile_homing` (`+0x64C`), or icon 1. It flashes for 25 ticks of every 50, on the lock warning's count (`0x0057BC44`) |
| `0xC6` | ECM | `ecm_state` (`0x0057BF4C`) is 1, or icon 2, with a bar for its charge `0x23` below |
| `0xC7` | cloak | the ship carries a cloak (`cloak_state`, `0x00566638`, not -1), on or off, with a bar for its charge `0x20` below. Never in a multiplayer game |
| `0xCA` | spectral shields | `spectral_shields_state` (`0x0057BF20`) is 1, with a bar for their charge `0x20` below |
| `0xC8` | reverse thrust | the object's `reverse_thrust` |

An icon is one of `ShowHudIcon`'s (mission command `0x5B`, `cmd_ShowHudIcon`): it sets an icon of a
table of twenty (`hud_icons`, `0x00566558`) off, on or flashing, and `hud_icon_lit` (`0x00482F50`)
says whether one is lit this frame. A flashing icon is lit for the first 50 ticks of every 100; one
that runs past 100 carries what it ran over into the next hundred, lit. `hud_draw` asks only when
the light's own condition does not already hold, so an icon's flash stands still while it does. The
display reads icons 0 to 5: 3 is the countermeasures readout, 5 the eject marker.

`enemy_lock` is set by `mission_frame` each frame, in its pass that draws the objects, when a ship
whose order is Fight, against the player, has its missile ready (byte `0x2F` of its fight state,
which `fight_fire` sets once its lock on its target is complete:
[Missiles](missiles.md#the-ais-missiles)). `missile_homing` is zeroed on every object by
`mission_frame` and set by `missiles_update` (`0x004960F0`) on the object a live missile homes on.

A bar is a line of `hud_colour(0xE7, 0x68, 0x00)` drawn with `VFX_line_draw` from one pixel right of
the light's point to the charge times a scale further: `1/62` for the ECM, `1/312` for the cloak and
`1/187` for the spectral shields, so a full bar is about 32 pixels, rounded as `0x004C3330` rounds.

OpenReliant draws all nine by these conditions.

## The devices

Three devices run off a charge in ticks, which `hud_draw` keeps in every view: charging a tick a
tick while off, up to full, and draining while on. One that runs dry is turned off.

| Device | State | Charge | Full | Drains a tick |
| --- | --- | --- | --- | --- |
| ECM | `ecm_state` (`0x0057BF4C`) | `ecm_charge` (`0x005665F8`) | 2000 | 1 |
| Cloak | `cloak_state` (`0x00566638`) | `cloak_charge` (`0x0056663C`) | 10000 | 1, outside a multiplayer game |
| Spectral shields | `spectral_shields_state` (`0x0057BF20`) | `spectral_shields_charge` (`0x00566620`) | 6000 | 6 |

A state is -1 for a ship that does not carry the device, 0 for off and 1 for on. `hud_init` sets all
three to 0 and full, and turns blind fire on. The mission's start (`0x004934F0`) then fits the
player's ship by its type: every ship carries an ECM; the Nagi, the Crusader, the Tempest and the
Shroud carry spectral shields; the Predator, the Coyote, the Patriot, the Reaper, the Shroud and the
Phoenix carry blind fire, which starts on; a ship whose model can cloak (header flag 2) carries a
cloak. Ship types `0xF4` to `0xFF`, whose models are the first twelve's `t_` twins, count as the
same twelve. The same switch picks the cockpit's frame model
([`main.zig`](../../src/engine/game/main.zig)).

`frame_controls` reads the device keys after the camera's and the targeting keys
(`hud_target_keys`, `0x0048B6B0`, where SMART TARGET flips `smart_targeting`):

- TOGGLE BLINDFIRE flips `blind_fire` on a ship that carries it, and Betty says which.
- ECM turns the ECM the other way from the object's flag `0x4000000` through `player_ecm_set`
  (`0x00415370`), which sets the flag and `ecm_state`.
- SPECTRAL SHIELDS, outside a multiplayer game, does the same through
  `player_spectral_shields_set` (`0x00415430`) and flag `0x8000000`. Turning the shields on also
  tunes them, into the object's `+0x670`, to the gun type most dangerous near the ship: it counts
  the guns of each hostile ship in range, weights each type's count by its shield damage, and
  takes the highest, leaving out types 13 and 14. Betty says which.
- CLOAK SHIP is read by `player_controls`; `player_cloak_set` (`0x004153E0`) cloaks or uncloaks the
  ship through `object_set_cloak`, which sets `cloak_state` for the player
  ([The cloak](cloak.md#who-cloaks)). The cloak running dry uncloaks the ship the same way.

Ported: the charges, the fitting, SMART TARGET, TOGGLE BLINDFIRE, ECM, SPECTRAL SHIELDS and CLOAK
SHIP ([`input.zig`](../../src/engine/input.zig)), with their sounds ([The display's
sounds](#the-displays-sounds)). OpenReliant uncloaks the ship a frame after the cloak runs dry ([In
OpenReliant](cloak.md#in-openreliant)). Not yet: the tuning of the spectral shields.

## The display's sounds

`hud_beep` (`0x0048CE70`) plays the display's sound n, sample 15 + n of `bank_stdsmp` at a volume
of 60 in the middle (`0x00501C78`), in the four cockpit views only:

| n | Played by |
| --- | --- |
| 0 | Most keys: COMMS WINDOW, WING STATUS WINDOW, GUNNERY WINDOW, DAMAGE WINDOW, FULL GUNS on a ship of more than one group, OBJECTIVES WINDOW, RADAR RANGES as the radar moves, the power keys, SHIELD BALANCING and POWERBALL WINDOW as they are first held, MISSILE WINDOW, PRIMARY TARGET; a targeting key that does what it is for; a countermeasure spent |
| 1 | A window starting to open (`hud_window_open`) |
| 2 | A window starting to close (`hud_window_close`), however it closes |
| 3 | A key that finds nothing: TARGET TORPEDO without the player's controls, a nearest target key finding no ship, a next or previous target key finding none, a subtarget key without a target listing components that is not friendly, TARGET UNDER RETICULE with nothing to aim at, MATCH SPEED turning on with no target, PRIMARY TARGET with none, a turn of the missile ring that can't turn, no countermeasure left |
| 4 | A device turning on: SMART TARGET, SYNCHRONISE GUNS, ECM, SPECTRAL SHIELDS, MATCH SPEED, CLOAK SHIP |
| 5 | A device turning off, the same keys |

The locked forms of the window keys play none of their own. Betty says which way TOGGLE BLINDFIRE
turns blind fire, sounds `0x12` and `0x13` of `bank_betty`, SPECTRAL SHIELDS the spectral shields,
`0x14` and `0x15`, and CLOAK SHIP the cloak, `0x10` and `0x11`.

While the enemy lock's light shows, `hud_draw` plays `bank_stdsmp`'s sound 0 on voice 1 at a volume
of 60, looped, and plays it again whenever voice 1 has finished or was stopped; the voice is kept
at `enemy_lock_voice` (`0x0057BF50`). Once the light is out and no missile homes on the ship, it
ends the voice if it is still playing.

OpenReliant queues the windows' sounds as they open and close, and plays them later in the same
frame (`hud.Beeps`).

**Fix:** the game plays a power key's sound every frame the key is held, a new sound each frame;
OpenReliant plays it as the key is pressed.

**Fix:** the game runs the enemy lock's warning only in the view ahead, as it draws the lights, so
a warning playing as the view changes loops until the player looks ahead again. OpenReliant runs it
in every view, the light counting as out in the others.

Not yet ported: PRIMARY TARGET ([#98](https://github.com/vdmkenny/openreliant/issues/98)) and the
radio's menu ([#99](https://github.com/vdmkenny/openreliant/issues/99)), with their sounds.

## The jump prompt, the eject marker and the scanner

The block for the view ahead draws three more shapes about the middle of the screen, each placed
half of the way across and down:

- `hud_jump_prompt` (`0x00482FA0`), at an offset of `(-16, -90)`: while `warp_ready`
  (`0x0052A3F4`) says a warp is ready, the warp icon `0xC9` flashes; otherwise while `jump_ready`
  (`0x0052A3F0`) says a jump is, the jump icon `0xCE`. The mission sets one to 1; the prompt's
  first frame starts its flash and sets it to 2, drawing nothing; then it flashes for 50 ticks of
  every 100. JUMP DRIVE (`player_jump`, `0x00412B20`) clears it and posts `player_ready_to_jump`
  or `player_ready_to_warp`.
- `hud_eject_marker` (`0x004830B0`), at `(-16, -100)` and `0x26` lower: once the player has ejected
  (`player_ejected`, `0x00579986`, which `order_eject_player_init` sets) or while icon 5 is lit,
  shape `0xC2`, the pilot rising out of the ship, flashes for 50 ticks of every 100.
- `hud_scanner` (`0x00489250`), at `(-16, -100)`: while the `Scanner` mission command
  (`cmd_Scanner`) has `scanner_object` (`0x0057E060`) name an object, shapes `0xD1` to `0xD5`, a
  hand and the rings it sends out, in turn, moving on once `game_ticks` is past a tick 25 on from
  the last move. `mission_frame` beeps meanwhile at an interval of 10 to 200 ticks that it works out
  from the object's distance and bearing.

OpenReliant draws all three, the jump prompt by the mission script's variables (`vm.Variables`).
Mission 0 readies no jump and scans nothing.

## Art

`hud_init` loads the display's shapes into `hud_shapes` (`0x005656A8`): `hudhard.spr` under the
hardware renderers and `hudsoft.spr` under the software one, which `sr + 0x1AC` picks, and
`dmicons.spr` or `soft_dmicons.spr` into `0x0057BC3C`. `HUDHARD.SPR` holds 388 shapes, 2 palettes
and 21 remap tables: radar rings, bar gauges, arcs, target boxes, ammunition, and the silhouettes
the target display shows. `hud_init` hands `VFX_shape_multilookaside` 29 tables of 256 bytes from
the start of block 0, where the remap tables begin, though the set holds 21. In a multiplayer game
`hud_draw` draws a shape of `dmicons.spr` at the middle of the screen for the deathmatch power-up
the player holds (`power_up`, `+0x754`), flashing for the first 100 ticks after it was handed out
(`power_up_since`, `+0x760`) and gone once `frame_start` passes when it runs out (`power_up_until`,
`+0x75C`).

A shape's entry in its set names a palette or none (`VFX_shape_draw` in `winvfx16.dll`); one with
none is drawn with VFX's global palette. Under the hardware renderers `hud_draw` makes that of
block `0x77` of the display's set, its first palette, every frame (`palette_to_vfx`,
`0x00428410`), at `hud_brightness` (`0x00569718`), which `hud_init` sets to 1 and nothing changes.
No entry of a shipped set names a palette ([`spr.md`](../formats/spr.md)), so every shape of the
display is drawn with block `0x77`'s palette, those after the set's second palette, block 247,
included, and the ships' schematics, whose sets carry none, too. Nothing in the display makes
another block the global palette. OpenReliant does the same.

The element names `hud_init` copies come from `0x00515D70`, which the decrypted dump holds as
zeroes, so they are not readable from it.

## The windows

The display's panels are windows, fifteen records 40 bytes apart from `0x00501D30`: the window's
phase (`+0x00`), where it stands as a fraction of the screen across and down (`+0x04`, `+0x08`),
the pieces of its frame (`+0x0C` their count, from `+0x0E` their numbers), the ticks left before it
closes (`+0x18`), the ticks it stays (`+0x1C`), how far it has opened (`+0x20`) and whether it is
held open (`+0x24`). A mission's script opens a window with `OpenInstrument` (command `0x40`),
held open, and closes it with `CloseInstrument` (`0x41`); opening the objectives closes the wing
status window where it is up, and opening the radio's menu starts it afresh (`comms_menu_run`, not
ported, [#99](https://github.com/vdmkenny/openreliant/issues/99)). **Unknown:** the byte after the
hold (`+0x25`), which both clear.

| Window | Place | Stays | Shows |
| --- | --- | --- | --- |
| 0 | top, left | 400 | **Unverified:** the face of whoever speaks on the radio, from the mission's films, with a caption; it closes when the film ends |
| 1 | foot, left | 1200 | the gunnery display |
| 2 | top, middle | 200 | the missile display |
| 3 | foot, `0.7` across | 2000 | the target display's small form |
| 4 | top, right | 1000 | the damage display |
| 5, 6, 12 | top, left | 200, 200, 1000 | its frame alone; no key opens them |
| 7 | left, middle | 1000 | the power distribution |
| 8 | foot, right | 2000 | the target display's large form |
| 9 | right, middle | 1000 | its frame alone; no key opens it |
| 10 | right, middle | 1000 | the mission objectives |
| 11 | top, left | 1500 | the communications menu |
| 13 | right, middle | 1000 | the wing status |
| 14 | top, left | 2000 | **Unknown:** what it shows |

The phases are 0 shut, 1 opening, 2 closing and 3 open.

- `hud_window_open` (`0x0048B510`) gives a window its full time to stay and, if it is shut, starts
  it opening, not held. It does so whatever the phase, so a window that is closing carries on
  closing. In a multiplayer game windows 2, 9 and 10 do not open.
- `hud_window_close` (`0x0048B590`) starts a window that is open or opening closing, from its full
  size however far it had opened, and lets go of it. For windows 3 and 8 it also draws what they
  show into a second pane, `0x00566600`, which they close with.

`hud_draw` runs every window in every view, after the instruments (`0x004863F3`):

1. An opening window moves on by the frame's ticks, and at 60 is open; a closing one moves back,
   and at 0 is shut.
2. An opening or closing window is drawn, in the view ahead only, into a pane of 225 by 170
   (`0x0057998C`), its place a pixel in from the pane's edge its place is at, from the table at
   `0x00501F88`. `VFX_buffer_transform` then draws the pane onto the display scaled about that
   place, `2 - t` times its size with `t` the ticks it has opened over 60, and with the place
   `2 - t` times as far from the middle of the screen as its own. A window therefore opens shrinking
   from twice its size into place from twice as far out, and closes the other way; what falls
   outside the pane is cut off meanwhile.
3. An open window counts its time down by the frame's ticks, and once its time has run out and
   nothing holds it, starts closing. It is drawn in its place (`hud_window_draw`, `0x00486830`)
   that frame whichever it did.

`hud_window_draw` draws the window's frame in the view ahead, then what it shows. A frame is one or
two of the pieces at `0x00502078`, 20 bytes each: a shape of the display's set, drawn at an offset
from the window's place, the record's floats cut down to whole numbers, and a mode for
`VFX_shape_draw_mirrored` at `+0x0E`, 1 flipping it across, 2 down. The pieces are dark red
grids, the walls of the corner or edge the window stands in.

In mission 25, until `0x00587CDC` is set, windows 1, 2 and 13 neither move on nor are drawn.

The keys, which `frame_controls` and `hud_target_keys` read:

| Key | Does |
| --- | --- |
| COMMS WINDOW | opens window 11 held, and starts the radio's menu; pressed once it is open, closes it. Read only while the player's order is Player Control |
| WING STATUS WINDOW | closes window 10, then opens window 13, or closes it if it is up. The locked form holds it open as it opens it |
| GUNNERY WINDOW | opens window 1, and turns to the next group of guns, or out of firing them all ([The gunnery display](#the-gunnery-display)) |
| GUNNERY WINDOW LOCKED | opens window 1 held, or closes it once it is open |
| SYNCHRONISE GUNS | opens window 1, and flips whether the guns fire together |
| DAMAGE WINDOW | opens window 4, or closes it if it is up. The locked form holds it open as it opens it |
| FULL GUNS | with more than one group of guns, flips firing them all and opens window 1, held with SHIFT down |
| OBJECTIVES WINDOW | closes window 13, then opens window 10, or once it is open pages through the objectives |
| FULL POWER TO GUNNERY, ENGINES, SHIELDS, EQUALIZE POWER | while window 11 is shut, held, give the power its shares and open window 7 |
| POWERBALL WINDOW | held, keeps window 7 open, and sets `0x0051CEF8` |
| POWERBALL WINDOW LOCKED | opens window 7 held, or closes it once it is open |
| MISSILE WINDOW | opens window 2 held, or closes it once it is open |
| ROTATE MISSILES CLOCKWISE, ANTICLOCKWISE | outside a multiplayer game, open window 2 held and turn the ring |

The rest of the game opens windows too: firing the guns and launching a missile, the targeting keys
and a change of target the target display ([The target](#the-target)), and the radio its own. A
mission's script opens and closes any window by its number, `OpenInstrument` and `CloseInstrument`
(`0x0045D9D0`, `0x0045DA30`): a window it opens is held, window 11 starts the radio's menu too, and
window 10 closes window 13 first; one it closes is let go of. The display sounds as a window opens
and as it closes ([The display's sounds](#the-displays-sounds)).

## The gunnery display

Window 1 shows the player's guns, drawn by `hud_window_draw` in the view ahead from the window's
place `(x, y)`. The mission's start picks the ship's wire frame by its type, `gunnery_wire_frame`
(`0x005883C0`); a ship with none shows nothing. The shapes after the wire frame light each group of
guns on it, the first group's next.

1. The wire frame at `(x + 11, y - 134)`.
2. Firing one group:
   - its first gun's name, strings `0x3A9` to `0x3B3` from the Laser Cannon to the Nova Cannon, at
     `(x + 1, y - 157)`;
   - with more than one group, the chosen group lit;
   - for a pair of guns but the Nova Cannons, whether they fire together, shape `0xF0`, or in
     turn, `0xF1`, at `(x + 1, y - 139)`. The game takes the gun mode's bits from `synchronised` up
     off `0xF1`; those above it nothing sets.
3. Firing every group: FULL GUNS, string `0x297`, at `(x + 1, y - 157)`, and with more than one
   group each group lit but one whose first gun is a Nova Cannon.
4. On the Grendel, the Wolverine and the Reaper, whose guns fire rounds, shape `0xEE` at
   `(x + 4, y - 17)` and the rounds left at `(x + 21, y - 19)`.

GUNNERY WINDOW turns to the ship's next group, round to the first after the last, or, firing them
all, only stops that. FULL GUNS, on a ship of more than one group, flips firing them all; turned on
for a ship of two groups, it has every gun of both that fires by the trigger next fire when the
later of the two groups' first guns does, so that they fire together. FIRE LASERS opens the window
as the guns fire.

## The damage display

Window 4 shows how well the player's weapons, engines and shields still work as the armour wears,
the object's `gun_condition` (`+0x66C`), `armor_speed_factor` (`+0x668`) and `shield_condition`
(`+0x664`), each from 0 to 1 ([Objects](objects.md#shields)). `hud_window_draw` draws it in the
view ahead from the window's place `(x, y)`:

1. DAMAGE, string `0x28D`, right-aligned at `(x - 2, y + 2)`.
2. An icon and a name for each row, the names left-aligned:

   | Row | Icon | Name |
   | --- | --- | --- |
   | Weapons | `0xC1` at `(x - 136, y + 23)` | WEAPONS, `0x285`, at `(x - 102, y + 24)` |
   | Engines | `0xBD` at `(x - 134, y + 59)` | ENGINES, `0x286`, at `(x - 102, y + 62)` |
   | Shields | `0xBE` at `(x - 135, y + 97)` | SHIELDS, `0x287`, at `(x - 102, y + 101)` |

3. Shape `0x160`, a rule under each row, at `(x - 132, y + 42)`, `(x - 132, y + 80)` and
   `(x - 132, y + 119)`.
4. The rows' bars at `(x - 98, y + 45)`, `(x - 98, y + 83)` and `(x - 98, y + 122)`.

A bar (`hud_damage_bar`, `0x00488B30`) is shape `0xE0`, orange, drawn whole, then shape `0xDF`,
red, at the same place in the pane `hud_bar_pane`. The pane's left edge stands a pixel before
`round(77 * level)` along the bar (`0x004DC91C`), its right edge `0x4D` further, and it runs from
a pixel above the bar 6 down, all inclusive, so the red shows past the level.

## The wing status

Window 13 shows the fighters of the player's wing. A mission lists its flight groups in three
wings, six slots each (`mission_wings_build`, `0x0045AC60`): each group whose byte at `+0x08` names
a wing, 0 to 2, has its `+0x09` ships, from its first in the mission's ship list (`+0x0C`), take
that wing's slots from the first, each object keeping the wing's number at `+0x74C`, and the slot
after the last set to -1. The player's wing is `player_wing` (`0x00515D88`); the other two
(`0x00515D7C`, `0x00515D94`) nothing reads. `mission_start` (`0x004934F0`) then puts the player's
slot first, and gives each ship of the wing, at `+0x24`, its type's icon from the table at
`0x004F8890`, 24 pairs of a type and a shape: `0xFC`, `0xFA`, `0x101`, `0xFF`, `0x102`, `0xFB`,
`0x100`, `0x103`, `0xFE`, `0x105`, `0xFD` and `0x104` for the twelve ships the player can fly and
their twins, none for the rest.

`hud_window_draw` draws it in the view ahead from the window's place `(x, y)`: THE 45TH, string
`0xA6`, right-aligned at `(x - 3, y - 78)`, then each slot's ship that is still there, is in the
player's wing (`+0x74C` 0) and whose pilot has not ejected, three across and two down. The slots'
bars stand at `(x - 135, y - 54)`, `(x - 88, y - 54)`, `(x - 41, y - 54)`, `(x - 135, y - 8)`,
`(x - 88, y - 8)` and `(x - 41, y - 8)`.

1. The bar, 38 of the display's pixels high (`0x004DC914`): its weakest armour quadrant's share of
   `6 * armor_class`, at most all of it, gives the rows kept, rounded, and the rest are lost from
   the top. Shape `0xF3` shows the rows kept and `0xF2` those lost, each drawn a pixel left of and
   below the bar's place in the pane `hud_bar_pane`, 4 pixels across, cut to its rows.
2. The ship's icon, where it has one, at 6 across and 1 down from the bar.
3. Its slot's number, from 1, at 6 across and 2 up from the bar.

**Fix:** a ship starts with one less than `6 * armor_class` in each quadrant, so an undamaged
Predator's bar shows a row lost. OpenReliant counts from what a ship starts with.

**Fix:** listing a wing sets only the slot after the last to -1, and the slots past it keep the
ships of the mission before, which the window shows again where they are in the wing. OpenReliant
empties every slot first.

Mission 0 lists the player and three wingmen in the player's wing.

## The power distribution

Window 7 shows how the ship's power is shared between its shields, guns and engines (see
[Controls](controls.md#the-power-distribution)). `hud_window_draw` draws it in the view ahead,
with everything placed from the window's place `(x, y)`, in this order:

1. The title, string `0xA7`, at `(x + 2, y - 77)`.
2. The power ball, a circle of radius 31 around `(x + 68, y - 1)`.
3. The shares as whole percentages, `%d%%`: the shields' at `(x + 86, y - 43)`, the guns' at
   `(x + 18, y + 30)` and the engines' at `(x + 86, y + 30)`. Each is its share times 100, rounded;
   when they come to 101, the first of them that is 34 becomes 33.
4. An arc round the ball for each system, a shape for the empty arc and one for the full arc drawn
   over it through a pane cut to the share. The guns' arc on the left fills upward, the
   engines' on the right fills downward, and the shields' across the top empties from the left.

   | System | Empty | Full | At | Pane |
   |---|---|---|---|---|
   | Guns | `0x84` | `0x81` | `(x + 34, y - 13)` | `x + 33` to `x + 64`, `y - 14 + round(48 - 48 * share)` to `y + 34` |
   | Engines | `0x85` | `0x82` | `(x + 70, y - 13)` | `x + 69` to `x + 100`, `y - 14` to `y - 14 + round(48 * share)` |
   | Shields | `0x83` | `0x80` | `(x + 41, y - 32)` | `x + 40 + round(54 - 54 * share)` to `x + 94`, `y - 33` to `y - 17` |

5. The icons for the three systems: shape `0xBE` at `(x + 53, y - 67)`, `0xBD` at `(x + 103, y + 1)`
   and `0xC1` at `(x + 2, y + 4)`.

The ball is a sphere textured with `powerball.tga`, a white triangle in the middle of a black
square, and lit from in front, above and to the left. The texture scrolls with the power point, so
the triangle points toward wherever the power is. `hud_init` works out four tables for it:

- `power_ball_texture` (`0x569984`): the texture, a byte a pixel, each the top 5 bits of its grey.
- `power_ball_sphere` (`0x579E2C`): for each pixel of a 62 by 62 square, where it shows the
  texture. The pixel stands on a sphere of radius √2 seen from the front, `x` and `y` from -1 to
  1; the texture is 138 texels to the half turn, `asin(x / z)` across and `asin(y / z)` down,
  from its middle. A pixel outside the circle is divided by its distance squared.
- `power_ball_shade` (`0x567F90`): how much light each pixel gets, 0 to 63. The pixel at `x`, `y`
  stands for the point `(x + 0.3, y + 0.3)` on a sphere of radius 1, so the brightest spot is up
  and to the left of the middle, and gets 64 times the cosine of the angle between the sphere's
  surface there and a light at 8 in front.
- `power_ball_colours16` (`0x566F90`) and `power_ball_colours8` (`0x568E94`): 32 colours for each
  of the 64 levels of light. With `t` the level over 63 and `b` the lesser of `t² + 0.25` and 1, a
  texture level `l` gives red `184 * l / 31 * b + h`, green `67 * l / 31 * b + h` and blue `h`,
  each kept to whole numbers from 0 to 255 (`hud_channel`, `0x00482DE0`). The highlight `h` is
  `255 * (t² + 0.25 - 1)` where that is above zero; below it, `h` keeps what the shade table left
  in its place, 0.39, which only moves where the channels round to.

Each frame, `hud_window_draw` writes the ball into the display a pixel at a time: for each row, the
pixel's colour is picked by its light and by the texture at its `power_ball_sphere` offset plus
`trunc(x / 2) - 256 * trunc(-y / 2)`, with `(x, y)` the power point. In the display's 16-bit
colour, while `hit_shake` is above zero, each row moves right by a random share of
`10 * hit_shake` pixels, rounded, a number of `rand` a row, so the ball shakes with the camera.

**Improvement:** OpenReliant writes the ball's pixels into an image each frame, in the same way, and
draws the image with the rest of the display, so it scales with it.

## The launch's date

From the drop of the player's launch from the Reliant to its end ([Launches](launch.md#the-date)),
`hud_draw` types out the date of the mission being flown (`0x00484601`), in every view: the language
string of the mission's date from the table at `0x005023D6`, which holds the dates of missions 1 to
28 one after another from string 978, June 24, 2160, and nothing for the others. It stands at the
foot of the screen, 50 from the left and 30 up, in the display's font and colour. A letter more
shows each time the game's ticks pass the time kept at `0x0057BF44`, which then moves 8 on, the
count kept at `0x005799E0`, and a cursor, `_`, follows the letters until the whole date shows, a
letter's time after its last. `hud_init` clears it, and the launch's start and end set and clear the
flag at `0x00569934` that shows it.

## The objectives

Each mission has ten objectives (`mission_objectives`, `0x00504120`, four bytes each): a state and
the language string that names it, or -1 for none. Missions 1 to 35 have a row each, and mission 25's
second part the row after them; the display reads the row of the mission being flown. As
`hud_init` readies the display for a mission (`objectives_reset`, `0x00499180`), the first objective
of every row becomes the current one, each other with a name is listed, and the window shows the
first (`objectives_shown`, `0x0056997E`):

| State | Shown |
|---|---|
| 0 | Not at all: OBJECTIVES WINDOW passes it over as it pages, and with every objective so the window says "No current objectives." |
| 1 | As an objective |
| 2 | As the current objective |

A mission's script sets an objective's state with `SetObjective` (command `0x43`), for missions
below 36; an objective made current becomes the one the window shows. The table's names,
[`hud/objectives.zig`](../../src/engine/game/hud/objectives.zig), `make objective-tables` derives
from the executable. **Fix:** the game writes an objective past the ten into the next mission's row,
and mission 0's before the table; OpenReliant writes none. What the window shows is not ported yet
([#98](https://github.com/vdmkenny/openreliant/issues/98)).

## Turning it off

No key turns the whole display off: the game binds none. `hud_draw` returns at once while the byte
`hud_on` (`0x00501C50`) is clear, which `hud_init` sets and nothing clears.
Individual panels have their own keys, which open and close [the windows](#the-windows). The
nearest thing to turning the display off is leaving the view ahead from the cockpit, which drops
the instruments and the windows.

## What is not known yet

- The names of the display's elements, which `hud_init` copies from `0x00515D70`.
- What windows 5, 6, 9, 12 and 14 are for, which no key opens and a mission's script may, and
  what window 14 shows.
- What the rest of `hud_draw` draws: what the other windows show.
- Why blind fire leaves the Nova Cannon alone.
- What sets `0x0057BF34`, whose string view `0xD` shows, and `0x00529FB8`, which shows a line at
  the foot in every view.
- What `hud_palette_ramp` (`0x0048D590`) colours, and whether the display's text takes its palette
  from it rather than from the font.
- How the display reaches the screen in the game, which is `vfx.dll`'s panes rather than anything
  in the payload.
