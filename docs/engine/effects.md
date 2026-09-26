# Effects

What the game shows besides its objects and their shots: for now, the particles, fireballs, burning bits, break-up and shockwaves of an explosion, the smoke a damaged ship trails, a ship's shields flaring as they are struck, the sparks a hit throws, and a capital ship's engine exhaust burning the player's ship. [Destruction](objects.md#destruction) covers when a ship blows up.

## Drawn between the ticks

The game moves its effects on by the ticks, a hundred a second, and draws each where the last tick left it, so at a display rate the ticks don't divide evenly, they move on unevenly.

**Improvement:** each is drawn as far past its tick as the frame is, the share of a tick the clock keeps (`objects.pastTick`): a particle, a spark, a bit, a chunk of rock, a fireball and its light, a piece of the break-up and a shockwave all that much further along by their velocities, a piece and a chunk turned that much further by their spin, and a shockwave's ring spread that much further. What they do stays on the ticks. `--no-smooth-motion` and `--original` draw them where the ticks leave them.

## Particles

`particles.cpp` keeps particles: sprites that fly off an emitter and change size and colour over
their life. A particle comes from one of the ten `particle_pools` (`0x0058A948`), which
`particle_pool_create` (`0x0049C050`) fills: a number of particles over a texture, drawn as one set
of sprites that take their own texture coordinates, are coloured by their own colour and combine
with what is behind them as the pool says. `particles_init` (`0x0049BF60`) makes the explosions'
pool (`particle_pool`, `0x0058A94C`), 1000 particles over `gunflare\partic4` that add to what is
behind them, the mission's start makes three for the [smoke](#smoke), and `guns_init` two for the
guns ([Guns](guns.md#particles-and-bursts)). A pool's sprites can instead show their texture's own
colours. A particle is a record of
0x18 bytes, its birth and life in ticks, its velocity a tick and its template, and the sprite of the
same index. It is free once its birth plus its life is before the frame.

A template (`particle_template_create`, `0x0049C5D0`, 0x50 bytes) says how its particles live:

| Offset | What |
|---|---|
| `0x00` | Its kind: 0 particles; 1 particles and, one time in 200, a spark; 2 sparks |
| `0x04` | How long a particle lives, in ticks |
| `0x08` | Up to how many more at random, `rand() % spread` |
| `0x0C` | The rate an emitter streams at over its own life, in particles a tick in hundredths |
| `0x18` | A particle's half-size over its life |
| `0x24`, `0x30`, `0x3C` | Its red, green and blue over its life, each held within 0 to 1 |
| `0x48` | The pool |
| `0x4C` | How far a burst thins with distance: 1 unless set; none at 0 |

Each curve is a quadratic `a t² + b t + c`, `t` running from 0 at the particle's birth to 1 at its
end, that `particle_curve_set` (`0x0049C180`) puts through a start, a middle and an end value at 0,
0.5 and 1.

An emitter (`particle_emitter_create`, `0x0049C600`, 0xFC bytes) holds its life and birth, a
Surrender frame of its own at `+0x08` that it can hang off another, then how its particles leave:
along a direction (`0xBC`), strayed by up to half its spread either way on each axis (`0xC8`), at
its speed and up to its speed's range more (`0xD4`, `0xD8`) a tick, turned into the world, plus a
velocity they inherit (`0xDC`); and the span of the texture they show (`0xE8`).

- `particle_emit` (`0x0049C1C0`) gives one particle its life, velocity and template, and puts its
  sprite where the emitter stands.
- `particle_burst` (`0x0049C450`) sends a number of them out at once, into the free particles. Half
  as many go where the emitter stands behind the camera, and the rest are thinned by their
  template's half-size halfway through its life times 150, over their distance times the template's
  `0x4C`, which takes all of them at most.
- `particle_stream` (`0x0049C680`) sends particles out over the emitter's own life: each tick of the
  frame, one goes with the chance the template's rate gives at that point, thinned as a burst is but
  by the distance alone, and each moves on at once as if it had left at the frame's start. It
  returns 0 once the emitter's life is over. It walks the pool until it has sent them all, the
  template's kind rolling at each particle it passes, free or not; a spark it rolls is thrown on top
  of them.
- `particle_spark` (`0x0049C340`) throws a spark: its velocity is a particle's but inheriting
  nothing, times 100 to make it a second's, and `explosion_spark` (`0x00471B20`) throws it as a
  [burning bit](#burning-bits) where the emitter stands.

**Improvement:** a burst and a stream are not thinned by their distance, so an explosion far off
is as full as one close by, and each pool has room for four times the game's to hold them. The half
behind the camera is still left out. `--original` restores the thinning and the game's pools.

`particles_frame` (`0x0049C8E0`), once a frame after the shots, moves each particle alive in each
pool on by its velocity times the frame's ticks, sets its sprite's half-size and colour from its
template's curves, and hides the rest; each pool's set is drawn up to its last particle alive, in
the world's layer.

An explosion's blast (`explode_blast`, `0x0046C980`) bursts into two templates that
`explosions_init` (`0x0046B240`) makes:

| Template | Life | Half-size | Colour | Burst |
|---|---|---|---|---|
| Flame (`0x00553348`) | 500 to 599 | 0, 100, 400 | yellowish white, orange, nothing | 400, at 200 to 500 a tick, from an emitter turned 60 degrees back from the camera and a random way about its axis, spread across the view; it thins with distance at 0.05 |
| Sparkle (`0x0055334C`) | 100 to 599 | 0, 25, 25 | white, fading out | 150, at up to 7 a tick every way |

Both carry some of the ship's velocity on: a quarter of it to half for the flame, a quarter for the
sparkle. A ship that bursts (`explode_burst`, `0x00471DB0`) sends 200 of the flame at 20 to 25 a
tick, carrying a quarter, and the sparkle carrying half.

[`particles.zig`](../../src/engine/game/particles.zig) ports the pools, templates, emitters, the
sparks they send and the frame; [`explode.zig`](../../src/engine/game/explode.zig) the two templates
and the bursts. `particles_frame` runs the [sparks](#sparks) first.

## Fireballs

`explosion_fireball` (`0x0046BD00`) sets a fireball off in the first free of the thirty
`explosion_fireballs` (`0x00553398`), and none at all where they are all going off. A fireball is
one sprite, as large either way as it is told and sorted as if it stood that much nearer, that plays
an animation where it was set off:

| Kind | Frames |
|---|---|
| 0, the bang | The sixteen textures `explosion\bang_00000` to `bang_00015` (`explosion_bang_images`), one after another over its life |
| 1, the sheet | The nine cells of `explosion\explosion sheet` (`explosion_sheet_image`), three across and three down, 82 texels apart and 81 across, mirrored left for right and top for bottom by two random bits |

It is blended over what is behind it by its texture's alpha. A special fireball, the flak's
(`+0x28`), plays the nine cells of `flak04` (`0x00562CCC`) instead, three across and three down a
third apart, unmirrored, and is added to what is behind it. A fireball waits out a delay before it
shows, drifts at a velocity a tick, and plays for its life, 150 ticks from every caller here but a
chunk of rock's puff. A fireball
told it is lit is coloured by how far it has played, from black to white. One with a light carries
a point light coloured (1, 0.5, 0.1) that starts at intensity 10 and fades to nothing as it plays,
reaching its intensity times 50 times the square root of its size. The light stays where the
fireball went off as the fireball drifts. `explosions_update` (`0x0046E480`) plays each one on
once a frame and frees it once it is done.

**Improvement:** there is room for 128 fireballs, where the thirty the game keeps leave part of a
second burst out close after a first. A fireball's light moves with it as it drifts, and starts 50%
brighter, at 15 where the game's starts at 10, so it also reaches 50% farther. Each frame of its
animation fades into the next, a second sprite showing the next frame, where the game flips from
one to the next, some ten frames a second. It fades out over the last fifth of its life as its
last frames play, where the game's vanishes after the last. `--original` restores the game's.

| Who | Where | Size | Light | Delay | Drift |
|---|---|---|---|---|---|
| A blast (`explode_blast`) | At the ship | Its radius | Yes | None | A quarter of the ship's velocity |
| A burst (`explode_burst`), 18 of them | Within 0.3 of the radius, a random way | 0.8 of the radius | Yes | Up to 9 ticks | Half of it |
| A spin-out and a halt, as they begin | At the ship | Its radius | No | None | None |
| A halting torpedo, 5 more | Within 750 each way | 1000 to 1500 | Yes | 30 ticks apart, and up to 19 later | None |
| A chunk of rock, its puff: special, over 40 ticks | Where it is thrown | 200 | Yes | None | None |
| The Uber Explode's ball, 5 on each ship it reaches | Within half the ship's radius each way | Half its radius | Yes | 30 ticks apart | None |

[`explode.zig`](../../src/engine/game/explode.zig) ports the fireballs as `Explosions.setOff` and
`Fireball`, and [`aiexplode.zig`](../../src/engine/game/aiexplode.zig) the spin-out's, the halt's
and the torpedo's.

## Burning bits

`explosion_bit` (`0x004717D0`) throws a small lit mesh out of an explosion into the next of
`explosion_bits` (`0x005538C8`), in place of whatever flew there. The options' detail sets how many
fly at once: 100, 300 or 500 at low, medium and high. OpenReliant starts at high.

A bit is a piece of debris, one of the ten models of types `0x4E` to `0x57`, which
`explosions_init` loads through `ship_type_first_levels` (`0x004AE190`) and draws 1.5 times as far
before a coarser level. The piece goes by one number `r` from 0 to 1: the first below a quarter, the
last below a half, and above that the second to the tenth, `1 + (r - 0.5) × 16`. Its scale is half
to one and a half times the throw's size. It leaves along its direction at 1500 to 4500 a second,
strayed up to a quarter of a radian about each axis, times the throw's speed; it turns up to 0.05
radians a frame about each axis; and it flies for 1750 to 2250 ticks. `explosions_update` moves each
bit on by its velocity times the ticks since the last frame, over 100, turns it once, and lets it go
once its life is over.

| Who | Bits | Direction | Size | Speed |
|---|---|---|---|---|
| A blast | 25 | Every way | 0.4 | 0.2 |
| A blast of an escape pod, a proximity mine or a ship its pilot left | 5 | Every way | 0.2 | 0.1 |
| A burst | 25 | Every way | 0.2 | 0.2 |
| A spin-out, each frame while fewer ticks are left than ten times its trail, from 50 | 1 | Backwards, from within 250 of the ship each way | 0.1 | 1 |
| The Uber Explode, each frame from half way through | 12 to 24 | At the camera, from 10000 beyond it toward the blast and up to 2000 to each side | 0.1 | 1 |

A ship with flag 24 set leaves only every other bit of its trail.

A stream's spark (`explosion_spark`, `0x00471B20`) is a bit as well: a piece picked the same way,
at 0.1 of the size, flying at the velocity it is given, turning as a bit does, for -100 to 300
ticks. One whose flight is over before it starts is let go before it is drawn, having still taken
the oldest bit's place.

A throw can also ask for a body by a chance: a split's bits take its sequence's `bodies`, 0.05 for most sweeps ([Splits](#splits)), and the Ulysses' 0.1. A body is one of the crewmen, types `0x58` to `0x5B` (`0x00553388`), which `explosions_init` loads drawn 2.5 times as far before a coarser level. It is picked by one number `r` from 0 to 1 as the first three, `3r` rounded down, with the fourth only at exactly 1; the game works that out as `r` times -3 back from the first. It is drawn 2.5 times as large, or 0.75 for a throw of size 0.1 or less. A chance of 1 is a body without drawing a number. The game can also throw a rock chunk (types `0xB2` to `0xB6`), which no caller asks for.

The game makes a bit with a light mask of 0, so every one of the backdrop's lights reaches it,
both key lights and both fill lights, where a ship's part takes one of each pair.

**Improvement:** a bit takes the lights a ship's part takes (`objects.lightMask`), so it is not
washed out. `--original` restores every light, for the bits and the break-up's pieces alike.

**Improvement:** OpenReliant keeps room for 4000 bits whatever the detail, and a thrown bit flies on until its place is needed instead of going after about 20 seconds. A capital ship's split throws hundreds, which the original's pool lets go of within seconds. A stream's spark still goes after its few seconds. `--original` restores the original's pool and times (`explode.BitPool`).

[`explode.zig`](../../src/engine/game/explode.zig) ports the bits as `Explosions.throwBit`,
`Explosions.throwSpark` and `Bit`, and [`aiexplode.zig`](../../src/engine/game/aiexplode.zig) the
spin-out's trail. OpenReliant leaves a piece out where the game has no model for it.

## Rock chunks

`rock_chunk_throw` (`0x00472780`) throws a chunk of rock into the next of 300 (`rock_chunks`,
`0x00558778`), in place of the oldest. A chunk is one of the five models of types `0xB2` to `0xB6`
at random, which `explosions_init` loads, lit as a burning bit is. It turns a random way at first,
and tumbles up to 0.05 radians a tick either way about each axis. It leaves along its direction at
6 to 12 a tick, turned up to 0.1 radians either way about each axis, and flies for 20000 ticks and
up to as many more. A puff of flak goes off where it starts ([Fireballs](#fireballs)).
`explosions_update` moves each chunk on by its velocity and turns it by its tumble for each tick
since it last did, and lets it go once its time is past.

| Who | From | Direction | Drawn | Speed |
|---|---|---|---|---|
| A shot striking a rock ([Sparks](#sparks)) | The point struck on the rock's part | Out along the face's normal | As modelled | As above |
| A Latov coming apart, the sequence's `bits` a step ([Splits](#splits)) | The step's point | Straight out from the ship's middle | 10 to 15 times as large | 4 times as fast |

[`explode/chunks.zig`](../../src/engine/game/explode/chunks.zig) ports the chunks.

## Break-up

A blast and a burst break the ship up first (`explode_break_up`, `0x0046C550`). It walks the node
tree from the root, the root's child list, every part in order whatever it is linked to and shown
or not, and each part's own children, the roots of the models it carries, and cuts each part in
four (`model_slice`, `0x0046BF20`).

A cut draws a number of random planes through a frame's origin, each a normal of three numbers
from -0.5 to 0.5. Each of the part's polygons, in its drawn level of detail, goes to the side of
each plane that the sum of its corners, turned into the frame, lies on, so two planes give up to
four sides. Each side that gets any polygons becomes a piece: a mesh of its own, with a corner of
its own for each corner of its polygons, in the frame's orientation and centred on those corners'
mean, where the piece stands. It is drawn with the part's object flags. The first cut's frame is
the ship's own place, so its planes pass through the ship's centre.

| Piece | What it does |
|---|---|
| First and fourth | Flies whole, away from the ship's centre at 14 to 24 a step, turning up to 0.02 radians a tick either way about each axis, for 200 to 499 ticks, and trails smoke |
| Second | Is cut again, through its own centre, in two |
| Third | Is cut again in four |

A piece of a second cut flies away at 20 a step for each plane that cut it, turning up to that many
times 0.025 radians a tick for a blast or 0.005 for a burst, for up to 299 ticks for a blast or 300
to 599 for a burst. Every piece carries on with the ship's velocity, and moves at a quarter of what
that comes to a tick.

The smoke is a stream of particles that leaves the piece along its own Z axis at 5 to 7 a tick,
straying up to an eighth either way across it:

| Blast | Burst |
|---|---|
| `0x00553358`: 30 to 10 a tick in hundredths, 25 to 75 across, orange to nothing, a second each | `0x00553354`: 60 to 20 a tick in hundredths, 25 to 75 across, pale blue to nothing, five seconds each |

The pieces go into a table of 500 (`0x0055AE88`), the next taking the place of the oldest
(`debris_add`, `0x00472700`). Each frame, `explosions_update` moves each piece on by its velocity
times the frame's ticks, turns it by its spin once for each tick, and streams its smoke. Once its
time is up it goes up in a fireball of the sheet's, 1.2 times its mesh's radius in size, over 60
ticks, drifting with it, and its smoke stops; 12 ticks later it is gone.

The game makes each piece's polygons plain ones, which turns a strip's odd members inside out. It
copies each polygon's plane normal unturned and leaves its distance at 0, so the faces show and
hide by the wrong planes. It leaves the part's baked colours and second texture coordinates
behind, and it creates the piece's object with a light mask of 0, so every light reaches it.

**Improvement:** OpenReliant keeps each polygon's kind, works each piece's planes out from its own
corners, and carries the baked colours and both sets of texture coordinates, so a piece looks as
its part did. A piece takes the part's light mask; `--original` restores every light.

[`explode/breakup.zig`](../../src/engine/game/explode/breakup.zig) ports the break-up.

### A component's destruction

As a component is destroyed ([Objects](objects.md#a-components-destruction)), each part of its
assembly goes up, and each part of every model mounted on it (`explode_part_burst`,
`0x0046CCF0`):

- a lit fireball its size where it stands, over 150 ticks;
- a burning bit, of size 0.3 and speed 0.1, from each third of 20 points within 0.15 of its radius
  either way about it, thrown outward from its centre;
- its drawn mesh cut in four through the ship's centre, and each quarter cut again, through its
  own centre, in two, four, eight and two. Each piece flies away from the ship's centre at the
  planes that cut it times the assembly's parts' radii together over 60, a step, carrying on with
  the ship's velocity, and moves at a hundredth of that a tick. It turns up to its planes times
  0.0025 radians a tick either way about each axis, for 100 to 119 ticks, and then goes up as any
  piece does; a lit fireball its size, set off late by as long, waits where it ends.

The hidden parts of the assembly, its damaged model, go up with the rest.

## Splits

When a capital ship loses its hull (`explode_capship_component`, `0x0046F820`), it splits in two. The explosion sequences at `0x004FFB50` say how: 40 records of `0x2C` bytes, looked up by the ship's own type, not the type it takes its stats from (`explode_sequence_find`, `0x00471D30`). `make explode-tables` transcribes them into [`explode/sequences.zig`](../../src/engine/game/explode/sequences.zig). Each record gives the type of the ship's other half, if it has one, whether the split is a sweep or bursts, how long it lasts, and the sizes of its fireballs and burning bits.

`split_create` (`0x0046F480`) sets the split up in one of ten slots (`0x0055335C`):

- The ship's engines stop, and its parts stop playing their tracks.
- The points of its parts' `cut` lists are gathered in the ship's frame and sorted from stern to bow. A Latov's stay in the order the parts list them.
- The other half appears where the ship is, turning as it turns but unpowered and disabled. It shows its first part, cut by the second portal.
- The ship's intact parts, and everything they carry, are cut by the first portal, which keeps what lies ahead of the cut. The last intact hull part is kept for the end.
- The first hull part of the damaged model is the wreck. A sweep shows it at once, cut by the second portal, which keeps what lies behind the cut. A Latov shows all its damaged hull parts.
- A kind 7 shockwave spreads from the ship, and a bursts split sets off five to seven bursts straight away.

`split_update` (`0x00470030`) runs each split once a frame:

- **A sweep** moves the cut through the points over the split's time. The ship is held where it split, shaking by up to 10 on each axis. The portals stand at the last point reached, turned with the ship, and are in the scene until the last step (never for a Latov). Each step sets off a lit fireball of `(0.5r + 0.75)` times the sequence's size and `bits` burning bits, heading out from the ship or back along it. A Latov throws rock chunks instead (`0x00472780`), and flashes the view at its 29th, 35th and 80th steps. Every 14 to 16 steps an explosion is heard, and one step in 30 adds a bigger burst halfway to the bow. The other half is free to move.
- **Bursts** start after a second. One frame in ten, or five for a Stalag, sets off two lit fireballs and four times `bits` burning bits at a random point, with an explosion's sound. A Latov's or a Stalag's bursts shake the view, and a Stalag's flash it one frame in 40.

Every burning bit of a split may be a body, by the sequence's chance ([Burning bits](#burning-bits)).

When the time is up, the split ends once (`GameObject` `0x610` bit 1) and the portals go, so nothing is cut any more:

- After a sweep, the other half drifts away by its type, and all the ship's parts but the wreck disappear.
- After bursts, every point gets a fireball and burning bits, the intact parts disappear and the wreck shows. A Latov or a Stalag flashes the view.
- Either way, the view flashes where the camera stands within five of the ship's radii (`explode_flash_near`, `0x00471D70`).
- Either way, the ship drifts at `(2, 1.4, -5)` a step and turns slowly; a few types stop dead instead. `CAPEXP` is heard from it, it is recentred on what is left (`object_recentre`), and three fireballs go off at its hull's `fireballs` points, 50 ticks apart.

`object_draw` leaves out the engine glows of a ship that is splitting.

**Fix:** OpenReliant corrects these bugs of the original:

- A type with no sequence doesn't split. The game reads a record from the text before the table, and the split never ends.
- With no other half, the game frees the player's ship to move each frame and sends it off at the end. OpenReliant leaves it alone.
- The points are sorted properly; the game puts the one that belongs right after the first before it. Each part's points go through the part's place in the ship, and a burst's points through the ship's place, not through the part a list belongs to.
- The Victorious' front half drifts as its own case says, instead of falling through into the next case.
- A burst with no points is skipped, where the game divides by zero, and the end reads only as many fireball points as the hull has.
- When all ten slots are taken, the split whose slot is reused is stopped first, so its parts are no longer cut.

The flash (`0x00587CC8`) lasts 100 ticks. Once a frame, `mission_frame` draws it and counts it down by the frame's ticks (`0x00494940`): a sprite over the whole view, just beyond the near plane in the overlay's layer, untextured and added to what is drawn, white at 0.012 for each tick left, at most 1. So it holds white for 17 ticks and fades out over the rest. The same sprite shows red while the player's display is shaken by a hit ([The interference](hud.md#the-interference)).

[`explode/split.zig`](../../src/engine/game/explode/split.zig) ports the splits, and [`main/flash.zig`](../../src/engine/game/main/flash.zig) the flash. Not ported: the Dark Reign's hat, the Krasnaya's arms and the Boridin breakaway's core, which a split takes apart first ([#238](https://github.com/vdmkenny/openreliant/issues/238)). The Ulysses' own routine is [#232](https://github.com/vdmkenny/openreliant/issues/232).

### Burning wrecks

Making a wreck type sets one of its parts burning (`create_object`):

| Type | Wreck | Part |
|---|---|---|
| `0x72` | The Mammoth's front | `Mam frnt dest 2` |
| `0x73` | The Mammoth's back | `Mam back dest` |
| `0x75` | The Badanov's back | `Bad dead back`, shown first |
| `0x76` | The Badanov's front | `BAD dead frnt`, shown first |
| `0x77` | The Kurgan's | `Box07` |

A split makes these as its other half, so they burn from the moment it starts.

`explode_part_burn` (`0x00471290`) sets a part burning, for good or for 5000 ticks, flickering or not, with or without lights. The wrecks burn for good, flickering, with lights. Where the part has a list of ray points:

- An [electric ray](#electric-rays) runs between each pair of points: one strand, 260 either way, a jitter of 0.2, pale cyan (0.6, 1, 1), dimming as it goes dark.
- A red burn light, `Burn light` (`part_burn_lights`, `0x00471470`), stands at the first point of each light list, reaching 20000, in one of 15 slots (`0x0055AD24`). Each frame it flickers between half and full brightness, and it fades out over 10000 ticks.
- Smoke streams from each point of the smoke lists (`part_streams`, `0x004715D0`), along the normal of the vertex it stands on, at 3 to 3.5 a tick, straying a quarter either way across, in one of 64 slots (`0x0055AD60`). The smoke (`0x00553350`) is grey puffs growing from 50 to 150 across over about a second, 0.2 of one a tick at first and 0.1 at the end.

Each frame, `explosions_update` streams the smoke and fades the lights. A light or a stream that finds no free slot isn't made.

**Fixes:**

- The game leaves out the last pair of ray points, so every wreck has one ray fewer than its points make, and a part with a single pair has none. OpenReliant runs a ray between every pair.
- The game keeps a burn light or a stream hanging from its part's frame after the wreck is gone. OpenReliant lets it go with the wreck.
- The game stops with an assertion where the object has no part of the name. OpenReliant burns nothing.

[`explode.zig`](../../src/engine/game/explode.zig) ports the burning as `burnPart`, and [`create.zig`](../../src/engine/game/create.zig) the wrecks' part of `create_object` as `wreckMade`. Not ported: the Protogate's power core, which burns with rays alone ([#233](https://github.com/vdmkenny/openreliant/issues/233)).

## The Uber Explode

The Huuuuuuuge Explosion order (43, `order_huuuuuuuge_explosion`, `0x004086C0`) sets off the Uber
Explode where the object stands, of size 50000 over 1500 ticks, and pops ([Orders](orders.md)). One
goes off at a time; another takes its place.

`uber_explode_start` (`0x00472AB0`) lists up to 80 objects it may reach (`uber_caught`,
`0x00562B88`): each but the player's ship that is created and not disabled, with combat stats of a
side but the neutral one and an order stack, and within 5 times its size, but for the gates (types
`0x6D` and `0x6E`), the Boridin and its breakaway (`0xA8`). It makes:

- Two halves of a hemisphere (`uber_hemisphere`, `0x00562CD0`, which `explosions_init` makes
  through `0x00473BF0`), the second turned half round: a pole and seven rings of 18 vertices, a
  sixteenth of a half turn apart, and a last pole that no triangle uses, over `ring3`, lit and
  blended by alpha. Each vertex takes its texture from where it lies across, halved and moved in by
  a half. The halves start dark at alpha 0.3, the last ring and pole clear.
- A ball, a sphere of 18 by 8 (`sphere_mesh_create`) over `shield128`, and its glow (`Uber BMO`), a
  sprite over `gunflare\partic6`, lit and added, red at 0.75, hanging from the ball.
- Two squares (`UberWave1`, `UberWave2`) over `bigshock1` and `bigshock2`, and a light
  (`UberExplosion_Light`), lilac (0.7, 0.5, 1) at intensity 2, reaching 20 times its size, none of
  which it ever adds to the scene.

It sounds `UBEREXP` from the owner, flashes the view for 100 ticks, and sets off two shockwaves of
kind 3: 16 times its size across over a quarter of its duration, and 6 times over half
([Shockwaves](#shockwaves)).

`uber_explode_update` (`0x00473210`) runs first in `explosions_update`. By how far through its
duration it is:

| Share | What happens |
|---|---|
| Up to 0.5 | The halves show, 1.3 times its size. Until 0.3 they open out: `0x00473EA0` lays the rings that share of the way round from the pole, from a point to the whole bowl. They brighten from nothing to full by 0.05, hold until 0.3 and fade to nothing by 0.5, their alpha 0.3 of it |
| From 0.3 | The ball shows and spreads from 0.001 to 5 times its size, in a straight line over the rest of the duration. It takes one texel of its texture, (45, 18), and each vertex flickers red at a random number to the fifth, its green 0.3 of its red. The view shakes (`hit_shake`) by twice the share of its spread. Its glow is twice as wide as the ball |
| From 0.3 | Each listed ship the ball reaches, but one exploding, is knocked away from the blast by 2000 times its mass at a point 0.6 of its radius from its middle a random way, spins up to 0.15 radians a tick either way about each axis, sets off five fireballs ([Fireballs](#fireballs)), and drops its orders for Do Nothing |
| From 0.5 | 12 to 24 burning bits a frame fly at the camera ([Burning bits](#burning-bits)) |
| From 0.95 | The view flashes for 2000 ticks a share past 0.95, so 100 at the end |

Past its duration it frees its objects and sounds `CAPEXP` from the owner. Each ship the ball
reached stops turning and, unless it is exploding already, is destroyed (`object_destroyed`,
neither spinning nor ejecting). The owner's mission ship then raises its explosion event
(`0x0045AB50`). In a multiplayer game the blast spares its owner in place of the player, and counts
and tells the players the kills.

**Fix:** the game lists every object in reach, running past the end of its list with more than 80;
OpenReliant lists the first 80. It colours one vertex of the halves' last ring with the rest, which
shows a sliver of the rim; OpenReliant keeps the whole rim clear.

**Improvement:** the game opens the halves and spreads the ball by rounded factors; OpenReliant
divides.

**Improvement:** the halves and the ball are drawn on grids three times as fine, so neither shows
its facets. The halves fade to their rim across the three rings that stand in the game's last band,
and the ball's vertices take the flicker of the game's vertices round them, so its blotches keep
their size. The ball flickers and the bits are thrown once each simulation step, 25 times a second,
where the game does both each frame, so a higher frame rate neither quickens the flicker nor throws
more bits. And the light lights what is round the blast while the halves show, as bright as they
are. `--original` restores the game's.

[`explode/uber.zig`](../../src/engine/game/explode/uber.zig) ports the Uber Explode, and
[`aiexplode.zig`](../../src/engine/game/aiexplode.zig) the order. Its end posts its owner's
ExplosionShip event ([Script VM](script-vm.md#events)). Not ported: the multiplayer part
([#55](https://github.com/vdmkenny/openreliant/issues/55)).

## Electric rays

`erayfx.cpp` draws electric rays: jagged strands of light between two points. They crackle over [burning wrecks](#burning-wrecks) and over ships a Havoc's shockwave disrupts ([Orders](orders.md)).

There is room for 100 rays (`0x005531B0`). `eray_add` (`0x0046AC50`) takes the first free slot, or frees the first ray where all are taken. A ray (`eray_create`, `0x0046ACE0`, 0x1B0 bytes) has:

- One or more strands of 16 segments (`eray_segment_mesh`, `0x0046A850`). A segment is a square across its start, over highlight texture 0, and two quads crossed along it, over `laser2`. All are lit and added to what is behind them by their alpha, which starts at 0.5.
- A point light, `Eray Light`, reaching 10000, in the first strand's colour (`eray_colour`, `0x0046AEA0`), at the middle of that strand.
- Flags: 1 flickers, 2 fades, 4 lasts only its life.
- What it hangs from, whose frame its ends are in (`eray_hang`, `0x0046AE60`), and the object it plays over: it goes once that object's slot stands in.

Once a frame, `erays_update` (`0x0046AC30`) runs `eray_update` (`0x0046AF40`) for each ray:

- A ray that lasts its life loses the ticks since it last moved on, and goes when none are left.
- A flickering ray stays lit for up to 100 ticks at random, then goes dark for up to 1500. One that fades dims by 0.03 a tick while dark; any other goes out at once.
- While it is brighter than nothing, each strand runs from the ray's start to its end through 15 points between, which stray at random each frame (`eray_jitter`, `0x0046AA70`). The middle of each stretch moves by up to the ray's jitter times the stretch's length, in a random direction, halving the stretch four times over. The strand's alpha is 0.5 times the ray's brightness, and the light shines at full strength.

The game leaves unset when a ray last changed and how long it stays lit. OpenReliant starts both at nothing, so a flickering ray goes dark on its first frame, fading if it fades. The game also makes a 17th segment for each strand that it never places or lights. OpenReliant leaves it out, and draws each strand as a single mesh.

**Fix:** a ray hanging from a part that a split's portal cuts is cut by it too, so it shows only on what the sweep has laid bare. The game cuts the part alone, and its rays crackle over the stretch of the ship still whole.

[`erayfx.zig`](../../src/engine/game/erayfx.zig) ports the rays.

## Smoke

A damaged ship trails smoke from its engines, and a badly damaged one throws out small fireballs as
well. `mission_frame` works it out in its pass over the objects, after the particles' frame and the
camera's. An object with flag 24 has its smoke let go and its level set back to 0 first; then each
one the pass draws, save stand-ins and disabled and jumping ones, sends its smoke out and has its
level followed.

**The level** (`+0x660`), for an object with stats other than the Ripper, goes by the weakest
quadrant of its armour against six times its type's `armor_class`:

| Level | Armour | Template | Half-size | Colour | Life |
|---|---|---|---|---|---|
| 0 | 0.9 or more | none | | | |
| 1 | Below 0.9 | Particles over `gunflare\partic4`, added | 37.5, 150, 300 | 0.3, 0.15, 0 grey | 70 to 79 |
| 2 | Below 0.7 | Particles over `gunflare\partic4`, added | 62.5, 250, 500 | 0.5, 0.25, 0 grey | 100 to 109 |
| 3 | Below 0.5 | Particles over `gunflare\partic7`, over what is behind by its alpha, and a spark one time in 200 | 75, 300, 600 | 0.5, 0.25, 0 grey | 100 to 109 |

While the weakest quadrant of its shields holds more than 0.9 of six times its type's
`shield_power`, smoke already showing thins to level 1 and none starts. The game reads the
shields' aft quadrant twice and their right one not at all.

**When the level changes**, the smoke starts again (`smoke_start`, `0x00494400`) from the first
part of the model, in its order, with an engine glow, and the first glow on it: the emitter hangs
from the part's frame where the glow stands, turned as it is, its Z axis turned back where the
glow's plume burns the other way (a negative length, `+0x50`). It streams along its Z axis at 30 to
36 a tick for 999999 ticks, strayed up to 0.15 either way across at level 1 and 0.25 above. A model
without a glow keeps what smoke it has. `mission_start` makes the three templates and their pools of
1000 (`smoke_template_create`, `0x004946B0`, into `smoke_templates` at `0x00587CB4`), and
`mission_end` (`0x004942B0`) lets them go.

**Each frame** with smoke, its template's rate is set through 50, 0 and 0, and its emitter's birth
to the frame's start, so it streams half a particle a tick; its particles carry a quarter of the
ship's velocity, which is a step's. At level 3, one frame in ten (`rand() % 10`), a fireball, the
bang, goes off where the glow stands, reckoned from the ship's root rather than the glow's part: 0.1
to 0.3 of the ship's radius across, for 90 ticks, drifting with the smoke.

OpenReliant reckons which particles are behind the camera by the camera's last frame, as it frames
the camera after the objects; the game frames the camera first.

**Improvement:** each particle of the smoke has a size of its own, from three quarters to one and a
quarter of its template's, and a shade of its own, from 0.85 to 1.15 of its colour
(`particles.Pool.Variety`), so that a trail of the same soft sprite does not look even. The numbers
come from the pool's own generator, which leaves the game's `rand()` as it would be. `--original`
draws them alike.

[`main/smoke.zig`](../../src/engine/game/main/smoke.zig) ports the smoke: the levels as `Level`, the
pools as `Pools`, a ship's smoke as `Stream`, which its slot holds, and the pass as `frame`.

## Shockwaves

`shockwave.cpp` keeps rings that spread out from an explosion. `shockwave_init` (`0x004A0D90`)
builds five rings (`shockwave_ring_mesh`, `0x004A0B30`), one over each of the textures `rng_02`,
`rng_03`, `rng_04`, `rng_01` and `rng_06`. A ring is eight points a unit out and eight a tenth out,
every 45 degrees about its Z axis, with sixteen triangles between them. Each corner's texture
coordinates are how far it lies across and how far up, either way and no less than 1/64, so the
texture, a quarter of a ring, shows mirrored in each quarter. It is coloured by its own colours
and added to what is behind it, and never culled. `shockwave_init` also builds a sphere
(`0x004A16F0`), which nothing draws.

**Improvement:** a ring has 32 points round it and its hole, so it is round where the game's eight
make an octagon, whose corners show on a ring ten times a ship's radius across. `--original`
restores the octagon.

`shockwave_create` (`0x004A15D0`) sets one off into the first free of thirty (`shockwaves`,
`0x005937C8`) at a place and facing, with a kind, a size, a life in ticks, a velocity a tick, a
side and an owner. The game fails an assertion where none is free. Once a frame after the
explosions, `shockwaves_update` (`0x004A0F00`) moves each one on by its velocity times the frame's
ticks, fades its colours from 1 to 0 over its life, and spreads it to its size times how far
through its life it is, the ring's scale. What it passes, between how far it had spread and how
far it has now, it acts on by its kind:

| Kind | Ring | Set off by | As it passes |
|---|---|---|---|
| 0 to 2 | `rng_02` to `rng_04` | A blast, one time in four: a random one of the three, ten times the ship's radius across, over 100 to 149 ticks, standing and drifting as the blast's flame emitter does | The player's view shakes by ten times how far through its life it is, at most 2 |
| 3 | `rng_01` | The Uber Explode, a pair ([The Uber Explode](#the-uber-explode)) | Nothing |
| 4 | `rng_06` | Nothing | Nothing |
| 5 | `rng_06` | A Havoc's end (`missile_end`, `0x00495870`): 50000 across over 500 ticks, sparing its launcher's side | Ships of other sides are pushed away, disrupted |
| 6 | `rng_01` | An Imp's end, likewise | Each quadrant of ships of other sides takes 50 more than its shield holds, and their [shield bubbles](#shields) flicker for 100 ticks |
| 7 | none, unseen | A capital ship's split ([Splits](#splits)): twice the ship's radius across, lasting half as long again as the split | Shakes the view as kind 0 does, and damages the player by the owner's type |
| 8 | `rng_01` | A halting torpedo, 6000 across over 100 ticks | The view shakes as for kind 0, and the player takes damage |

A shockwave that harms passes over ships that list components, are stand-ins, exploding or
disabled, or that another harmed less than 50 ticks before (`GameObject` `0x654`). Kind 8 does
0.05 of its size times what is left of its life to each quadrant. The fore and aft shields' reserves
take it first: a reserve that holds spares the shield, and one that runs out passes on to the
shield what it held.

Kinds 5 and 6 also pass over torpedoes and the Ripper, and shake the player's view as kind 0 does
as they pass the player's ship. Kind 5 puts a ship whose order ranks no higher than Disrupted
(114) into it, with a push of the ship's mass times the ring's size over its life, and a duration
of 500 ticks for a player's ship and 2000 for another's, both times 1.5 of what is left of the
ring's life, at most 1: so at full strength through its first third. The push points from the ring's
centre to the ship, in the world's frame, and Disrupted takes it in the ship's own
([Orders](orders.md)). Kind 6 does its damage as the missiles' kind, with no share passing to the
armour, and names the ship itself as the attacker.

The game names object 16 as kind 8's attacker, whatever its loop over the ring's colours left in
a register.

**Improvement:** OpenReliant names the shockwave's owner, the torpedo, instead.

[`shockwave.zig`](../../src/engine/game/shockwave.zig) ports the rings and what kinds 0 to 2 and 5
to 8 do, and [`explode.zig`](../../src/engine/game/explode.zig),
[`aiexplode.zig`](../../src/engine/game/aiexplode.zig) and
[`missiles.zig`](../../src/engine/game/missiles.zig) the blast's, the torpedo's and the missiles',
and [`explode/uber.zig`](../../src/engine/game/explode/uber.zig) the Uber Explode's.

## Shields

`shield.cpp` shows a ship's shields as they are struck: a bubble round the ship that ripples out
from the point struck. `create_object` gives one (`shield_bubble_create`, `0x0049EF90`, 0x48 bytes)
to every ship that lists no components and is not debris. It is a sphere 1.1 times the ship's
radius, hanging from the ship's frame, over `shield128`, coloured by its vertices and added to what
is behind it, and never culled. Its tint is the ship type's side: friendly, or any other.

`shields_init` (`0x0049EF10`) builds six levels of the sphere (`sphere_mesh_create`,
`0x0049E3D0`), finest first: 16 slices round by 14 bands down, then 12 by 10, 10 by 8, 8 by 6, 6 by
4 and 4 by 4, each a fan round each pole and two triangles to a slice between. Each level is drawn
out to a distance from the camera the options' detail gives:

| Detail | Reaches |
|---|---|
| Low | 1250, 2500, 5000, 10000, 20000, 40000 |
| Medium | 2500, 5000, 10000, 20000, 40000, 80000 |
| High | 10000, 20000, 40000, 80000, 160000, 320000 |

It also fills two ramps of 1024 colours, one a tint, by a strength from nothing up to one: a
friendly ship's runs from dark at 1 up to a cyan of 0.7 green and full blue at 0.6, down through a
dim blue of 0.3 at 0.4 to dark below 0.35, each stretch eased by a cosine (`cosine_ease`,
`0x004268C0`), and is grey without a hardware renderer. The other sides' swaps the green and the
blue, at 0.8. Both are 0.07 as bright.

**Improvement:** OpenReliant divides by each stretch's span of strength, where the game multiplies
by its reciprocal, rounded.

A shot spent on a shield, whatever becomes of it, and a knock that reaches a shield flare it
(`shield_flare`, `0x0049F1E0`), while any of the ship's shields holds anything and the ship is not
cloaked. Ten sparks of kind 3 fly off the point struck, unless the camera is in the ship's cockpit.
The bubble keeps its last eight hits, a strength for each vertex: the next hit gives each vertex
within 1.4 radians of the point struck, seen from the ship's centre, half a strength and one more
for each 1.2 radians off it, up to 2. A vertex shows only while its strength is between nothing and
one, and each fades by 0.025 a tick, so the colour ripples out from the point struck over about
two thirds of a second.

Once a frame, `shield_bubbles_draw` (`0x0049F0A0`) draws each bubble struck in the last 100 ticks at
the level its ship's distance from the camera gives, save the player's while the camera is in its
cockpit. As it is drawn (`shield_bubble_drawn`, `0x0049F450`), unless the game is paused, the bubble
moves on by the ticks since it last did (`shield_bubble_update`, `0x0049E7D0`): each vertex's colour
is the sum of its hits' faded strengths through its ramp, and its texture swirls, each vertex's
coordinates turning about a centre that starts at (0.3, 0.3), by 0.00001 a tick over the square of
how far they are from it, while the centre turns about the texture's corner by 0.0001 a tick. The
game leaves the centre off the coordinates it turns, so the texture wanders.

A shockwave of kind 6 makes a bubble flicker as a force field for 100 ticks: drawn over `ffield`,
set on the level's mesh that every bubble at that level shares, it is lit a random grey one frame
in four and dark on the rest, and its hits wait.

**Improvements:** the sparks fly out from the ship's centre through the point struck, where the game
takes the point itself as their direction, so they fly toward the world's origin; and a bubble past
the last level's reach is left out, where the game stops the pass there, leaving out the bubbles in
the slots after it and the capital shields. OpenReliant moves a bubble's colours on as it goes into
the scene rather than as the renderer draws it, so one out of view still fades.

**Improvement:** by default a bubble is drawn smooth; `--original` draws it as the game does. A
smooth bubble keeps its last 16 hits as where each struck and when, and works each vertex's
strength out from them for the frame, fading by the share of a tick the frame is at. So it is
right on whichever level it is drawn at, where the game's strengths belong to the vertices of the
level struck and a bubble drawn at another level reads them for other vertices, and it fades
evenly at any frame rate. Each level's texture coordinates are its own vertices', where the game's
lower levels read the finest level's; and the texture swirls about its centre, where the game
leaves the centre off the coordinates it turns, so its texture wanders further each time it is
drawn, the faster the higher the frame rate. Within half the finest level's reach it is drawn on a
sphere of 48 slices by 40 bands, so the ripple is a smooth ring rather than a band of broad
triangles.

[`shield.zig`](../../src/engine/game/shield.zig) ports the bubbles, and
[`guns.zig`](../../src/engine/game/guns.zig) and
[`collision.zig`](../../src/engine/game/collision.zig) the shots and knocks that flare them. A
cloaked ship's shields don't flare: the hit shows its hull instead ([The cloak](cloak.md#hits)).

### Capital shields

A ship that lists components has no bubble. When a shot or a missile strikes one of its components, and the ship has a shield generator and isn't exploding, the part struck glows round the hit instead (`node_add_effect`, `0x004992D0`, kind 3). A shot on a component of an asteroid, a turret asteroid or an asteroid hole leaves kind 5, which never glows. A force field, a part whose name holds `FORCEFIELD` in any case (`part_is_force_field`, `0x0049FC70`), glows whole when a shot or a knock strikes it, shield generator or not.

Up to 50 glow at once (`capshields`, `0x0058FB70`, 0x3C bytes each). `capshield_flare` (`0x0049F4A0`) does nothing on an object whose `invulnerable` is 5, or on a force field of an object that is exploding. A part already glowing shows for 200 more ticks. Otherwise `capshield_create` (`0x0049F790`) takes the next slot in turn (`capshield_next`, `0x00593728`), letting go of whatever shows there:

- It copies the part's finest mesh (`mesh_copy`, `0x004C4710`) and clears every polygon's `cap` flag, so all of them draw.
- Every surface becomes a single pass, lit and added to what is behind it, over `shield128`, or `ffield` for a force field.
- The copy stands where the part does and shows for 200 ticks. It keeps eight hits, each a strength for every vertex.

Each hit takes the next of the eight:

- On a force field, every vertex gets 1.
- On any other part, each vertex within reach of the middle of the polygon struck gets twice its distance over the reach, and the rest get nothing. The reach is 0.3 of the way across the part's bounds, at most 8000. The glow spreads out from the middle of the polygon as it fades.
- A polygon whose corners are all dark is marked `cap`, so it isn't drawn.

Once a frame after the bubbles, `capshields_draw` (`0x0049F950`) lets go of each whose time is up and draws the rest where their parts stand:

- Each vertex's hits fade by 0.025 a tick. Its colour is the sum of their colours through the friendly ramp, three times as bright, each channel held to 1.
- A part's texture swirls, each coordinate turning about (0.5, 0.5) by 0.001 a tick over the square of how far it is from there.
- A force field's coordinates are thrown anywhere at random every frame, and its green is added to its blue.

The game hands `capshield_create` the object's side but never stores it, so every capital shield glows in the friendly ramp. When a capital ship loses its hull, `force_field_mark` (`0x0049FCD0`) hides its force fields ([Splits](#splits)).

**Fixes:**

- When the game finds a part already glowing, it makes that slot the next one in turn, so the next part struck replaces the glow struck last while other slots are free. OpenReliant leaves the next slot where it was.
- The game marks the polygons the latest hit leaves dark and never draws them again, so a part struck again elsewhere loses the glow of its earlier hits. OpenReliant marks the polygons every hit leaves dark, each time the part is struck.

**Improvement:** the swirl's sine and cosine come from `std.math` rather than the engine's tables.

The game finds a part's glow by looking through every slot, and lets it go with the part's node (`0x00499CF0`). OpenReliant reads the slot the part's node names, and lets a glow go once the draw finds its part gone. OpenReliant's collision trees keep the file's face numbers, so a hit finds the polygon it struck through the faces' fans (`srofiles.polygonOf`); the game renumbers the trees to the polygons as it builds the mesh.

[`shield.zig`](../../src/engine/game/shield.zig) ports the capital shields, and [`shieldfx.zig`](../../src/engine/game/shieldfx.zig) the hits that make them glow.

## Sparks

`sparks.cpp` keeps the sparks a hit throws: small bolts that fly off, slow and fade. Each of five
kinds (`spark_looks`, `0x00508A18`, 0x68 bytes each) has its size, its texture's span, a first and
a last colour, a life in ticks and a drag, what is left of its speed after a tick:

| Kind | Thrown by | Size | Colour | Life | Drag |
|---|---|---|---|---|---|
| 0 | An allied Huge Gun's shot striking a component | 90 by 90, 500 long | White to dark blue | 300 | 0.9999 |
| 1 | A shot striking a component | 30 by 30, 140 long | White to black | 100 | 0.995 |
| 2 | A shot striking a hull | 30 by 30, 90 long | White to black | 100 | 0.995 |
| 3 | A shot striking a shield, and a shot or a ship meeting a multiplayer arena's wall (`arena_wall_hit`, `0x004B02A0`) | 20 by 20, 90 long | Blue to black | 100 | 0.995 |
| 4 | A coalition Huge Gun's shot striking a component | 90 by 90, 500 long | Warm white to dark red | 300 | 0.9999 |

`sparks_init` (`0x004A1AF0`), which `particles_init` runs, builds each kind's shape
(`spark_shape_build`, `0x004A2040`). Kind 0 is a beam of three crossed quads over `alhuge`,
reaching its length either way from its middle, drawn out to 1500000. The rest are a bolt of two
quads crossed along its length over `lasers`, drawn out to 100000, then a single quad out to
500000, whose material asks for generated texture coordinates though nothing makes any for it.
Each is coloured by its own colours and added to what is behind it, and never culled. A kind also
has three flags to turn, grow and fade late, which none sets.

`sparks_spray` (`0x004A1ED0`) throws a number of sparks from a point, each along a direction
turned by a random pitch and yaw within half a spread either way, at a speed and up to half a
range more or less, drifting on with a carried velocity. Kinds 2 and 3 are not thrown more than
20000 from the camera. Each goes into the next of 256 (`sparks`, `0x00593D90`) in place of what
was there (`spark_add`, `0x004A1DB0`). `sparks_update` (`0x004A1BB0`) moves each on by its
velocity and the carried one times the ticks since it last ran, slows it by the drag to the power
of those ticks, colours it between its first and last colour by how far through its life it is,
and frees it past its life.

A shot striking a hull (`bullet_hull_hit`) throws 10 of kind 2 at 7.5 to 12.5 a tick within half
a radian either way, out from the object's centre through where the shot entered the part's box,
carrying a quarter of the object's velocity, unless the camera is in the object's cockpit. The
game takes that point in the part's own frame, where `segment_meets_box` (`0x0049B6A0`) gives it,
for one in the world, so the sparks fly from near the world's origin.

**Improvement:** OpenReliant throws them from where the shot struck.

What a hit leaves where it struck (`shieldfx_create`, `0x004A0310`), which `node_add_effect`
(`0x004992D0`) hangs from the part struck as a node of kind 6, is its sound
([Sound](sound.md#where-the-sounds-come-from)) and, for a shot through to a hull, an emitter of an
orange template (`shieldfx_init`, `0x0049FD20`) on the part's surface nearest the point
(`mesh_nearest_surface`, `0x0049FEF0`), facing out from it. A shot or a missile on a component
leaves a burst of 20 of the same template's particles, or, on a ship with a shield generator, its
capital shield's glow ([Capital shields](#capital-shields)). Nothing sends the hull's emitter's
particles out: `node_draw` updates a node of kind 6 through `0x00458AB0`, the one routine the build
keeps of every routine that only returns 1, so it shows nothing.

A component's burst (kind 3, `shieldfx_create`, `0x004A0310`) is an emitter of the orange template (`shieldfx_orange`, `0x0049FD20`) at the point struck, facing out along the face's normal, which bursts 20 puffs at once. They leave at 10 to 12 a tick, straying up to an eighth either way across, and grow from 50 to 100 across as they fade from orange over about a second. Before it adds a component's node, `node_add_effect` clears the nodes of earlier hits within reach of the new one, and the oldest past ten. A rock's hit (kind 5) plays `COLL02` where it struck, and throws a chunk of rock from there along the face's normal ([Rock chunks](#rock-chunks)).

**Fix:** the game throws the chunk along the normal in the part's own frame, taken for a direction in the world's, so a chunk from a tumbling rock flies off any way. OpenReliant turns the normal into the world's.

**Fix:** a normal along `X` leaves the game's emitter with no frame; OpenReliant faces it along the normal all the same.

[`shieldfx.zig`](../../src/engine/game/shieldfx.zig) ports the sound, the burst and the rock's sound, keeping no nodes, as none shows anything once made. So a hull's part struck a hundred times, which the game's hundred nodes a part would leave silent, still sounds.

[`sparks.zig`](../../src/engine/game/sparks.zig) ports the sparks,
[`guns.zig`](../../src/engine/game/guns.zig) the hull's, and
[`shield.zig`](../../src/engine/game/shield.zig) a shield's ([Shields](#shields)), and
[`guns.zig`](../../src/engine/game/guns.zig) a component's. Not ported: the multiplayer arena's
wall's ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

## Engine exhaust

A capital ship's engine glows burn the player's ship flying into them. The first time `exhaust_burn`
runs in a mission, `exhaust_ships_list` (`0x00469810`) lists into `exhaust_ships` (`0x0054EA80`,
room for 400) the slots handed out whose objects list components and carry an engine glow, on their
model or on one it carries (`exhaust_ship_add`, `0x004699E0`, and `0x00469BC0`). Once they are
listed (`exhaust_ships_listed`, `0x0054F0C4`), `create_object` offers each object it makes to the
list. A slot stays listed whatever it comes to hold, and one made again is listed again. As a
mission ends (`0x004AD260`), `exhaust_ships_reset` (`0x00469840`) has them listed afresh.

`exhaust_burn` (`0x00469850`) runs once a frame in `mission_frame`, after the shields' bubbles and
before the explosions. While the player's ship flies under Player Control, it clears
`exhaust_burning` (`0x0054EA7C`), and takes each listed ship whose `last_throttle` isn't 0 and whose
distance from the player's ship, squared, is no more than the square of 1.2 times its radius and the
square of the player's ship's radius together:

- `exhaust_depth` (`0x00469A10`) sums how deep the player's ship stands in the exhaust of each of
  the ship's engine glows and those of the models it carries. It takes each glow's frame where the
  glow next stands. The exhaust is the glow mesh's bounds, scaled by the attachment's sizes times
  `last_throttle` times `engines_intact`, taken positive, times 1.7, with its ends along the plume
  changing places where the size turns it back. Inside, the depth is 1 less the point's distance
  from the glow's origin over the far corner's; outside, nothing.
- A depth above nothing sets `exhaust_burning`, which keeps the display's red away
  ([HUD](hud.md#the-interference)).
- The screen's flash lasts 100 ticks for each of the depth (`flash_ticks`), white, which cuts
  another flash short where the depth is nothing.
- On a frame at a tick that divides by 7, a depth above nothing burns the player's ship:
  `object_damage` on its fore quadrant, 23 times the depth, no more than 1, as a collision, what
  passes the shields wearing the armour at half. The blow starts the display's interference, so the
  display tears as the view whites out.

OpenReliant keeps the list beside the objects (`create.Objects.exhaust`) and runs it where the game
does (`environfx.Exhaust.burn`); `main.drawFrame` leaves the red out while it burns.

- **Fix:** the list has room for 400, which the game writes past where slots made again grow it;
  OpenReliant lists no more.
- **Fix:** an exhaust of no size, of a ship whose engines are out, leaves a point at its origin
  nothing deep, where the game divides nothing by nothing.
