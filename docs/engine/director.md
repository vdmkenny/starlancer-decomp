# The director's camera

A mission's script shows its cutscenes through the director's camera: shots that fly the camera
along the mission's curves, or stand it at a ship, for a number of seconds, looking at a ship or
turning as the path turns. The camera shows them in view 13, held, and goes back to the player's
cockpit once they are over ([Camera](camera.md#the-directors-view)).
[`executor/director.zig`](../../src/engine/game/executor/director.zig) flies a shot,
[`executor/curves.zig`](../../src/engine/game/executor/curves.zig) holds the curves, and
[`camera/shots.zig`](../../src/engine/game/camera/shots.zig) the shots waiting. The director's code
and the curves' lie between `loadout.cpp`'s and `Executor.cpp`'s; their source file is unknown.

## The commands

| Command | What it does |
|---|---|
| `StartDirectorCam` (`0x10`, `0x004582E0`) | Drops the shots waiting, and stacks its own, which the camera takes at once |
| `StackDirectorCam` (`0x52`, `0x00458300`) | Stacks its shot after those waiting |
| `StopDirectorCam` (`0x24`, `0x00458E30`) | Puts the camera back in the player's cockpit, forced, unless the player's slot holds a stand-in. The shots waiting stay |
| `WaitForDirectorCam` (`0x50`, `0x00459C90`) | Holds the thread while the camera is in view 13 |

A shot's five arguments, in the catalogue's order:

1. The curve its path starts along, or the ship the camera stands at. A value that names a ship's,
   a flight group's or a squad's record (`record_kind`) is taken for a ship's.
2. The ship the camera looks at, or none.
3. How long it lasts, in whole seconds.
4. The ship its path rides along with, or none.
5. The ship, flight group or squad it holds still while it is on screen, or none.

The shots wait in a table of ten (`camera_shots`, `0x00539940`, 24 bytes each),
`camera_shot_count` (`0x00539A58`) of them. `camera_shot_stack` (`0x00461D30`) adds one after the
rest, and where none waited, begins it (`camera_shot_start`, `0x0045F170`). Once the camera's frame
finds that the director has left view 13, the first shot is over: the rest move up, and the next
begins. A shot `StopDirectorCam` stops stays in the table, so that `StackDirectorCam` after it only
adds to the table; `StartDirectorCam` empties it.

**Fix:** the game adds a shot past the table's last over the globals after it; OpenReliant passes
over the shot.

## Curves

A mission's curves are section 16 of its file ([Mission files](../formats/dte.md#curves)),
`mission_curves` (`0x00525FB0`), `mission_curve_count` (`0x005267C4`) of them. Each runs from one of
the mission's ships to another. Its point `t` of the way along (`curve_point`, `0x00457050`) is a
cubic Hermite spline of where it starts and ends and its two tangents, each weighed ten times as the
record holds it:

```
p(t) = (2t³ - 3t² + 1) from + (3t² - 2t³) to + 10 (t³ - 2t² + t) leaving + 10 (t² - t³) arriving
```

The four weights are `0x00457130`, `0x00457160`, `0x00457190` and `0x004571B0`. Past 1 the cubic
runs on.

A curve's length (`curve_length`, `0x00457250`) is the sum of the chords between its points at each
32nd of the way (`0x00457260`). The game takes those points from a table of the four weights at each
32nd (`curve_weights`, `0x00529FC0`), which `mission_script_start` fills (`0x00456F00`); OpenReliant
computes them, as the table holds them.

A path runs on from the ship a curve ends at through the curve that carries it on (`curve_next`,
`0x00457200`): the first other curve that starts at that ship, or else ends at it. Its length
(`curve_path_length`, `0x00457320`) is its curves', up to one that ends at no ship.

**Fix:** the game measures a path that comes round on itself for ever; OpenReliant stops once it
has taken as many curves as the mission has.

Ships follow the same paths by Ship Follow Curve and its backwards twin
([Following a path](orders.md#following-a-path)).

A point, a ship of kind `0x3E3`, marks a place on a curve where its record names the curve and the
share of the way along it ([Ships](../formats/dte.md#ships)). `curve_next_marker` (`0x00457510`)
finds the nearest place past a share, and the last point that marks the share itself.

## A shot

`director_begin_shot` (`0x00450D10`) takes the shot's seconds, whole, as ticks, a hundred a second
(`director_ticks`, `0x00525250`), measures its path (`director_path_length`, `0x00525254`), notes
where the ship its path rides along with stands, and begins the path's first curve
(`director_begin_curve`, `0x00450D90`). Each curve has its share of the ticks, as its length is to
the path's, or all of them for a path of no length (`director_curve_ticks`, `0x00525258`). Over it
the camera turns from the yaw and the pitch of the ship it starts at to those of the ship it ends
at, as the mission's ship records hold them, a whole turn on where either is less. A shot at a ship
takes that ship's for both. The shot's first curve switches to view 13, held and forced.

Once a frame in view 13 (`director_frame`, `0x00450FA0`), the curve's ticks run on by the frame's,
and with `t` their share of its own:

- The camera stands at the curve's point `t` of the way along, or where the ship it stands at is
  (`director_place`, `0x004511A0`). Where the path rides along with a ship, the camera is carried by
  how far the ship stands from where the mission placed it (`curve_ride`, `0x004574A0`).
- Past a place a point marks on the curve, the point has its CameraReached (`event_camera_reached`,
  `0x00451180`), one place a frame (`director_progress`, `0x004510C0`).
- The camera looks at the ship it tracks. With none, it turns by the yaw about `Y` and then the
  pitch about `X`, each `t` of the way from the curve's first to its last.
- From `t` of 1 on, the curve is over (`director_curve_end`, `0x00450F20`): the ship it ends at has
  its CameraReached, and the curve that carries the path on begins, its ticks from nothing. With
  none, the camera goes back to view 0, the player's cockpit, forced.

**Fix:** the game divides by nothing for a curve its shot gives no ticks, which places the camera
nowhere; OpenReliant takes it to the curve's end. At a curve that ends at no ship, the game posts
CameraReached on what lies past the mission's ships, reads the angles to turn to from there, and
carries the path on to a curve that starts or ends at none; OpenReliant turns by the start's angles
alone, and ends the path there, as its length has it. For a shot with neither curve nor ship, the
game reads a ship at address zero; OpenReliant holds the camera where it is, level.

**Improvement:** with smooth motion, the camera stands and turns as far on as the frame is drawn
past its tick, and where the ships are drawn, so that it moves on every frame, as they do.

## The ships a shot holds

As the camera switches to view 13, `camera_set_view` marks each ship of the shot's ship, flight group
or squad jumping (`camera_hold_ships`, `0x0045EC40`, a squad's in `0x0045EAD0`), and as it switches
away, lets them go. A jumping ship stays where it is and does not fire ([Jumps](jump.md#jump-out)).

## The curves' ships

As the script starts (`mission_script_start`, `0x0045CBC0`), each ship that a curve starts at has
the first such curve's ships made, where the start part has not made them (`mission_ship_create`):
the ship it starts at, the two its tangents are drawn to, and the ship it ends at. Each point is a
marker at its place, turned as its record has it, whose angles the mission's ship records then keep
(`mission_ships_sync`) for the director to turn by.

**Fix:** the game takes the object past its array for a curve that names no ship; OpenReliant passes
over it.

`0x004573B0` makes a curve afresh from its four ships' places, on a message that comes through the
shared memory the game watches (`FileMappingObject`, `0x00457730`). OpenReliant keeps the record as
it stands.
