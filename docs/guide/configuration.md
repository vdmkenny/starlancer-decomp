# Configuration and options

Pass options when running `openreliant`:

```bash
./openreliant [<game-directory>] [<option>...]
```

If omitted, `game-directory` defaults to the current working directory `.`.

## The original

OpenReliant improves on the original's look and sound. `--original` turns the improvements off, and an option after it turns one back on.

| Option | Description |
|---|---|
| `--original` | The original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no shadows, motion that moves on with the game's ticks, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, and the sound mixed plainly in stereo |

## The mission

| Option | Description |
|---|---|
| `--mission <number>` | The mission to play, by the number the game names its file by, `mission<number>.dte`, from the game's `missions` folder or `resource.hog`; 0 by default, OpenReliant's own sandbox, which `openreliant` carries where the game has no mission 0 |
| `--ship <type>` | The ship type to fly, by its number in `shipstats.bin`, in place of the loadout screen's choice, with its default missiles; the mission's own by default, the Predator in mission 0 |
| `--view <0\|1\|2>` | The view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the pause menu's video screen changes, or 0 without them |
| `--difficulty <easy\|medium\|hard>` | The game's difficulty: how hard hits land on your ship, and shots on the enemy; medium by default, as in the game |
| `--music <file>` | A piece from the game's music folder to play from the start, until the mission's script plays its own; none by default |
| `--no-pause-menu` | Start flying immediately, where the mission otherwise starts in the game's pause menu |

## Display

| Option | Description |
|---|---|
| `--fullscreen` | Fill the display; Alt and Enter switch while playing |
| `--size <width>x<height>` | Draw frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display |
| `--fps <rate>` | Frames a second at most; without vsync, the display's rate by default; 0 for no limit |
| `--no-vsync` | Draw without waiting for the display |

## Graphics

| Option | Description |
|---|---|
| `--software` | Draw on the software device, OpenReliant's reference, rather than the GPU |
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel, for smooth edges; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default (trilinear, sixteen times anisotropic, and magnified with a Catmull-Rom filter) |
| `--no-bloom` | Draw without the bloom around bright things |
| `--no-dither` | Draw 32-bit colour without dithering |
| `--no-pixel-lighting` | Light each vertex rather than each pixel, as the original does |
| `--gamma-space` | Light, blend and filter the encoded colours, as the original does, rather than in linear light |
| `--shadows <off\|low\|high>` | Shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel |
| `--no-cockpit-shadows` | Leave the shadows out of the cockpit, keeping them on the ships |
| `--no-smooth-motion` | Move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame |
| `--few-shot-lights` | Light only the latest two of the player's shots and the latest two of everyone else's, as the original does |

## Sound

| Option | Description |
|---|---|
| `--hrtf` | Place the sounds for headphones whatever the output; by default they are while the output is headphones |
| `--no-hrtf` | Place the sounds for speakers whatever the output |
| `--no-reverb` | Play the sounds around you and the cockpit's voice without reverb |
| `--no-compressor` | Leave the mix's loudness as it is, only keeping its peaks in check |
| `--no-sound` | Play without sound |

## Other options

| Option | Description |
|---|---|
| `--screenshot <file.png>` | Draw one frame, with the camera settled, to a PNG, and quit |
| `--screenshot-ticks <ticks>` | With `--screenshot`, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default |
| `--version` | Show the version |
| `-h`, `--help` | Show the help page |

## Commands

| Command | Description |
|---|---|
| `openreliant install` | Install the game's files from the StarLancer discs into a directory |
| `openreliant joysticks` | List the joysticks and gamepads, and which one the game uses |
| `openreliant missions` | List the game's missions, its own and those added to its `missions` folder, and check that each loads |

Each command's `--help` shows its options.

### Missions of your own

A mission file named `mission<number>.dte`, stored expanded, in the `missions` folder of the game's directory plays in place of that mission, as it does in the original: the game reads a loose file before its own copy in `resource.hog`. The retail game ships two, `mission18.dte` and `mission25.dte`. Check that a mission loads with:

```bash
./openreliant missions StarLancer
```

It lists every mission, where each comes from (`loose` or `archive`), and what its file holds, including the ship type and name of the player's own record, and says which fail to load. A mission can carry a name for OpenReliant to show, in a section of the file the original game ignores: see [OpenReliant's mission name](../formats/dte.md#openreliants-mission-name).

## In-flight keys

The flight keys are the game's own, as `starlancer.ini` binds them. OpenReliant adds:

| Key | Action |
|---|---|
| F2, F3 | Start the mission again in the previous or next ship type |
| F4 | Bring in another wing |
| Alt+Enter | Switch between windowed and fullscreen mode |
| Escape | Open the pause menu, whose LEAVE MISSION quits and RESTART restarts |
| 1 to 8 | Camera views: 1 cockpit, 2 left, 3 right, 4 rear, 5 flyby, 6 target, 7 external, 8 missile |

In the target view (6) and external view (7), arrow keys orbit around the object and Shift with Up or Down zooms.

## Configuration file (starlancer.ini)

Settings are read from `starlancer.ini` in the game directory:

```ini
[KeyConfig]
JoystickInvert=1
TwistEnable=1
HatEnable=1
Controller=0

[JoyConfig]
DeadZone=5
Joystick=Extreme 3D
ThrottleAxis=3
TwistAxis=2
ThrottleInvert=0
```

See [Controllers and input](controllers.md) for detailed controller options.
