# Combat maneuvers

How a ship fights. The [order](orders.md) Fight (105) runs one maneuver after another against its target: "loop the loop", "defend dodge1", "attack pursue" and seven more. Each maneuver is a script in a small language of the developers' own, which the payload compiles line by line as it first runs each line, and a table picks the next maneuver by where the two ships are.

[`aidefend.zig`](../../src/engine/game/aidefend.zig) and [`aifight.zig`](../../src/engine/game/aifight.zig) define the structures, [`aidefend/maneuvers.zig`](../../src/engine/game/aidefend/maneuvers.zig) holds the maneuvers, their scripts and the handlers of each opcode, which `make maneuver-tables` transcribes from the executable, and [`aidefend/script.zig`](../../src/engine/game/aidefend/script.zig) compiles the scripts as the payload does. The build compiles every script, so a script the compiler cannot read fails it. The names below are those `make ghidra-annotate` gives the Ghidra project; the source file the asserts name is `aidefend.cpp`.

## The maneuvers

`maneuvers` (`0x4E1070`) holds a 16-byte `ManeuverRecord` for each maneuver:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 1 | The inputs it may mirror: bit 0 yaw, bit 1 pitch, bit 2 roll. Each time it starts, a random choice among them is mirrored. |
| `0x04` | 4 | Its script |
| `0x08` | 4 | Its name |
| `0x0C` | 2 | The fewest ticks it runs |
| `0x0E` | 2 | The most |

A script is a list of 8-byte `ManeuverScriptLine` records ending with one without text: the line's
text, and a pointer to its compiled instruction, null until the line first runs. "loop the loop"
reads:

```
Cloak(on)
SetAfterburner(off)
SetPitch(1)
SetYaw(0)
SetRoll(0)
SetSpeed(0.5)
loop:
	Wait(1000)
	Goto loop
```

and "attack pursue":

```
Cloak(off)
SetAfterburner(off)
loop:
	If Goingtocrash
		Avoid(300)
	Endif
	Attack(25)
	Goto loop
```

## The language

Each line is one command: a word, then for some commands arguments in parentheses, separated by
commas. A word is letters, digits and `_ . : -`; spaces and tabs around words are skipped. Commands
compare without regard to case. A line whose first word ends in `:` is a label.

`maneuver_compile_line` (`0x00405010`) compiles a line into `maneuver_code` (`0x515DA4`) at
`maneuver_code_end`: a byte of opcode, then what the command needs. It reads arguments with
`script_read_arguments` (`0x00404F80`), four at most. Where a command takes a range, one argument
gives both ends. It stops with a fatal error on a command it does not know ("Syntax error %s"),
arguments that do not open with `(` or are not separated by commas ("Syntax error"), a `Goto` to a
label no line holds ("Invalid goto"), and an `If` or `Else` with no `Endif` ("no endif for if").

| Command | Opcode | Compiled |
|---|---|---|
| `SetYaw(a, b)`, `SetPitch`, `SetRoll`, `SetSpeed` | 0 to 3 | A range of numbers: 12 bytes |
| `Wait(a, b)` | 4 | A range of ticks: 6 bytes |
| `Goto label` | 5 | The label's line, found by comparing each whole line with the label and a colon: 2 bytes |
| `label:` | 6 | 1 byte |
| `SetAfterburner(on)`, `(off)` | 7 | Whether the argument is `on`: 2 bytes |
| `Runaway(a, b)` | 8 | A range of ticks |
| `Attack(a, b)` | 9 | A range of ticks |
| `Attackmassive()` | 10 | 6 bytes, no ticks written |
| `Outofactionsphere(a, b)` | 11 | A range of ticks |
| `Setmirror` | 12 | 1 byte |
| `If Goingtocrash` | 13 | The condition, 0 for `Goingtocrash`, and the line of the matching `Else` or `Endif`: 3 bytes. For any other condition the byte is left as it was. |
| `Else` | 14 | The line of the matching `Endif`: 2 bytes |
| `Endif` | 15 | 1 byte |
| `Avoid(a, b)` | 16 | A range of ticks |
| `Cloak(on)`, `(off)` | 17 | Whether the argument is `on`: 2 bytes |
| `AttackMediumFighter(a, b)` | 18 | A range of ticks |
| `NewAttackRun(true)`, `(false)` | 19 | Whether there is one argument and it is `true`: 2 bytes |
| `RunToShip()` | 20 | 6 bytes, no ticks written |
| `EndScript()` | 21 | 6 bytes, no ticks written |

## Running a maneuver

`maneuver_handlers` (`0x4E0CC0`) holds a start and a run routine for each opcode, either of which
may be null. `maneuver_run` (`0x004069B0`) runs the Fight order's maneuver for an update, keeping
the line it is on and whether that line waits in the order's state, a `FightState`:

1. While no line waits, it moves to the next line, compiles it if it has not been, and calls its
   opcode's start routine, which returns true for an instruction that waits.
2. It then calls the waiting line's run routine, which returns true while the instruction still
   waits.

So a script's commands run one after another in the same update until one waits, and a loop
without a waiting command in it would never return. Commands that wait keep a
timer in the state, `min + random * (max - min)` ticks after `frame_start`, which
`maneuver_start_timer` (`0x00405B20`) sets. What each does:

| Command | What it does |
|---|---|
| `SetYaw`, `SetPitch`, `SetRoll` | Sets the input to a random value in the range, times the pilot's turn limit, negated when the maneuver mirrors that input. |
| `SetSpeed` | Sets the throttle to a random value in the range. |
| `Wait` | Waits its ticks. |
| `Goto`, `Else` | Go on after the line they hold (`maneuver_jump`, `0x00405B70`). |
| `If Goingtocrash` | Runs the lines after it when the ship is on course to hit its target, and otherwise goes on after its `Else` or `Endif`. Against a target without components, "on course" is what `ai_collision_course` (`0x00401980`) finds over 100 updates with a margin of 5000, 3500 or 2000 units by the pilot's skill (0, 1 or 2), and never for other skills; against one with components, being within 50 times the cruise speed plus both radii of the target's part. |
| `SetAfterburner(on)` | Keeps the afterburner lit through the maneuver, but only for a pilot whose turn limit is exactly 2, and only while a player's ship is within 50000 units. No pilot preset's limit is above 1, so as the game ships it never lights. `off` puts it out. |
| `Cloak(on)` | Cloaks the ship after 500 ticks, if its model can cloak. `off` uncloaks it at once. |
| `Setmirror` | Picks at random which of the three inputs the `Set` commands mirror from here on, whatever the maneuver allows. |
| `Runaway` | For its ticks, flies at a point a million units away from the target. |
| `Outofactionsphere` | For its ticks, flies to the object at the action sphere's centre. |
| `Attack` | For its ticks, steers at its aim point (see [each update](#each-update)) with the pilot's turn limit and ease, at full throttle. Within 12000 units of the target, both radii aside, the throttle is instead the aim point's velocity along the ship's nose over its cruise speed, which is a quarter of the target's speed that way. When the target is behind where the ship will be in 20 updates, a pilot of skill 2 lights the afterburner. The throttle stays at least 0.5. |
| `Attackmassive` | Steers at its aim point at full throttle until it is within 50 times its cruise speed, plus both radii, of the target's part. |
| `AttackMediumFighter` | For its ticks, flies at full throttle toward where the target will be, leading it by its velocity less a tenth of the ship's, over the time the ship needs to get there. Within 10000 units of a target that is not within 18 degrees of its nose, it flies straight on instead. |
| `Avoid` | For its ticks, with the target ahead, pitches hard at half throttle, one way or the other by whether the target is above or below; with the target behind, flies on at full throttle. |
| `NewAttackRun` | Takes the way out from the target's part that is clear of its hull (`ai_escape_direction`, `0x00402500`), or for a component the point the model gives it, then flies to a point 50000 units out that way from the part, or with `true` twice the target's radius for a target larger than 50000. The way out turns with the part of the target hanging from its root that the aimed part is, or hangs from. It burns full throttle and afterburner while the way out lies along its velocity, half throttle while it lies against it, and ends within 2000 units of the point. `true` also sets the ship's `fighting` to -1 at the start; the end sets it back to the target. |
| `RunToShip` | Flies to the friendly ship chosen for it. By a ship with components it ends within 5000 units of the ship's edge; by one without, it matches the ship's speed along its nose and closes by the distance past 5000. |
| `EndScript` | Ends the maneuver: it sets the maneuver's end to the tick before, so Fight chooses another. |

`ai_escape_direction` sums, over each box of the collision trees of the parts in the ship's root's
child list, every part whatever it is linked to, taken as a sphere as wide as its half-size, a push
away from the box for each whose edge is within 20000 units of the point, the harder the nearer, and
normalizes the sum.

The commands that fly to a point (`maneuver_steer_to_point`, `0x00405C60`) go at full throttle
and steer with [`ai_steer`](orders.md#steering) at the pilot's turn limit and no ease, flags `0xB`,
unless there is something to avoid, when they steer at full limit with flags `0x3`. Once the point
is within 26 degrees of the nose, the ship pitches at its full rate until it is 45 degrees off,
then steers at it again, so it weaves.

## Choosing a maneuver

`fight_choose_maneuver` (`0x0040A3A0`) chooses the next maneuver into the order's data, a
`FightData`, which Fight starts on its next update. It runs when Fight starts and whenever the
maneuver's time is up.

- Against a target with components: "attack massive object", for 20000 ticks.
- For a ship with components: "attack medium fighter", for 10000 ticks.
- For a ship outside the action sphere whose target is not a player's and is either within 200000
  units of it or outside the sphere as well, with no player's ship within 100000 units: "out of
  action sphere", for 500 ticks. The AI's first setup (`ai_first_setup`, `0x0040C9B0`) puts the
  sphere around slot 0 with a radius of 220000 units; a mission's `SetActionCentre` (command
  `0x25`) moves it (`action_sphere_center`, `0x515D78`, and `action_sphere_radius`, `0x515D74`),
  back to 220000 for a radius of 0.
- Otherwise, `fight_choose_by_position` (`0x0040A000`):
  - Farther from the target than `pursue_distances` (`0x4E193C`), 300000, 200000 or 100000 units by
    the pilot's skill, times the target's speed over its top speed but at least a quarter:
    "attack pursue". The table holds three; for any other skill the game reads past it, far enough
    that the ship never pursues.
  - With the target behind the ship, one time in ten, "run to ship" toward the nearest friendly ship
    with components and combat class 2 or 3, unless the ship is already within 50000 units of one,
    its radius aside (`fight_find_ship_to_run_to`, `0x00409F00`).
  - Within 10000 units of the target: "defend runaway".
  - Otherwise a random maneuver from `maneuver_choices` (`0x4E1918`), by where the target is from
    the ship's nose (ahead within 60 degrees, behind more than 120 degrees off it, or abeam
    between), then where the ship is from the target's (ahead within 60 degrees, behind more than
    96 degrees off it, or abeam between): "attack pursue" when the ship is behind the target, or
    when the target is ahead and the ship abeam of it, and otherwise one of "defend runaway", the
    three dodges and "loop the loop".

Its length is what the choice gives, or `min + random % (max - min)` ticks from the maneuver's
range, with the ship's own random number.

When Fight starts (`order_fight_init`, `0x0040A4D0`) it chooses the first maneuver, draws the wait
for the first missile, sets the ship's `fighting` to the target, counts one more in the target's
`fought_by`, and zeroes the ship's `recent_damage`. When it starts a chosen maneuver it clears its
state, puts the script before its first line, picks the inputs to mirror, and sets the tick it
ends at.

## Each update

Fight's update (`order_fight`, `0x0040A5E0`) pops the order when its target is no longer valid,
chooses a new maneuver when the last one's time is up and starts one chosen, and then:

1. **Aims** (`fight_aim`, `0x00409BE0`). Every pilot's `aim_interval` ticks it aims afresh: ahead of
   the target where `ai_lead_aim` (`0x00401280`) can lead it with the fastest of the guns it fires
   together, and otherwise at the target, or at its part for a component. `ai_lead_aim_with_gun`
   (`0x00401180`) leads it along its heading by its speed times the time the gun's shot takes to
   reach it, where that is within a quarter of the gun's lifetime, three times its lifetime for a
   Turret Flak. **Fix:** the game reads each gun's turret kind as its type, so it leads every ship's
   shots as a Laser Cannon's; OpenReliant leads by the fastest gun's own type. **Fix:** for the
   Turret Flak the game takes the Laser Cannon's lifetime, the table's first gun's, which leads flak
   past the life of its own shells; OpenReliant the flak's own. The aim point's velocity is a
   quarter of the target's, turned by the target's per-update turn half `aim_interval` times. Each
   update the aim point moves by that velocity times `frame_duration`.
2. **Fires** (`fight_fire`, `0x004096B0`), unless the ship is cloaked. Once the pilot's `pause`
   has passed since it last looked, it looks again: where the aim point is within `fire_spread`
   times the target's radius (or its part's) of the line along the ship's nose, and the part is
   within a quarter of a laser cannon's range (its speed times its lifetime), it fires for the
   pilot's `burst` ticks. A friendly ship holds its fire while a player's ship is ahead of it
   within 50000 units and within a tenth of that distance, plus the player's radius and 500
   units, of the line along its nose. It then locks and launches its missiles, timed from the
   pilot's `missiles` range, and drops its countermeasures, timed from its `countermeasures`
   range, while a missile homes on it ([Missiles](missiles.md#the-ais-missiles)).
3. **Calls for help** (`fight_call_for_help`, `0x00409D10`). When the target is the player, the
   player hit the ship last, its `recent_damage` has reached 1.2 times its armor class, and one of
   its armor values is below 3 times its armor class, about half what it starts with, it zeroes
   `recent_damage` and pushes Fight, aimed at the player, on the nearest ship of its side with
   combat class 1 whose order is Fight or Mill. The first milling ship in the slots takes over
   from any fighting ship found before it, however near; from there the nearest wins.
4. **Cloaks** (`fight_update_cloak`, `0x00409EC0`) as the maneuver's `Cloak` asked.
5. Runs the maneuver.

## The pilot

The Fight order and its maneuvers read the ship's pilot, a record of `pilot_stats` that
`pilotstats.bin`'s tiers fill ([`pilots.zig`](../../src/engine/game/pilots.zig)):

| Field | Tier | What it does |
|---|---|---|
| `turn_limit` | C, first float | The most of each turning input `ai_steer` gives, and the scale of the inputs the `Set` commands give |
| `turn_ease` | C, second float | How far `ai_steer` lets a turn swing |
| `aim_interval` | C, the word | The ticks between aims |
| `fire_spread` | B | How far off the nose line the aim point may be, in the target's radii, to fire |
| `timings` | A | `burst` and `pause` for the guns, then the ranges for missiles and countermeasures |
| `values[3]` | | Its skill, 0 to 2: how far off it pursues, the berth `If Goingtocrash` gives, and whether `Attack` lights the afterburner |

**Unknown:** what the game calls these.

## In OpenReliant

The Fight order and every command run as described, with these left out: the points a model
gives its components ([#239](https://github.com/vdmkenny/openreliant/issues/239)), and
multiplayer, where the host chooses the maneuvers
([#55](https://github.com/vdmkenny/openreliant/issues/55)).

Where the game would stop or hang, OpenReliant goes on: a script that runs off its end ends the
maneuver, a loop that starts 256 lines in one update without one waiting is left for the next
update, and a range with no span gives its least rather than divide by zero.
