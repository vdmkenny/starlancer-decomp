# Platform

The `openreliant` executable runs the game on SDL3, which stands in for everything the original takes from Windows: the Win32 window and message loop, DirectDraw and Direct3D 7, and DirectInput. The game's own code, under [`src/engine/`](../../src/engine), reaches the platform only through [`src/platform/`](../../src/platform), so the same code builds for macOS, Linux and Windows.

| Module | In place of |
|---|---|
| [`platform/window.zig`](../../src/platform/window.zig) | The window and message loop `WinMain` runs, and the flip to the screen |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7's device, `IDirect3DDevice7`, which the driver draws with ([Renderer](renderer.md#the-gpu-device)) |
| [`platform/keyboard.zig`](../../src/platform/keyboard.zig) | DirectInput's keyboard: SDL's scan codes as DirectInput's (`DIK_*`) |
| [`platform/joystick.zig`](../../src/platform/joystick.zig) | DirectInput's joystick: SDL's joysticks and gamepads as the device the game reads into `DIJOYSTATE` |
| [`platform/audio.zig`](../../src/platform/audio.zig) | The wave-out device Miles played through; OpenAL Soft or OpenReliant's own mixer plays the game's sound into it ([Sound](sound.md)) |
| [`platform/openal.zig`](../../src/platform/openal.zig) | Miles's 3D providers: the game's sound calls played by OpenAL Soft ([Sound](sound.md#openal-soft)) |
| [`platform/macos.zig`](../../src/platform/macos.zig) | Nothing: what macOS needs before SDL starts |
| [`openreliant/main.zig`](../../src/openreliant/main.zig) | `WinMain`: opening the game's files and running the frame loop |
| [`openreliant/install.zig`](../../src/openreliant/install.zig) | The installer on disc 1, `SETUP.EXE`: unpacking `LANCER.CAB` and copying the disc's `GAME/CAB` files |

SDL comes from the [castholm/SDL](https://github.com/castholm/SDL) package, which builds it from source for the target, so no SDL has to be installed. `build.zig` translates its header into the `sdl` module the platform layer imports. OpenAL Soft is built from source the same way, by [`deps/openal-soft`](../../deps/openal-soft/build.zig), into the `al` module.

## Running

```bash
make play                                      # optimized, for the host, on game/install
zig build -Doptimize=ReleaseFast               # zig-out/bin/openreliant
zig build -Doptimize=ReleaseFast -Dstrip       # without debug information, as released
zig build -Dtarget=x86_64-windows              # openreliant.exe
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos               # Apple silicon, from any Zig
```

`openreliant [<game-directory>] [<option>...]` runs in the game's installed directory, or the one given, and reads `resource.hog` and `tcachehw.dat` from it as the original does ([`bigfile.zig`](../../src/engine/game/bigfile.zig)). It has no data of its own: without those files it reports what it needs and exits.

`openreliant --help` lists the options in the groups below, the keys OpenReliant adds, and the commands; each command's `--help` shows its own. An invalid option or value is named in one line, and `openreliant` exits with status 2. The page comes from one table in [`main.zig`](../../src/openreliant/main.zig), which the compiler holds to having help for every option, and [`help.zig`](../../src/openreliant/help.zig) wraps it to 80 columns at compile time.

**The original.** OpenReliant improves on the original's look and sound; `--original` turns the improvements off, and an option after it turns one back on.

| Option | Does |
|---|---|
| `--original` | The original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, motion that moves on with the game's ticks, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings and particles as few and plain as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, the shields' bubbles as coarse as the original's, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the marker for a target out of sight placed as the original misplaces it, and sound mixed plainly in stereo with no master bus |

**The mission.**

| Option | Does |
|---|---|
| `--mission <number>` | The mission to play, by the number the game names its file by; 0, OpenReliant's own sandbox, by default |
| `--ship <type>` | The ship type to fly, by its number in `shipstats.bin`, in place of the loadout screen's choice; the mission's own by default |
| `--view <0\|1\|2>` | The view it starts in, as the game's settings keep it: 0 the cockpit, the default; 1 the chase view; 2 no cockpit |
| `--difficulty <easy\|medium\|hard>` | The game's difficulty: how hard hits land on your ship, and shots on the enemy; medium by default, as in the game |
| `--music <file>` | A piece of `music` to play from the start, until the mission's script plays its own; none by default |

**Display.**

| Option | Does |
|---|---|
| `--fullscreen` | Fills the display |
| `--size <width>x<height>` | Draws frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display |
| `--fps <rate>` | Frames a second at most; 0 for no limit |
| `--no-vsync` | Draws without waiting for the display |

**Graphics.**

| Option | Does |
|---|---|
| `--software` | Draws on the software device, OpenReliant's reference, at the window's size in points |
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default |
| `--no-bloom` | Draws without the bloom around bright things |
| `--no-dither` | Draws without dithering 32-bit colour |
| `--no-pixel-lighting` | Lights each vertex rather than each pixel, as the original does |
| `--no-smooth-motion` | Moves what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame |
| `--few-shot-lights` | Lights only the latest two of the player's shots and the latest two of everyone else's, as the original does |

**Sound.**

| Option | Does |
|---|---|
| `--hrtf` | Places the sounds for headphones, through a head-related transfer function, whatever the output; by default they are while the output is headphones |
| `--no-hrtf` | Places the sounds for speakers, whatever the output |
| `--no-reverb` | Plays the 3D sounds and the cockpit's warnings without reverb |
| `--no-compressor` | Leaves the master bus's compressor out, keeping its limiter |
| `--no-sound` | Runs without sound |

**Other.**

| Option | Does |
|---|---|
| `--screenshot <file.png>` | Draws one frame, with the camera settled, to a PNG and quits |
| `--version` | Shows the version |
| `-h`, `--help` | Shows the options |

It plays a mission ([Missions](../engine/missions.md)), drawn through the ported pipeline and driver with the GPU ([Renderer](renderer.md)): the game's mission that `--mission` names, read as the game reads it, or by default mission 0, OpenReliant's own sandbox. Mission 0 is a standard mission file, which the build writes from [`mission0.zig`](../../src/openreliant/mission0.zig) and installs as `missions/mission0.dte` beside `bin`, for `sltool` and the original, and which `openreliant` carries and plays where the game has no mission 0. Its scene: the Reliant at the origin, facing along Z, from whose first four tubes the player's ship and three wingmen, listed in the player's wing, launch ([Launches](../engine/launch.md)); ahead, a wing of four Sabres facing the Reliant, and beyond them the Badanov, the smallest of the Coalition's capital ships, turned across the way. Past the Badanov, outside the action's sphere, lies a little field of twelve rocks, the seven asteroids in turn, placed and turned from a fixed seed. Its script's start part makes the Reliant's flight group, then every other, sets the rocks tumbling in place under Random Spin Slow, plays the launch's music and starts the wing's launch, as mission 1 does. Meanwhile the Reliant and the Badanov hold their fire (`DisableGuns`): the Huge Guns lead a target up to a quarter of their shots' life away, which reaches well past the Badanov, and would fire over the launch beside the player's hangar. Once the wing is out, it frees their guns and gives the ships their orders ([Orders](../engine/orders.md)): the Reliant and the Badanov under Fly at a tenth of the Reliant's speed, the Sabres under Fight against the player and each wingman against a Sabre, and the mission's music follows the launch's. The player's ship flies under Player Control, which is its own controls, once its launch ends. The Sabres' pilot is record 42 of `pilotstats.bin`, one of its weakest, where `create_object` gives a Sabre the sharp pilot of record 66, so the player's missiles mostly get past their countermeasures, and an ejected pilot fares each way as likely. The game's own bindings drive the camera ([Controls](../engine/controls.md), [Camera](../engine/camera.md)): keys 1 to 8 pick the cockpit, left, right, rear, flyby, target, external and missile views, the cockpit key cycles the cockpit mode while in it, and in the target and external views the arrow keys orbit and Shift with up or down zooms. Added for OpenReliant ([`test_keys.zig`](../../src/openreliant/test_keys.zig)): F2 and F3 start the mission again with the loadout's ship the previous or next ship type, passing over any whose files the game lacks, F4 brings another wing of Sabres in front of the player, and Alt and Enter switch between the window and the full screen. Escape opens the game's [pause menu](../engine/pause-menu.md), whose LEAVE MISSION quits and whose RESTART starts the mission again. With no front end yet, the mission starts in that menu; CONTINUE, or Escape, starts the flying, and `--no-pause-menu` skips it. Once the mission is over, the camera having watched the player's ship's [end](../engine/objects.md#destruction) or the mission's script having ended it, the mission starts again in the same ship, where the game would go to its debriefing. A ship that does not launch is shown in view 0 in the cockpit mode the options' setting picks, or, in the chase mode where its own radius is larger than the distance that view sits behind it, in the external view, which orbits at a distance worked out from its size, so that a capital ship or a station is seen whole.

A Zig built for Intel Macs runs under Rosetta on Apple silicon and builds for Intel by default; `make play` asks for Apple silicon, and `build.zig` then hands SDL and the linker the SDK's paths from `xcrun`.

## Installing the game's files

`openreliant install [--from <disc>]... [--force] <directory>` makes the same install as a full install with the original installer, without writing to the registry or the system's folders:

1. From disc 1, it unpacks `LANCER.CAB` into the directory, without the cabinet's top-level `CAB` folder, and copies the files from the disc's `GAME/CAB` folder next to them.
2. It copies disc 1's archive, `GAME/CD1.HOG`, next to them as `CD1.HOG`.
3. It copies disc 2's archive, `GAME/CD2.HOG`, as `CD2.HOG`.

The result is the directory `openreliant` runs from, and it is the same on every system. The discs' archives hold the videos, the music and the later missions. `make game` uses the installer to create `game/install`. For user walkthroughs, see [User guide: Installation](../guide/installation.md).

A disc can be a disc image, raw (`.bin`) or cooked (`.iso`), which is read with the project's own readers ([Disc images](../formats/disc-images.md)), or a folder with the disc's files, which is how a mounted disc appears. `--from` names one, and is given once for each disc, in either order. File names on a disc are matched case-insensitively, as on Windows, because Linux shows discs without Joliet names, like StarLancer's, in lower case. The files copied from the discs get upper-case names, as on the discs, so the engine finds `LANGUAGE.DLL` on every system.

Without `--from`, the installer searches the drives for the discs:

| System | Where it looks |
|---|---|
| Windows | CD drives that contain a disc, including mounted disc images |
| Linux | Mount points of ISO 9660 and UDF file systems, read from `/proc/self/mounts` |
| macOS | The volumes in `/Volumes` |

It installs from disc 1, then looks for disc 2. When disc 2 is not in a drive and the installer runs in a terminal, it asks for disc 2 and looks again each time Enter is pressed, until disc 2 is found or `skip` is typed. At a terminal, copying an archive shows how far it has progressed. On Windows the installer finds the console with `GetConsoleMode`, which also works under Wine, where the standard library's check reports none.

Without disc 2, the install proceeds without its archive and explains how to add it: disc 2 alone, named or in a drive, adds its archive to the existing install in the directory.

It identifies the discs by their files:

| Disc | Identified by |
|---|---|
| Disc 1 of a known release | `LANCER.CAB` with that release's size: 226,746,308 bytes for the North American release |
| Disc 1 of another release | `LANCER.CAB` with any other size; only installed with `--force` |
| Disc 2 | The volume label `SL_CD2`, or `GAME/CD2.HOG` |

With disc 1 in more than one drive, a known release is selected over an unknown release.

The install halts if a filename in the cabinet would extract outside the target directory. Once disc 1 is installed, the installer verifies that startup files needed by the engine are present, and reports the first missing file.

The original game reads its paths from the registry key `HKLM\Software\Microsoft\Microsoft Games\Starlancer\1.0` (`install_paths_read`). For a full install (`InstallType` 3) or when the key is absent, it opens `cd1.hog` and `cd2.hog` from the installation directory (`cd_hog_open`) rather than from the CD in the drive.

The cabinet is unpacked with [libarchive](https://libarchive.org), which [`deps/libarchive`](../../deps/libarchive) builds from source for the target, using the build script of the [allyourcodebase/libarchive](https://github.com/allyourcodebase/libarchive) package with libarchive pinned to the 3.7.9 release. The LZX decoder in libarchive 3.8.9 fails on `LANCER.CAB` ([libarchive#3542](https://github.com/libarchive/libarchive/issues/3542)).

## Missions

`openreliant missions [<game-directory>]` ([`missions.zig`](../../src/openreliant/missions.zig)) lists the missions a game's folder holds, the loose files in its `missions` folder and the members of `resource.hog`, with OpenReliant's own mission 0, built in, where the game has none, and reads and binds each as a mission's start does ([Missions](../engine/missions.md)), showing where each comes from and what its file holds: its counts of ships, flight groups, triggers and script bytes, its format flags, and the ship type and name of the player's own record. It exits with status 1 where a mission fails to bind, so a mission of one's own can be checked before it is played. `make check-missions` runs it on `game/install`.

## Joysticks and gamepads

[`platform/joystick.zig`](../../src/platform/joystick.zig) replaces DirectInput's joystick support. Each controller that SDL detects is presented to the game as a DirectInput-style joystick device (`engine.input.JoystickDevice`). As in the original, the game sets a range for each axis it uses and a dead zone for the device, and reads the device into a `DIJOYSTATE` at every simulation step ([Controls](../engine/controls.md#devices)). [`docs/guide/controllers.md`](../guide/controllers.md) is the user guide.

- SDL reports axes from -32768 to 32767. The platform maps them to the range the game set, applying the dead zone the way DirectInput does: inside the dead zone the axis reads as the center of its range, and outside it the remaining travel is scaled to cover the full range.
- Hats are converted to DirectInput point-of-view values: hundredths of a degree clockwise from forward, or centered. Opposite directions pressed together cancel out.
- `DIJOYSTATE` has room for 32 buttons and four hats; any beyond that are ignored.

The game uses one controller at a time, selected by `platform.joystick.choose`: if `Joystick` is set in `JoyConfig`, the first controller whose name contains that text; otherwise the first joystick that is not a gamepad or a standalone throttle, then the first gamepad. When a controller is connected or disconnected, SDL sends an event, and the driver selects the controller again and reloads the settings with `load_key_config`, since bindings depend on the controller type. A controller that is disconnected reads as centered, with no buttons pressed.

### Joysticks

SDL numbers a joystick's axes in the same order on every system (X, Y, Z, Rx, Ry, Rz, then sliders), but does not report which of these axes a given joystick possesses. The platform therefore guesses the throttle and twist axes from the count of axes, based on common hardware:

| Axes | X | Y | Throttle | Twist | Typical device |
|---|---|---|---|---|---|
| 2 | 0 | 1 | | | Old gameport sticks |
| 3 | 0 | 1 | 2 | | Sticks with a throttle wheel |
| 4 | 0 | 1 | 3 | 2 | Most flight sticks: X, Y, twist and a throttle slider |
| 5 | 0 | 1 | 2 | 3 | HOTAS sets |
| 6 or more | 0 | 1 | 2 | 5 | HOTAS sets with X, Y, Z, Rx, Ry and Rz |

If SDL identifies the device as a standalone throttle, its first axis is the throttle. If SDL identifies it as a gamepad but has no mapping for it, axis 2 is the twist and there is no throttle. The game receives the throttle as its Z axis and the twist as Rz. `ThrottleAxis` and `TwistAxis` in `JoyConfig` override the guess with an SDL axis number, or -1 for none. `ThrottleInvert=1` reverses the throttle, for levers that report their highest value when pushed forward.

### Gamepads

A controller that SDL maps as a gamepad is presented to the game as a joystick with a fixed layout (`input.GamepadButton`): the left stick is X and Y, the right stick's horizontal axis is the twist, the D-pad is the hat, and there are 32 buttons. Buttons 0 to 25 are SDL's gamepad buttons in SDL's order, 26 and 27 are the triggers (pressed past a quarter of their travel), and 28 to 31 are the right stick's four directions (pushed past half). Gamepads have no throttle axis, so the throttle is controlled with ACCELERATE and DECELERATE, which gamepads bind to the right stick's up and down.

SDL's built-in database covers Xbox, PlayStation and Nintendo controllers and many others. A `gamecontrollerdb.txt` file in the game folder can add mappings, in SDL's format, for gamepads SDL does not recognize.

### Improvements

Deliberate differences from the original's joystick support:

- Gamepads get their own default bindings (`input.gamepad_buttons`) and have `TwistEnable` on by default, so the right stick rolls. The original treated a gamepad like any other joystick.
- A joystick is preferred over a gamepad. The original preferred joysticks with force feedback.
- Any controller that rumbles plays the force-feedback effects as rumble, gamepads among them, where the original played them on a force-feedback joystick alone ([Controls](../engine/controls.md#force-feedback)). The `ForceFeedback` setting in `starlancer.ini` turns them off.
- Controllers can be connected and disconnected while the game runs. The original only looked for a joystick at startup.
- The `DeadZone`, `Joystick`, `ThrottleAxis`, `TwistAxis` and `ThrottleInvert` settings and the `gamecontrollerdb.txt` file are new; the original game ignores them.
- Two bugs in how `load_key_config` reads bindings are fixed ([Controls](../engine/controls.md#bindings)).

### Listing controllers

`openreliant joysticks [<game-directory>] [--watch]` lists the connected controllers, shows which one the game will use and the `Joystick=` setting that picks each, and for joysticks which axis is used for what, marking whether the throttle's and the twist's come from `starlancer.ini` or the automatic choice. It reads the settings from the game's `starlancer.ini`. With `--watch`, it shows the selected controller's state as the game sees it until you press Ctrl+C: the values the game reads, the buttons held down by number, with a gamepad's name for each, and for a joystick every axis by its number, as a share of its travel, with what the game uses it for. On a terminal it redraws the view in place with ANSI escape codes, each line cut to 79 columns so that it does not wrap; otherwise, as into a file, it prints each view that differs from the last after a blank line.

### Testing

The unit tests in `platform/joystick.zig` use SDL's virtual controllers, modelled on real devices, on every system. `make test-controllers` also tests the Linux path end to end: in a privileged Docker container, [`scripts/controllers`](../../scripts/controllers) creates kernel virtual devices (uinput) with the USB IDs, names, axes and buttons of real controllers (an Xbox 360 controller, a DualShock 4, a Logitech Extreme 3D Pro, a Saitek X52, a gameport stick and an unknown gamepad), and checks what `openreliant joysticks` reports for each of them.

## Builds and releases

Changes go to `main` through pull requests. Each pull request, and each push to `main`, builds the executables and runs the tests on Linux, macOS and Windows ([`tests.yml`](../../.github/workflows/tests.yml)), next to the check that no game files are committed ([`check-files.yml`](../../.github/workflows/check-files.yml)). `main` is protected: a pull request needs those four checks to pass before it can be merged. Pull requests are squash merged, so the pull request's title becomes the commit on `main` and has to follow Conventional Commits too. A pull request that finishes an issue says `Closes #N` in its description.

Releases come from [release-please](https://github.com/googleapis/release-please) ([`release.yml`](../../.github/workflows/release.yml), [`release-please-config.json`](../../release-please-config.json)). Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat` for a new feature, `fix` for a bug fix, `docs` for documentation, and `build`, `ci`, `chore`, `perf`, `refactor` or `test` for the rest, with a `!` after the type for a breaking change. From these, release-please keeps a release pull request open with the next version and the changelog so far. Before 1.0, a feature raises the minor version, a fix the patch version, and a breaking change the minor version.

Merging the release pull request updates [`CHANGELOG.md`](../../CHANGELOG.md) and the version in `build.zig.zon`, tags the version, and publishes a GitHub release with that version's changelog as its notes. The workflow then builds `openreliant` for each system and attaches the archives:

| Archive | Built on | Target |
|---|---|---|
| `linux-x86_64.tar.gz` | Linux | `x86_64-linux-gnu` |
| `linux-aarch64.tar.gz` | Linux | `aarch64-linux-gnu` |
| `windows-x86_64.zip` | Windows | `x86_64-windows-gnu` |
| `windows-aarch64.zip` | Windows | `aarch64-windows-gnu` |
| `macos-x86_64.tar.gz` | macOS | `x86_64-macos` |
| `macos-aarch64.tar.gz` | macOS | `aarch64-macos` |

Run by hand from the Actions tab, the workflow builds all six and keeps the archives as the run's artifacts, but publishes nothing.

The build gives `openreliant` its version ([`version.zig`](../../src/openreliant/version.zig)), which `--version` and the top of `--help` show. It is the version in `build.zig.zon`, followed by what `git describe` says of the checkout as SemVer build metadata when it is not exactly a release:

| Checkout | Version |
|---|---|
| The release's tag | `0.2.0` |
| 12 commits past it | `0.2.0+12.gabc1234` |
| With uncommitted changes | `0.2.0+12.gabc1234.dirty` |
| No git or no tags, as in a source archive | `0.2.0` |

Each archive holds the executable, the README, the license and the changelog, and no game files. Every build names its target explicitly, so it is built for its architecture's baseline processor and runs on any machine of that kind. The Linux builds need glibc 2.31 or newer, and SDL loads the display, sound and input libraries at run time. The macOS builds are not signed, so macOS blocks them until the quarantine flag is removed with `xattr -d com.apple.quarantine openreliant`.

release-please opens its pull request with the workflow's own token, which needs "Allow GitHub Actions to create and approve pull requests" turned on in the repository's Actions settings. GitHub does not run workflows for pull requests opened with that token, so the release pull request never gets its checks, and an admin merges it past the branch protection.

## Frames

The window is drawn into at the display's own density. With vsync, the default, the display paces the frames: each waits for the display the window is on, at its refresh rate. Without it, frames are held to that display's refresh rate, or to `--fps`; `--fps` holds them to its rate with vsync too. The game's clock ticks 100 times a second, so past 100 frames a second some frames show the same moment of the game; objects move on every fourth tick ([Game loop](../engine/loop.md)).

SDL's GPU interface runs on Metal on macOS and on Vulkan on Linux and Windows: the game's shader comes as SPIR-V and in Metal's language, not as DXIL for Direct3D 12.

## macOS

Launched, AppKit looks for windows of an earlier run to restore before SDL's own setting against it takes effect, which can hold the first frame back by seconds. `macos.zig` registers `ApplePersistenceIgnoreState` for the run before SDL starts, as SDL itself does later.
