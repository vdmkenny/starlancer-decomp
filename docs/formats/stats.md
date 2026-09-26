# Stat tables

`shipstats.bin`, `gunstats.bin`, `missilestats.bin` and `pilotstats.bin` define every ship, gun,
missile and pilot. Each ships twice, identically: in `LANCER.CAB` and in `resource.hog`.

```
sltool stats list <file>
```

lists a table with its fields named, and marks records the engine never loads.

## Frame

Each file is a flat array of **352-byte (`0x160`) records** with no header. All four share one
frame: a 64-byte NUL-padded name, then the table's fields.

| File | Records | Fields end at |
|---|---|---|
| `shipstats.bin` | 256 | `0x7C` |
| `gunstats.bin` | 15 | `0x58` |
| `missilestats.bin` | 16 | `0x64` |
| `pilotstats.bin` | 124 | `0x5C` |

Each table has its own loader in the payload executable. It reads one record at a time into a stack
buffer and copies the fields it wants into a runtime table. **No loader reads the name, or anything
past its table's last field**, and in the shipped files those bytes are zero in every record.

| Table | Loader | Records read | Runtime tables |
|---|---|---|---|
| Ships | `stats_load_ships` (`0x00466500`) | Exactly 256 | `ship_flight_stats` (`0x4F9E70`) and `ship_combat_stats` (`0x4FC670`), `0x28` and `0x30` bytes a ship |
| Guns | `stats_load_guns` (`0x004788F0`) | Until end of file | `gun_stats` (`0x500CA4`), 16 entries of `0x2C` |
| Missiles | `stats_load_missiles` (`0x00494BC0`) | **At most 11** | `missile_flight_stats` (`0x5035E8`) and `missile_stats` (`0x5037A8`), `0x28` bytes a missile each |
| Pilots | `stats_load_pilots` (`0x0049CAE0`) | Until end of file | `pilot_stats` (`0x58A968`), 194 entries of `0x24` |

Ships and missiles share one runtime layout for how they fly: a live object points at its flight
model at `+0x14` whichever it is. The flight model holds the max speed, the roll, pitch and yaw
rates, the four inertias, and the max speed divided by the pitch rate, which the ship loader
computes after reading the file. A missile's has only its speed and rates. The word at `+0x24`
comes from no file: the executable holds it for each ship type and missile, and it says how the AI
turns the ship ([Steering](../engine/orders.md#steering)). The runtime layouts, with
the source of every field, are in the modules of the files that load them:
[`create.zig`](../../src/engine/game/create.zig), [`guns.zig`](../../src/engine/game/guns.zig),
[`missiles.zig`](../../src/engine/game/missiles.zig) and
[`pilots.zig`](../../src/engine/game/pilots.zig).

The gun and pilot loaders have no bound: a file with more records than the runtime table writes past
its end. The missile loader stops after 11, so the last five of the 16 missiles, Blazer, Iron Tooth,
Death Claw, Brute and Hell Fire, are never read. They are zero, as is the eleventh, Stalker.

## Where the names come from

The loadout screen labels ship and missile stats with strings from `LANGUAGE.DLL`. For ships, a
layout table of eight 8-byte rows at `0x4EC020` gives each on-screen row a string ID and a display
kind, a ten-segment bar or a number, and row `r` shows the ship's `r`th loadout value; the code that
fills those values gives the field behind each label. Names marked **Screen** come from there.

Names marked **Mods** come from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
which located fields by diffing known mods.

## Ships

| Offset | Field | Loaded as | Evidence |
|---|---|---|---|
| `0x40` | Max speed | float | Screen: **Max Speed** bar |
| `0x44` | Inertia | float | Screen: **Acceleration** bar. Mods: Inertia |
| `0x48` | Yaw rate | float | Screen: **Agility** bar. Mods: YawMax |
| `0x4C` | Yaw inertia | float | Mods |
| `0x50` | Pitch rate | float | Mods |
| `0x54` | Pitch inertia | float | Mods |
| `0x58` | Roll rate | float | Mods |
| `0x5C` | Roll inertia | float | Mods |
| `0x60` | Shield power | truncated | Screen: **Shield Power** bar |
| `0x64` | Armor class | truncated | Screen: **Armor Class** bar |
| `0x68` | Afterburner fuel | truncated | Screen: **Afterburner Fuel**, a number labelled ` SECS` |
| `0x6C` | Shield recharge | float; 0 becomes 10 | Screen: **Shield Recharge** bar |
| `0x70` | Gun energy | float | The most the guns' charge holds: `create_object` gives a new ship this much (`GameObject.gun_charge`), the guns recharge to it, and the display's right arc measures against it. Mods: GunEnergy |
| `0x74` | Gun recharge | float | The seconds the guns take to charge fully (`guns_step`). Mods: GunRecharge |
| `0x78` | Rounds | truncated | The rounds a new ship's guns have, which a shot of a gun that fires rounds takes (`guns_step`). Mods: Ammo |

"Truncated" means the loader converts the float to an integer with `_ftol`.

The loader copies `0x40` to `0x5C` into the ship's flight model in the order speed, `0x58`, `0x50`,
`0x48`, `0x44`, `0x5C`, `0x54`, `0x4C`: the three rates together, then the four inertias, as the mod
diffs pair them. It also derives `0x40 / 0x50` per ship.

The loadout screen places each ship on a bar between the minimum and maximum of that stat across the
ships it lists: the Alliance fighters the player can fly, and in a second list Coalition fighters.

## Guns

| Offset | Field | Loaded as | Into | Evidence |
|---|---|---|---|---|
| `0x40` | Range | truncated | `+0x14` | The ticks a shot lives, which is what gives the gun its range. Mods |
| `0x44` | Speed | float | `+0x18` | How fast a shot flies (`bullet_place`) |
| `0x48` | Shield damage | float | `+0x1C` | What a hit does to a shield (`object_damage`). Weighted by the threat check below. Mods: DamageMin |
| `0x4C` | Hull damage | float | `+0x20` | What a hit does to a hull or a component. Of what gets through a shield, the hull takes this over the shield damage. Mods: DamageMax |
| `0x50` | Fire rate | `100 / x`, truncated | `+0x24` | The ticks between shots. Mods: CyclicRate |
| `0x54` | Shot energy | truncated | `+0x28` | What a shot draws from the guns' charge (`guns_step`). Zero in every gun that fires rounds. Mods: energy or heat per shot |

The loader stores `100 / fire_rate`, the interval between shots.

`gun_stats` is indexed by the gun type a model's muzzle names, from 1 to 15, so the file's first
record is type 1 and type 0 is no gun. The loader fills only `+0x14` to `+0x28` of each record; the
first five words are the executable's own and say what a shot costs the ship (energy for types 1 to
7, one of its rounds for the rest) and which sound it makes. The engine's copy of those words is
[`guns/stats.zig`](../../src/engine/game/guns/stats.zig), which `make gun-tables` derives from the
executable.

The two damage values are **not a minimum and a maximum**: in several guns the shield damage is the
larger. `player_spectral_shields_set` (`0x00415430`) uses the shield damage alone: turning the
spectral shields on, it counts each gun type among the hostile ships nearby, weights each count by
that damage, and tunes the shields to the most dangerous type other than the two capital-ship guns.

## Missiles

| Offset | Field | Loaded as | Evidence |
|---|---|---|---|
| `0x40` | Speed | float | Screen: **Speed** bar. Mods: MaxVelocity |
| `0x44` | Turn rate | float | Copied into all three rates of the missile's flight model |
| `0x48` | Flight time | `x * 100`, truncated | Screen: **Range** is `speed * flight_time`. Mods: Range |
| `0x4C` | Shield damage | float | Screen: **Damage** is `0x4C + 0x50`. What a hit does to a shield (`missile_collide`) |
| `0x50` | Hull damage | float | Screen. What a hit does to a hull |
| `0x54` | Lock time | truncated | Screen: **Locking Time** is `0x54 * 0.01`, labelled ` SECS` |
| `0x58` | Decoy chance | truncated | In percent: the chance a countermeasure draws the missile off (`object_spend_countermeasure`) |
| `0x5C` | Lock range | float | How far off a target the missile locks on: the player's lock, the AI's and the missile turret's |
| `0x60` | Component damage | float | What a hit does to a component of a ship that lists them |

`0x48` is flight time, not range: the loadout screen computes range as speed times it. `0x54` is in
hundredths of a second.

The screen hides the locking time for Screamer and Solomon, pins Jack Hammer's damage bar at full,
and hides Stalker's speed, range and damage.

## Pilots

The record index is the pilot ID missions use. The loader fills all 194 runtime slots with defaults,
then applies each record read. Three fields are **tier selectors**: 0, 1 or 2 picks one of three
presets for a group of runtime values, and any other value keeps the default. The other four are
copied with a 16-bit move, so only their low halves count. The shipped data uses tiers 1 and 2.

| Offset | Field | Effect |
|---|---|---|
| `0x40` | Tier A | Six 16-bit values |
| `0x44` | Tier B | One float |
| `0x48` | Tier C | Two floats and a 16-bit value |
| `0x4C` to `0x58` | Four values | Copied through, low 16 bits |

| Tier | A | B | C |
|---|---|---|---|
| 0 | 10, 40, 800, 1600, 400, 800 | 5.0 | 0.6, 0.4, 100 |
| 1 | 30, 50, 400, 800, 300, 600 | 3.0 | 0.8, 0.2, 50 |
| 2 | 100, 100, 200, 400, 200, 400 | 1.5 | 1.0, 0.0, 25 |
| Default | 30, 50, 400, 800, 200, 400 | 3.0 | 0.8, 0.2, 50 |

The loader applies B, then A, then C; tier 2 of C also sets the last two values of A, to 50 and 100.

**Unknown:** what the runtime values do. Each group changes monotonically from tier 0 to tier 2.

## Prior art

The record frame, the counts and the names marked **Mods** are from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
built on Userunfriendly's hexcheat mod pack, which treats the bytes past each table's fields as an
undecoded tail. They are unread and zero.
