# Camera

The views the game shows and where each puts the camera: `camera.cpp`, with the projection from Surrender's `srAPI.cpp`. [`src/engine/game/camera.zig`](../../src/engine/game/camera.zig) and [`srapi.zig`](../../src/engine/surrender/surrenderlib/srapi.zig) state the same rules.

## Projection

`sr_set_projection` (`0x004C3A60`) takes a viewport, its edges as fractions of the screen, and a factor across and one down. A point at `(x, y, z)` in the camera's frame falls on the screen at:

```
(width / 2 + x / z * (width - 0.1) * across, height / 2 + y / z * (height - 0.1) * down)
```

whatever the viewport; the viewport only bounds what is drawn. Every view but one uses the factors 0.6 and 0.8: the screen spans 5/6 of a view unit either side of the middle across and 5/8 up and down, about 80 by 64 degrees, with square pixels on a 4:3 screen. View 0x20, a launch's bay, uses 0.35 and 0.467, about 110 degrees across, over the whole screen whatever the bars.

The game runs in the display modes the device lists, which it keeps in `dmodes.bin`, and starts at 640x480.

OpenReliant keeps the factor down and chooses the factor across that keeps pixels square, `0.8 * (height - 0.1) / (width - 0.1)`: on a 4:3 screen the game's 0.6, on a wider one a wider view.

## Views

`camera_view` (`0x539A34`) holds the view and `camera_object` (`0x539A8C`) the object it shows. `camera_set_view` (`0x0045F1B0`) switches view and places the camera at once; `camera_frame` (`0x0045FC90`) places it once a frame. Views from 7 on are the game's cutaways, of launches, landings, jumps and deaths among others.

| View | Key | Camera | Named |
|---|---|---|---|
| 0 | Cockpit | From the cockpit, ahead, as the cockpit mode says | Cockpit View |
| 1, 2, 3 | Left, right, rear view | From the cockpit, turned -90, 90 and 180 degrees about the ship's down axis | Left View, Right View, Rear View |
| 4, 0x1E | | Chase | a space |
| 6 | Target | Round the player's target | Target Camera |
| 0xC | External | Round the player's ship | External Camera |
| 7 | | Round the pilot's pod as the pilot ejects ([The ejection's views](#the-ejections-views)) | Eject Camera |
| 8 | | Behind the object, turning with it about its own `Y` at 0.005 a tick and pulling away from 3000 at 10 a tick, as the player's ship is destroyed | Death Cam |
| 0x12 | Missile | Behind a missile the object launched ([Missiles](missiles.md#the-missile-camera)) | Missile Camera |
| 0x1A | | From where the camera was, watching the object | a space |
| 0x1B | | From where the camera was, watching where the player's ship burst (`explode_marker`), which drifts on at a quarter of its velocity a frame | a space |
| 0x1C | | Round the ship picking up the player's pod, closing in | a space |
| 0x1D | | From behind the player's pod, at the Sabre that shoots it down | a space |
| 0x17 | | Close ahead of the player's ship and above it, looking back at it as it jumps in ([The jumps' views](#the-jumps-views)) | a space |
| 0x18 | | Far ahead of where the player's ship jumps in, held | a space |
| 0x19 | | Beside where the player's ship jumps in, watching it | a space |
| 0x27 | | Out along each of the player's ship's axes, watching it jump out | a space |
| 0x20 | | From within a launch's bay, beside the ship, looking down after it as it drops ([Launches](launch.md#the-cutaways)) | a space |
| 0x21 | | From far below a launching ship, looking up at it | a space |
| 0x22 | | From beside and below a launching ship, looking at it, the whole scene shown | a space |
| 0x24 | Flyby | From a point the player flies past | a space |
| 0xD | | Along the mission's curves, or at a ship, for the script's shots ([The director's view](#the-directors-view)) | a space |

The view table (`camera_view_table`, `0x4F72A8`) holds four bytes a view, for views 0 to `0x2B`: the language string that names the view, whether cinematic bars slide in, and whether it is from the cockpit. [`camera/views.zig`](../../src/engine/game/camera/views.zig) transcribes it; `make view-tables` derives it again. The bars slide in for views 7 to `0x27` and `0x2B`, but not the external view; views 0 to 3 are from the cockpit. The names are strings 170 to 182 of `language.dll`; string 174, Chase Camera, is none of them, the chase views and most cutaways taking 181, a single space. From the cockpit the object's flag bit 0 is set, except in the chase mode, and cleared when the view moves off it. The bars grow by 0.001 of the screen a tick to 0.1, top and bottom; a view without them clears them at once.

`camera_locked` (`0x539ACC`) holds the camera for a script: `camera_set_view` refuses a switch unless forced, and the camera keys do nothing. `frame_controls` (`0x00414060`), once a frame, maps the camera keys to views. The cockpit key, pressed in the cockpit view, first moves `cockpit_mode` (`0x539A9C`) on:

| Mode | Cockpit view |
|---|---|
| 0 | From the eye, no cockpit drawn |
| 1 | From the eye, the cockpit's model drawn over the view |
| 2 | The chase view |

The options' cockpit setting (`cockpit_mode_setting`, `0x5D5A78`), which the game keeps in its ini as `[Device] View` and reads as 0 when the ini has none, picks the mode: 0 for mode 1, 1 for mode 2 and any other for mode 0. A mission's start sets the mode it picks (`mission_start`, `0x0049359E`). The Reliant's launch holds the camera in view 0 in mode 1 from its start, shows one of three cutaways, views `0x20` to `0x22`, and at its last step sets the mode the setting picks and switches from a cutaway to view 0, no longer held ([Launches](launch.md#the-reliants-launch)). Resuming from the pause (`game_pause`, `0x00491E20`) switches to view 0 again when the setting changed while paused.

OpenReliant keeps the setting with the camera, which `--view` sets. A ship that does not launch starts in view 0; one too large for the chase mode's distance starts in the external view instead, as OpenReliant flies ships the game never gives the player.

## Cockpit

The camera's orientation is the ship's turned by the view's angle, and its position the ship's plus the model's eye point, the `.SHP` header's vector at `0x08`, turned likewise, so the rear view looks back from behind the ship. The Kamov (ship type 0x2D) looks back from 1500 behind it instead.

In view 0 outside the chase mode, `camera_frame` also moves the cockpit's model ([`rendering.md`](rendering.md#the-cockpit)), whose root hangs from the camera's frame. With each of the ship's rates of turn taken over its flight model's full rate, and its speed over its cruise speed, each held between -1 and 1:

- The root turns by the pitch rate times -0.1, the yaw rate times -0.15 and the roll rate times -0.1, so the cockpit sways against a turn, and stands at 50 times the speed along `Z` less the cockpit model's own eye point, so that the eye is at the camera and the cockpit slides back as the ship speeds up.
- The hands, the model's second part, turn by the pitch rate times 0.15 in pitch and the roll and yaw rates together times 0.2 in roll, about their part's mount point; they stand at their part's position less the object's centre, less 30 along `Z` times the guns' kick (`0x005636E0`), which the player's guns set to 1 as they fire (`0x0047BE3A`) and which loses a twentieth each frame.

Each frame, `camera_frame` first caps `hit_shake` (`0x00588724`) at 2, takes a tenth of it as the shake, and lowers `hit_shake` by 0.02 a tick. The root then jitters in yaw and roll by a random amount of up to half the shake either way, from two `rand` numbers drawn every frame, the first for the roll. While the shake is above zero, the camera also turns by a random amount of up to half of 0.03 times the remaining `hit_shake`, in the world's frame. Blows to the player's ship raise `hit_shake` (`damage_feedback`), and so does `object_move` while the player's ship flies faster than its cruise speed (see [Motion](objects.md#motion)). Before any of that, while `hit_shake` is above 0.1 and the joystick has force feedback, `camera_frame` plays the `Shake` effect on it ([Controls](controls.md#force-feedback)).

## Chase

`camera_chase` (`0x0045ED60`) puts the camera at `(0, h, d)` in the ship's frame, turned:

| Ship type | `h` | Distance at no throttle |
|---|---|---|
| 2, Grendel | -650 | 1800 |
| 8, Wolverine | -850 | 2000 |
| 9, Reaper | -800 | 2400 |
| 0x2D, Kamov | -1000 | 3400 |
| Others | -750 | 1800 |

`d` moves a tenth of the way to `-(400t + distance)` each frame, with `t` the throttle, 1.5 on the afterburner; switching to the view starts it at 1500, ahead of the ship. The camera swings against the ship's rates of turn, in radians per update: toward `-5.7` times the pitch rate, within a sixteenth of a turn and then halved when negative and one and a half times when positive, `-5` times the yaw rate and `-3` times the roll rate, within a tenth of a turn, each 5% of the way a frame, the roll adding 5% of the yaw's target too. The offset is turned by the ship's orientation, then the pitch about `X`, then the yaw about `Y`; the camera's orientation is the ship's turned by the roll about `Z`. Objects whose type is 0x100 or more have no chase view and fall back to the cockpit.

## Orbits

The target and external views put the camera at `(0, 0, d)` turned by the yaw about `Y` and then the pitch about `X`, in the world's axes, from the object, and look at it. `d` is kept between 1.8 radii of the object and 5.8 for the target or 3.8 for the player's ship; switching to either view zeroes the yaw, the pitch, their speeds and `d`.

`frame_controls` steers them from the arrow keys, fixed, whatever the bindings, in ticks of a hundredth of a second:

- Left and right change the yaw's speed by 0.1 degrees a tick, within 5 degrees a tick; then it slows by 0.05 toward 0. The yaw moves by the speed and wraps into 0 to 360.
- Shift with up or down moves the camera in or out by 60 a tick.
- Up and down change the pitch's speed likewise, which slows likewise and then keeps within 5. The pitch keeps within 89.5 degrees either way, and stops there.

The target view needs the player to have a target; without one it switches to the cockpit.

## Flyby

The flyby view starts a radius below the player's ship and four ahead, in its frame, and stays there, looking at the ship, until the ship is more than 23000 away; then it moves there again. It keeps at least a radius from the ship.

An object's radius is its farthest vertex from its origin, over its parts' finest levels (`object_bounds`, `0x00476680`).

## The ejection's views

The views of the player's [ejection](ejection.md) stand off from what they watch by an offset
(`camera_cutaway`, `0x00539A44`) that `camera_set_view` works out as it switches to them, with `t`
the ticks since:

- View 7, Eject Camera, as the pilot ejects: the object's `X` axis times 5000 (`0x0045F479`), from
  the object as it stands then. The camera stands that far out from the object, the offset turned
  about the world's `Y` by 0.005 a tick times `t`, and looks at it.
- View `0x1C`, as a nanny ship or the Antanov picks the pod up: half the way from the object, the
  ship, to the player's pod. The camera is turned as the ship, turned further about its own `Y` by
  0.002 a tick times `t` and a quarter turn (`0x004DC74C`, `0x004DC51C`), and stands back from the
  point the offset marks along its own axis ahead by `10000 - 2t`, no nearer than 1000.
- View `0x1D`, as a Sabre shoots the pod down: the way from the pod to the object, the Sabre. The
  camera stands behind the pod the other way, 1000 off, and looks at the Sabre. While the pod has
  not begun to explode the view's time holds at 0 (`camera_switched` moves on); then it pulls back
  by 20 a tick.

**Improvement:** with smooth motion, views 7, 8, `0x1C` and `0x1D` go on by the share of a tick
the frame is drawn past its tick as well (`objects.pastTick`), so they move every frame, as the
objects they watch do; the game moves them a tick at a time, which a display's frames fall between
unevenly. `--no-smooth-motion` and `--original` move them on ticks.

**Improvement:** view `0x1C`'s quarter turn is exact; the game's is 0.785398.

## The jumps' views

The player's [jumps](jump.md) switch to their views held and forced, with the player's ship as the
object. `camera_set_view` places the camera, and `camera_frame` moves it, with `t` the ticks since:

- View `0x27`, as Jump Out begins: the camera stands 8000 out along each of the ship's axes, from
  where the ship stands then (`0x0045FB18`), and looks at it.
- View `0x17`, one of Jump In's three: the camera stands 200 to the right of the ship, 500 above it
  and ahead of it by 1200, from 50 ticks on by `1200 + 10 (t - 50)`, and from 70 on by 1400
  (`0x00460EC5`), looking at it, in the ship's frame each frame. While hits shake the cockpit
  (`hit_shake`), the camera shakes with them as it does in view 0; Jump In's flight sets the shake.
  `camera_set_view` first places it 50000 ahead of the ship and 500 above it, which `camera_frame`
  replaces at once.
- View `0x18`: the camera stands 27000 ahead of the ship and 300 below it as the ship stands placed
  to fly in, 25000 behind where it arrives (`0x0045F8E7`), and holds there, looking at where the
  ship stood, level in the ship's frame: the look is taken with both points turned into the ship's
  frame, and turned out of it again.
- View `0x19`: the camera stands 2000 to the ship's left, 100 above it and 25000 ahead, likewise
  (`0x0045F91E`), and looks at the ship each frame.

`camera_set_view` moves the camera's marker (`0x00588390`) to where views `0x18` and `0x19` stand.
OpenReliant's camera keeps its own place for them, as for the flyby and target views.

**Improvement:** with smooth motion, view `0x17` pulls away by the share of a tick the frame is
drawn past its tick as well, as [the ejection's views](#the-ejections-views) do.

## The director's view

View 13 shows the shots a mission's script stacks for [the director's camera](director.md), which
flies the camera along the mission's curves or stands it at a ship. The first shot switches to it,
held and forced, and the director moves the camera each frame. Once the director has gone back to
view 0, `camera_frame` ends the shot and begins the next waiting. `camera_set_view` holds the shot's
ships still as it switches to the view, and lets them go as it switches away
([The ships a shot holds](director.md#the-ships-a-shot-holds)).

This page leaves out the cockpit's model and its motion, the shake from hits (`hit_shake`, `0x588724`) and the other cutaways.
