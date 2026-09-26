# Missions

How a mission's start finds the mission's file, reads it, binds it for play and makes its ships,
and what each frame does with it. The file's own layout is in [`.DTE` missions](../formats/dte.md);
what its script does at run time is in [the script VM](script-vm.md).
[`mission/bind.zig`](../../src/engine/game/mission/bind.zig) ports the reading and the binding.

## The file

`WinMain` names the file of the mission to play, `.\missions\mission<number>.dte` under the game's
directory, by the mission number (`mission_number`, `0x00562DC8`). Two missions have files of
their own for a case of their own (`0x004A9C42`, `0x004AA40A`):

| Mission | File | When |
|---|---|---|
| 25 | `mission251.dte` | Once its first part is won (`mission25_second_part`, `0x00587CDC`): the second part |
| 3 | `mission311.dte` | In a multiplayer game |

`mission_file_read` (`0x0045A300`) reads the file. A loose file at that path comes first, where
`file_exists` (`0x004AD6E0`, through `_access`) finds one: it is read as it is, up to `0xFA000`
bytes, the size of the buffer, so it must be stored expanded. Otherwise `hog_load` reads the member
of `resource.hog` of the file's name, `mission<number>.dte`, and expands it where RefPack packed it
([`.HOG` archives](../formats/hog.md)). With neither, the mission's start stops the game: "The
mission number is invalid".

OpenReliant's own mission 0, the sandbox, is a file of this kind, which `openreliant` carries and
plays where the game has no mission 0 ([Platform](../port/platform.md)).

A retail install carries two loose missions, `missions\mission18.dte` and `missions\mission25.dte`,
which stand in for their archive copies. A mission added to the `missions` folder under a mission's
name takes that mission's place the same way. OpenReliant finds the loose file whatever the case of
its names, as Windows does, on every system
([`files.zig`](../../src/engine/files.zig)).

## Binding

`mission_bind_sections` (`0x00451D90`) runs at the mission's start. It reads the file, then binds
the directory's 27 entries in turn (`mission_bind_section`, `0x00452A20`): each section's count and
its offset, made a pointer into the file, into the section's globals (`mission_ships` and the
rest). Each entry's byte 3 carries four flags, and any section that has one sets the matching
`mission_format_flags` (`0x00525F9A`, `0x00525FA4`, `0x005267C6`, `0x005294E8`); nothing reads
them.

Then it sets each ship's run-time place and angles to those it is placed at
(`mission_ships_reset`, `0x00452010`), and makes the mission's tables (`mission_bind_tables`,
`0x00453050`):

1. The script's part tables (`mission_build_part_tables`, `0x00452F50`).
2. The waypoints (`mission_list_waypoints`, `0x00452100`): the ships of kind `0x3E5` in a flight
   group, a group at a time, in `waypoints` (`0x00525710`), a flight group and a ship each. It
   takes the first waypoint not yet listed, then every later one of its group, marking each
   listed at the ship's `+0x1B`, until none is left. A Patrol Route flies a group's waypoints from
   the entry its target names (`order_patrol_route_init`).
3. Each flight group's ships (`mission_list_group_ships`, `0x00452EC0`), in the order the mission
   lists them, into one list, `flight_group_ships` (`0x004EF2F8`): the group's count at `+0x09` and
   its first ship's place at `+0x0C`, or -1 for none.
4. The record each entry of the object table stands for (`mission_resolve_objects`, `0x00452DB0`),
   in `object_records` (`0x00538C90`): of the entry's kind, the first ship, flight group or squad
   whose object ID, taken as 16 bits, is the entry's (`mission_object_record`, `0x00452DF0`).
5. The trigger lists (`0x0045AE10`), for three of the conditions.

Last it starts the script's clock (`vm_clock_start`) and the script (`mission_script_start`). The
mission's start then sets the game's object count to the mission's ship count, so the objects and
the mission's ships share their numbers, and loads the model of each ship type the mission places.

A mission may carry a name for OpenReliant in section 21, which the game binds into a local variable
and never reads ([OpenReliant's mission name](../formats/dte.md#openreliants-mission-name)).

OpenReliant binds all 44 shipped missions. `openreliant missions` lists the missions a game's folder
holds and binds each ([Platform](../port/platform.md)). A section that runs past the file fails to
bind, where the game would read past its buffer.

Not yet ported: the trigger lists, which are the triggers'
([#37](https://github.com/vdmkenny/openreliant/issues/37)).

## The mission's start

Before each mission, the loading (`0x004AD0A0`) puts a stand-in in every object's slot
(`objects_reset`) and loads the Turret Flak's shell and the debris. Then `mission_start`
(`0x004934F0`):

1. ends the 3D sounds, resets the clocks and the camera, and sets the rescue odds to the pilot always
   picked up;
2. loads the cockpit of the loadout's ship (`player_loadouts`, `0x00588400`);
3. binds the mission, whose binding ends by starting the script's clock and the script
   (`mission_script_start`): the start part runs, and its commands make the mission's first ships;
4. keeps the ships' records where their objects are (`mission_ships_sync`), sets the script's clock
   back to 0 and the object count to the mission's ship count, so that the objects and the mission's
   ships share their numbers, and runs the frame's mission work once (`process_mission`);
5. puts the player's slot first in the player's wing and gives each of its ships its wing icon;
6. makes the camera's marker (`0x00588390`), a marker at (0, 0, -8000) in the next slot, which the
   flyby and target views move about;
7. loads the model of each ship type the mission places, and resets the frame's clock.

## The mission's ships

`CreateFlightGroup` (`0x00457C40`, command `0x03`) creates each ship of the flight group its
argument names, in the mission's order, with `mission_ship_create` (`0x00457CD0`), then lists the
wings. A ship's object takes the slot of the ship's index among the mission's ships:

- A nav point or a marker (kinds 999 and `0x3E3` to `0x3E5`) is an object of type 1000 at its
  place, turned by its record.
- Any other ship is an object of its kind, fitted by its loadout tier (`+0x3D`), at its place
  (`+0x1C`). From mission 14 on, a ship of a flight group in the player's wing flies the `t_` twin of
  its kind, the player's ship types from `0xF4` on, and in mission 25's first part a Kamov (`0x2D`).
  `create_object` makes a player's slot the loadout's ship, whatever the record's kind.
- It gets its first order: Player Control for the player's ship, whose view the camera takes (view
  0), Multiplayer Control for another player's, and Do Nothing for the rest. Then it is turned by
  its record (`object_orient_by_record`, `0x00452240`): its yaw about Y, then its pitch about X,
  then its roll about Z, in whole degrees.
- A ship whose `+0x2B` names a gate launches: a Launch order, which starts at once, through that
  gate of the first of the mission's ships whose kind is the ship's `+0x28` ([Launches](launch.md)).
  A mission makes the flight group of the ship its wing launches from first, so that the ship is
  there as the wing is made.
- A ship whose `+0x15` names a pilot gets it (`object_set_pilot`).

**Fix:** from mission 14 on, the game takes a ship of the player's wing whose kind is none of the
player's ships for the object in the slot its record's address gives, and reads the wing of a ship
in no flight group from past the groups. OpenReliant makes the first of its own kind, and takes the
second for a ship of no wing.

## The wings

`mission_wings_build` (`0x0045AC60`) lists each flight group whose `+0x08` names a wing, 0 the
player's and 1 and 2 two more, in that wing's list of six slots: `player_wing` (`0x00515D88`),
`0x00515D7C` and `0x00515D94`. Each of the group's ships, in the mission's order, takes the next
slot from the first and joins the wing (`GameObject.wing`); the slot after the last is set to -1.
The mission's start then puts the player's slot first in the player's wing.

**Fix:** the game lists a group of more ships than the wing holds past the list's end, and takes the
list of a wing past the third from past the lists. OpenReliant lists as many as fit, every ship
still joining the wing, and passes over the second. It keeps the player's wing's list alone, the
other two being read by nothing.

## Each frame

`mission_frame` runs `process_mission` (`0x0045A570`) in each frame that runs ticks, while the
mission plays on and its scene is not the landing's, before the orders: the script's threads run on
([Script VM](script-vm.md)), the ships' records take their objects' places, and once the script's
clock has ticked, the timers run, and the proximity conditions are checked (`0x0045AF60`).

`mission_ships_sync` (`0x0045A5F0`) copies each object's place into its ship's run-time place
(`+0x08`), and the heading of its nose into its run-time yaw and pitch (`+0x2C`, `+0x38`), in whole
degrees: the yaw about Y from 0 to 360, and the pitch about X, taken the other way round and folded
under 180 where the nose points within a right angle of the Z axis. A ship whose object is not made
yet takes the place of its slot's stand-in.

`mission_over` (`0x0052A414`), one of the script's variables, ends the mission: `mission_frame`
sets it once the camera has watched the player's end, and a script may set it itself.

## In OpenReliant

`game.main.startMission` ([`main.zig`](../../src/engine/game/main.zig)) is the loading and
`mission_start`; `mission.Loaded` ([`mission.zig`](../../src/engine/game/mission.zig)) holds a
mission bound for play with its script, which `main.missionFrame` runs each frame, the script's
clock ticking once for each 100 of the game's ticks the pause does not hold. The commands are in
[`executor.zig`](../../src/engine/game/executor.zig). Until the loadout screen is ported
([#44](https://github.com/vdmkenny/openreliant/issues/44)), `openreliant` chooses the loadout's ship,
`--ship` or the test keys, and where it chooses none the player's record's kind stands.

The orders reach the mission's records through the world (`gameobj.World.mission`), for an order
aimed at a flight group or a squad ([Orders](orders.md#targets-that-name-several-ships)).

Not ported: the rest of the loading and of `mission_start`: the renderer's and the textures'
setting up and the loading screen, which are the front end's
([#43](https://github.com/vdmkenny/openreliant/issues/43)), the chat line, a multiplayer game, and
what the start does for the campaign, the pilots it gives the player's wing, mission 25's first
part's cockpit, the Kamov's, and the pilot's profile
([#301](https://github.com/vdmkenny/openreliant/issues/301)); and the triggers
([#37](https://github.com/vdmkenny/openreliant/issues/37)).
