//! `openreliant`: the engine, on SDL3 in place of Win32 and DirectX. It has no data of its own: it
//! runs in the directory of an installed copy of StarLancer, or in the one given, and reads
//! `resource.hog` and the texture cache from it as the game does. `openreliant install` installs
//! the game's files from its discs; see `install.zig`.
//!
//! It plays a mission, which starts again as each attempt ends: by default mission 0, OpenReliant's
//! own sandbox (`mission0.zig`), which it carries, or the game's mission `--mission` names. It draws
//! through Surrender's pipeline and its Direct3D driver with the GPU, or onto the software device,
//! from the camera's views, which the game's camera keys pick and steer. Added for OpenReliant: the
//! test keys (`test_keys.zig`), and Alt and Enter, which switch to the full screen and back. Escape
//! opens the game's pause menu, whose LEAVE MISSION quits.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const stats = openreliant.stats;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const spr = openreliant.spr;
const engine = openreliant.engine;
const math = engine.surrender.math;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srtexture = engine.surrender.surrenderlib.srtexture;
const srd3d = engine.surrender.srd3d;
const game = engine.game;
const camera = game.camera;
const help = @import("help.zig");
const install = @import("install.zig");
const joysticks = @import("joysticks.zig");
const mission0 = @import("mission0.zig");
const missions = @import("missions.zig");
const test_keys = @import("test_keys.zig");
const version = @import("version.zig");

/// Everything `openreliant` takes on its command line, in the order the help page lists them.
const Arg = enum {
    @"--original",
    @"--mission",
    @"--ship",
    @"--view",
    @"--difficulty",
    @"--music",
    @"--no-pause-menu",
    @"--fullscreen",
    @"--size",
    @"--fps",
    @"--no-vsync",
    @"--software",
    @"--16-bit",
    @"--msaa",
    @"--filter",
    @"--no-bloom",
    @"--no-dither",
    @"--no-pixel-lighting",
    @"--gamma-space",
    @"--shadows",
    @"--no-cockpit-shadows",
    @"--no-smooth-motion",
    @"--few-shot-lights",
    @"--hrtf",
    @"--no-hrtf",
    @"--no-reverb",
    @"--no-compressor",
    @"--no-sound",
    @"--screenshot",
    @"--screenshot-ticks",
    @"--version",
    @"--help",

    /// The value it takes, as the help page shows it, or null for none.
    fn value(arg: Arg) ?[]const u8 {
        return docs.get(arg).value;
    }
};

/// The help page's sections, in order.
const Section = enum {
    original,
    mission,
    display,
    graphics,
    sound,
    other,

    fn title(section: Section) []const u8 {
        return switch (section) {
            .original => "The original",
            .mission => "The mission",
            .display => "Display",
            .graphics => "Graphics",
            .sound => "Sound",
            .other => "Other",
        };
    }
};

/// What the help page says of an option: its section, the value it takes, and what it does.
const Doc = struct {
    section: Section,
    value: ?[]const u8 = null,
    /// Another name for it, shown before it.
    alias: ?[]const u8 = null,
    text: []const u8,
};

/// Every option's help, which the compiler holds to having one for each.
const docs: std.enums.EnumArray(Arg, Doc) = .init(.{
    .@"--original" = .{ .section = .original, .text = "the original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no shadows, motion that moves on with the game's ticks, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, and the sound mixed plainly in stereo" },
    .@"--mission" = .{ .section = .mission, .value = "<number>", .text = "the mission to play, by the number the game names its file by, mission<number>.dte, from the game's missions folder or resource.hog; 0 by default, OpenReliant's own sandbox, which openreliant carries where the game has no mission 0" },
    .@"--ship" = .{ .section = .mission, .value = "<type>", .text = "the ship type to fly, by its number in shipstats.bin, in place of the loadout screen's choice, with its default missiles; the mission's own by default" },
    .@"--view" = .{ .section = .mission, .value = "<0|1|2>", .text = "the view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the pause menu's video screen changes" },
    .@"--difficulty" = .{ .section = .mission, .value = "<easy|medium|hard>", .text = "the game's difficulty: how hard hits land on your ship, and shots on the enemy; medium by default, as in the game" },
    .@"--music" = .{ .section = .mission, .value = "<file>", .text = "a piece from the game's music folder to play from the start, until the mission's script plays its own; none by default" },
    .@"--no-pause-menu" = .{ .section = .mission, .text = "start flying, where the mission otherwise starts in the game's pause menu, as there is no front end yet" },
    .@"--fullscreen" = .{ .section = .display, .text = "fill the display; Alt and Enter switch while playing" },
    .@"--size" = .{ .section = .display, .value = "<width>x<height>", .text = "draw frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display" },
    .@"--fps" = .{ .section = .display, .value = "<rate>", .text = "frames a second at most; without vsync, the display's rate by default; 0 for no limit" },
    .@"--no-vsync" = .{ .section = .display, .text = "draw without waiting for the display" },
    .@"--software" = .{ .section = .graphics, .text = "draw on the software device, OpenReliant's reference, rather than the GPU" },
    .@"--16-bit" = .{ .section = .graphics, .text = "16-bit colour, dithered" },
    .@"--msaa" = .{ .section = .graphics, .value = "<1|2|4|8>", .text = "samples a pixel, for smooth edges; 4 by default" },
    .@"--filter" = .{ .section = .graphics, .value = "<original|trilinear|crisp>", .text = "how textures are filtered; crisp by default" },
    .@"--no-bloom" = .{ .section = .graphics, .text = "draw without the bloom around bright things" },
    .@"--no-dither" = .{ .section = .graphics, .text = "draw 32-bit colour without dithering" },
    .@"--no-pixel-lighting" = .{ .section = .graphics, .text = "light each vertex rather than each pixel, as the original does" },
    .@"--gamma-space" = .{ .section = .graphics, .text = "light, blend and filter the encoded colours, as the original does, rather than in linear light" },
    .@"--no-cockpit-shadows" = .{ .section = .graphics, .text = "leave the shadows out of the cockpit, keeping them on the ships" },
    .@"--shadows" = .{ .section = .graphics, .value = "<off|low|high>", .text = "shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel" },
    .@"--no-smooth-motion" = .{ .section = .graphics, .text = "move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame" },
    .@"--few-shot-lights" = .{ .section = .graphics, .text = "light only the latest two of the player's shots and the latest two of everyone else's, as the original does" },
    .@"--hrtf" = .{ .section = .sound, .text = "place the sounds for headphones whatever the output; by default they are while the output is headphones" },
    .@"--no-hrtf" = .{ .section = .sound, .text = "place the sounds for speakers whatever the output" },
    .@"--no-reverb" = .{ .section = .sound, .text = "play the sounds around you and the cockpit's voice without reverb" },
    .@"--no-compressor" = .{ .section = .sound, .text = "leave the mix's loudness as it is, only keeping its peaks in check" },
    .@"--no-sound" = .{ .section = .sound, .text = "play without sound" },
    .@"--screenshot" = .{ .section = .other, .value = "<file.png>", .text = "draw one frame, with the camera settled, to a PNG, and quit; the controls are not read, so that it comes out the same each time" },
    .@"--screenshot-ticks" = .{ .section = .other, .value = "<ticks>", .text = "with --screenshot, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default" },
    .@"--version" = .{ .section = .other, .text = "show the version" },
    .@"--help" = .{ .section = .other, .alias = "-h", .text = "show this page" },
});

/// `openreliant --help`.
const help_page = page: {
    var out: []const u8 = help.paragraph("OpenReliant " ++ version.string ++ " plays StarLancer from an installed copy of the game.", 0) ++
        \\
        \\usage: openreliant [<game-directory>] [<option>...]
        \\       openreliant install [--from <disc>]... [--force] <directory>
        \\       openreliant joysticks [<game-directory>] [--watch]
        \\       openreliant missions [<game-directory>]
        \\
        \\
    ++ help.table(&.{.{ .typed = "<game-directory>", .text = "where StarLancer is installed, with resource.hog and tcachehw.dat; the current directory by default" }});
    for (std.enums.values(Section)) |section| {
        out = out ++ "\n" ++ section.title() ++ ":\n";
        if (section == .original) out = out ++ help.paragraph("OpenReliant improves on the original's look and sound. --original turns the improvements off, and an option after it turns one back on.", 2);
        var rows: []const help.Row = &.{};
        for (std.enums.values(Arg)) |arg| {
            const doc = docs.get(arg);
            if (doc.section != section) continue;
            const named = (if (doc.alias) |alias| alias ++ ", " else "") ++ @tagName(arg);
            rows = rows ++ .{help.Row{ .typed = if (doc.value) |shown| named ++ " " ++ shown else named, .text = doc.text }};
        }
        out = out ++ help.table(rows);
    }
    break :page out ++ "\nWhile playing:\n" ++
        help.paragraph("The flight keys are the game's own, as starlancer.ini binds them. OpenReliant adds:", 2) ++
        help.table(&.{
            .{ .typed = "F2, F3", .text = "start the mission again in the previous or next ship type" },
            .{ .typed = "F4", .text = "bring in another wing" },
            .{ .typed = "Alt+Enter", .text = "switch between the window and the full screen" },
            .{ .typed = "Escape", .text = "the pause menu, whose LEAVE MISSION quits" },
        }) ++ "\nCommands:\n" ++
        help.table(&.{
            .{ .typed = "install", .text = "install the game's files from the StarLancer discs into a directory" },
            .{ .typed = "joysticks", .text = "list the joysticks and gamepads, and which one the game uses" },
            .{ .typed = "missions", .text = "list the game's missions, its own and those added to its missions folder, and check that each loads" },
        }) ++ help.paragraph("Each command's --help shows its options.", 2);
};

/// What the command line asks for.
const Command = union(enum) {
    play: Options,
    help,
    version,
    wrong: Problem,
};

/// What is wrong with the command line.
const Problem = union(enum) {
    /// An option there is no such thing as.
    unknown: []const u8,
    /// An option with no value after it.
    missing: Arg,
    /// An option with a value it doesn't take.
    bad: struct { arg: Arg, value: []const u8 },

    pub fn format(problem: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (problem) {
            .unknown => |arg| try writer.print("unknown option '{s}'", .{arg}),
            .missing => |arg| try writer.print("{s} takes a value, {s}", .{ @tagName(arg), arg.value().? }),
            .bad => |wrong| try writer.print("{s} takes {s}, not '{s}'", .{ @tagName(wrong.arg), wrong.arg.value().?, wrong.value }),
        }
    }
};

const Options = struct {
    directory: []const u8 = ".",
    /// The mission to play, by its number.
    mission: u16 = mission0.number,
    /// The ship the player flies, in place of the loadout screen's choice; null for the mission's
    /// own.
    ship: ?u8 = null,
    /// The options' cockpit setting, for the run; the ini's `[Device] View` without it.
    cockpit: ?camera.CockpitSetting = null,
    difficulty: game.collision.Difficulty = .medium,
    screenshot: ?[]const u8 = null,
    /// The game ticks a screenshot runs before it is taken, one a frame.
    screenshot_ticks: u32 = minimum_screenshot_ticks,
    /// Whether the mission starts in the pause menu.
    pause_menu: bool = true,
    fullscreen: bool = false,
    software: bool = false,
    settings: platform.gpu.Settings = .{},
    /// Frames a second at most, 0 for no limit; null for the display's rate without vsync.
    fps: ?f32 = null,
    /// Draw what moves between the game's ticks as well as between its steps
    /// (`Clock.stepFraction`).
    smooth_motion: bool = true,
    /// Which shots cast a light: every one, or the latest two of each side as the original does.
    shot_lights: game.guns.ShotLights = .every_shot,
    /// Whether a muzzle's flash lights what stands round it, and whether the turrets' guns flash.
    flashes: game.guns.flash.Settings = .{},
    /// Whether the effects the game never reads play on the controller, and whether hits shake the
    /// camera whatever the controller.
    forces: engine.input.force.Settings = .{},
    /// Which lights reach an explosion's debris: a ship's, or every one as the original lets them.
    debris_lights: game.explode.DebrisLights = .like_ships,
    /// How many burning bits the explosions keep flying, and for how long.
    bit_pool: game.explode.BitPool = .lasting,
    /// How full the explosions look: their fireballs, their shockwaves' rings, and the particles
    /// sent far from the camera.
    fireballs: game.explode.Fireballs = .fuller,
    /// How the Uber Explode is shown.
    uber: game.explode.uber.Style = .fuller,
    rings: game.shockwave.Roundness = .round,
    distant: game.particles.Pool.Distant = .whole,
    /// How alike a damaged ship's smoke's particles are.
    smoke: game.particles.Pool.Variety = .varied,
    /// How the shields' bubbles are drawn.
    shields: game.shield.Style = .smooth,
    /// How the sun and the lens flares are drawn.
    sun: game.backdrop.Sun = .smooth,
    /// How far the finer levels of detail reach.
    detail_reach: game.main.DetailReach = .far,
    /// How much a frame may draw.
    draw_budget: game.main.DrawBudget = .roomy,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine = .from_tip,
    /// How the sound plays, or null for none.
    sound: ?platform.audio.Options = .{},
    /// Where a missile's sound is heard from.
    missile_sound: game.sound3d.MissileSound = .follows,
    /// A piece of music to play from the start, from `music\`, before the mission's script plays
    /// its own; none by default.
    music: ?[]const u8 = null,

    /// OpenAL Soft's settings, which a setting for it after `--original` plays with again.
    fn openAl(options: *Options) ?*platform.audio.openal.Settings {
        const sound = &(options.sound orelse return null);
        if (sound.player == .software) sound.player = .{ .openal = .{} };
        return &sound.player.openal;
    }

    /// What `args` ask for: to play with these options, the help page, the version, or what is
    /// wrong with them.
    fn parse(args: []const [:0]const u8) Command {
        var options: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const text = args[i];
            if (std.mem.eql(u8, text, "-h")) return .help;
            const arg = std.meta.stringToEnum(Arg, text) orelse {
                if (std.mem.startsWith(u8, text, "-")) return .{ .wrong = .{ .unknown = text } };
                options.directory = text;
                continue;
            };
            const value: [:0]const u8 = if (arg.value() == null) "" else value: {
                i += 1;
                if (i == args.len) return .{ .wrong = .{ .missing = arg } };
                break :value args[i];
            };
            options.apply(arg, value) catch return .{ .wrong = .{ .bad = .{ .arg = arg, .value = value } } };
            switch (arg) {
                .@"--help" => return .help,
                .@"--version" => return .version,
                else => {},
            }
        }
        return .{ .play = options };
    }

    /// Takes in `arg`, with its value where it has one.
    fn apply(options: *Options, arg: Arg, value: []const u8) error{BadValue}!void {
        switch (arg) {
            .@"--original" => {
                options.settings = .original;
                options.smooth_motion = false;
                options.shot_lights = .latest_two;
                options.flashes = .original;
                options.forces = .original;
                options.debris_lights = .every_light;
                options.bit_pool = .original;
                options.fireballs = .original;
                options.uber = .original;
                options.rings = .octagon;
                options.distant = .thinned;
                options.smoke = .alike;
                options.shields = .original;
                options.sun = .original;
                options.detail_reach = .original;
                options.draw_budget = .original;
                options.edge_line = .original;
                if (options.sound) |*sound| sound.* = .{ .player = .software, .master = null };
                options.missile_sound = .stays;
            },
            .@"--mission" => options.mission = std.fmt.parseInt(u16, value, 10) catch return error.BadValue,
            .@"--ship" => {
                const ship = std.fmt.parseInt(u8, value, 0) catch return error.BadValue;
                if (game.create.models.ship_types[ship].model == null) return error.BadValue;
                options.ship = ship;
            },
            .@"--view" => {
                const number = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
                options.cockpit = switch (@as(camera.CockpitSetting, @enumFromInt(number))) {
                    .cockpit, .chase, .none => |setting| setting,
                    _ => return error.BadValue,
                };
            },
            .@"--difficulty" => options.difficulty = std.meta.stringToEnum(game.collision.Difficulty, value) orelse return error.BadValue,
            .@"--music" => options.music = if (std.mem.eql(u8, value, "none")) null else value,
            .@"--no-pause-menu" => options.pause_menu = false,
            .@"--fullscreen" => options.fullscreen = true,
            .@"--size" => options.settings.size = parseSize(value) orelse return error.BadValue,
            .@"--fps" => {
                const fps = std.fmt.parseFloat(f32, value) catch return error.BadValue;
                if (!(fps >= 0 and fps <= 10_000)) return error.BadValue;
                options.fps = fps;
            },
            .@"--no-vsync" => options.settings.vsync = false,
            .@"--software" => options.software = true,
            .@"--16-bit" => options.settings.sixteen_bit = true,
            .@"--msaa" => {
                const samples = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
                if (std.mem.indexOfScalar(u8, &.{ 1, 2, 4, 8 }, samples) == null) return error.BadValue;
                options.settings.samples = samples;
            },
            .@"--filter" => options.settings.filter = std.meta.stringToEnum(platform.gpu.Settings.Filter, value) orelse return error.BadValue,
            .@"--no-bloom" => options.settings.bloom = false,
            .@"--no-dither" => options.settings.dither = false,
            .@"--no-pixel-lighting" => options.settings.pixel_lighting = false,
            .@"--gamma-space" => options.settings.linear_light = false,
            .@"--shadows" => options.settings.shadows = std.meta.stringToEnum(platform.gpu.Settings.Shadows, value) orelse return error.BadValue,
            .@"--no-cockpit-shadows" => options.settings.cockpit_shadows = false,
            .@"--no-smooth-motion" => options.smooth_motion = false,
            .@"--few-shot-lights" => options.shot_lights = .latest_two,
            .@"--hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .on;
            },
            .@"--no-hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .off;
            },
            .@"--no-reverb" => if (options.openAl()) |settings| {
                settings.reverb = false;
            },
            .@"--no-compressor" => if (options.sound) |*sound| {
                // The limiter stays.
                const master = if (sound.master) |*master| master else master: {
                    sound.master = .{};
                    break :master &sound.master.?;
                };
                master.ratio = 1;
                master.makeup = 0;
            },
            .@"--no-sound" => options.sound = null,
            .@"--screenshot" => options.screenshot = value,
            .@"--screenshot-ticks" => options.screenshot_ticks = @max(std.fmt.parseInt(u32, value, 10) catch return error.BadValue, minimum_screenshot_ticks),
            .@"--help", .@"--version" => {},
        }
    }

    /// A size given as `<width>x<height>`, each from 1 to `max_size`.
    fn parseSize(text: []const u8) ?[2]u32 {
        var halves = std.mem.splitScalar(u8, text, 'x');
        var size: [2]u32 = undefined;
        for (&size) |*side| {
            const digits = halves.next() orelse return null;
            side.* = std.fmt.parseInt(u32, digits, 10) catch return null;
            if (side.* == 0 or side.* > max_size) return null;
        }
        return if (halves.next() == null) size else null;
    }

    /// The largest side `--size` takes, which GPUs draw to.
    const max_size = 16384;

    /// The frames a second to hold to, where the display does not already.
    fn frameRate(options: Options, window: platform.window.Window) ?f32 {
        if (options.fps) |fps| return if (fps > 0) fps else null;
        if (options.software or options.settings.vsync) return null;
        return window.refreshRate();
    }
};

/// What the driver draws with: the GPU, or the software device, OpenReliant's reference, whose
/// frames the window shows.
const Screen = union(enum) {
    gpu: platform.gpu.Gpu,
    software: srd3d.software.Software,

    fn interface(screen: *Screen) srd3d.device.Device {
        return switch (screen.*) {
            inline else => |*device| device.interface(),
        };
    }
};

/// Writes `text` to standard output, for a command that only says something: 0, its exit status.
fn say(io: Io, text: []const u8) !u8 {
    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "install")) return install.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "joysticks")) return joysticks.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "missions")) return missions.main(init.io, arena, args[2..]);
    const options = switch (Options.parse(args[1..])) {
        .play => |options| options,
        .help => return say(init.io, help_page),
        .version => return say(init.io, "openreliant " ++ version.string ++ "\n"),
        .wrong => |problem| {
            std.debug.print("openreliant: {f}\nRun 'openreliant --help' to see the options.\n", .{problem});
            return 2;
        },
    };
    run(init.io, init.gpa, arena, options) catch |err| switch (err) {
        error.MissingGameFiles, error.MissingMission => return 1,
        else => return err,
    };
    return 0;
}

/// Opens the controller the game should use, unless it is already open, and loads the input
/// settings and bindings, which depend on the controller. The original does this once at startup in
/// `input_init` and `load_key_config`; OpenReliant also does it whenever a controller is connected
/// or disconnected. `platform.joystick.choose` selects the controller, and the rest of
/// `JoyConfig`'s setup (`platform.joystick.Setup`) configures a joystick's throttle and twist axes.
fn connectController(arena: Allocator, devices: *engine.input.Devices, controller: *?platform.joystick.Controller, settings_file: engine.profile.Profile) void {
    const joystick = platform.joystick;
    const setup: joystick.Setup = .read(settings_file);
    const found = joystick.attached(arena) catch &.{};
    const chosen = joystick.choose(found, setup.preference);
    if (controller.*) |*open| {
        if (chosen != null and chosen.?.id == open.id() and devices.joystick.device != null) return;
        devices.joystick.close();
        open.close();
        controller.* = null;
    }
    if (chosen) |which| {
        controller.* = joystick.Controller.open(which, setup) catch null;
        if (controller.*) |*open| devices.joystick.open(open.device(), game.interface.deadZone(settings_file));
    }
    game.interface.loadKeyConfig(devices, settings_file);
}

/// Says that `directory` holds no installed copy of the game, and what the engine needs.
fn missingGameFiles(directory: []const u8, file: ?[]const u8) error{MissingGameFiles} {
    if (file) |name| {
        std.debug.print("openreliant: {s} is missing from {s}.\n", .{ name, directory });
    } else {
        std.debug.print("openreliant: there is no directory {s}.\n", .{directory});
    }
    std.debug.print(
        \\OpenReliant is an engine only: it plays the files of a legally obtained copy of
        \\StarLancer. Run it in the directory the game is installed in, or name that directory:
        \\
        \\    openreliant <game-directory>
        \\
        \\To install the game's files from your StarLancer discs:
        \\
        \\    openreliant install <game-directory>
        \\
    , .{});
    return error.MissingGameFiles;
}

/// The window's size in points as it opens, which the software device draws at until the first
/// frame takes the window's own. OpenReliant's: the original took the display mode `[Device]` names.
const initial_size = [2]u32{ 1280, 720 };

/// The voices `WinMain` asks `sound_init` for (`0x004A9421`).
const sound_voices = 10;

comptime {
    // The platform counts the game's ticks.
    std.debug.assert(platform.window.tick_nanoseconds * game.main.ticks_per_second == std.time.ns_per_s);
}

/// One of the game's files in its folder `directory`, whole, into `arena`.
fn readGameFile(io: Io, arena: Allocator, directory: Io.Dir, name: []const u8) ![]u8 {
    return directory.readFileAlloc(io, name, arena, .limited(engine.files.max_file_size));
}

/// The records of the stats table `table`, from its file in the game's folder `directory`, as its
/// loader reads them (`stats_load_ships` and the others).
fn readStats(io: Io, arena: Allocator, directory: Io.Dir, comptime table: stats.Table) ![]align(1) const stats.Table.Record(table) {
    const file = try stats.File.parse(table, try readGameFile(io, arena, directory, table.fileName()));
    return @field(file, @tagName(table));
}

fn run(io: Io, gpa: Allocator, arena: Allocator, options: Options) !void {
    const directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return missingGameFiles(options.directory, null),
        else => return err,
    };
    defer directory.close(io);
    if (install.missingGameFile(io, directory)) |name| return missingGameFiles(options.directory, name);

    // What `WinMain` opens at start-up, and the texture cache `renderer_start` opens.
    var resources: game.bigfile.Hog = try .open(arena, io, directory, game.bigfile.resource_name);
    defer resources.close(arena);
    const cache_bytes = try readGameFile(io, arena, directory, tcache.hardware_name);
    const cache: tcache.Cache = try .parse(arena, cache_bytes);
    const palette = try tga.palette(try resources.readFile(arena, "palette.tga"));
    var textures: srtexture.Table = .init(arena, cache, palette);
    // The flight and combat stats `stats_load_ships` reads; every gun type's figures, which
    // `stats_load_guns` reads; every missile type's, which `stats_load_missiles` reads; and the
    // pilots'.
    const ship_stats = try readStats(io, arena, directory, .ships);
    const gun_stats = try readStats(io, arena, directory, .guns);
    const missile_stats = try readStats(io, arena, directory, .missiles);
    const pilot_stats = try readStats(io, arena, directory, .pilots);
    // The strings `language_init` reads out of `language.dll` at start-up.
    const strings: game.language.Language = try .load(arena, try .parse(try readGameFile(io, arena, directory, game.language.file_name)));

    var window: platform.window.Window = try .open("OpenReliant", initial_size[0], initial_size[1], options.fullscreen);
    defer window.close();
    // The device the driver draws with, and the driver.
    const screen = try arena.create(Screen);
    screen.* = if (options.software)
        .{ .software = try .init(arena, initial_size[0], initial_size[1]) }
    else
        .{ .gpu = try .init(gpa, window.gpu, window.handle, options.settings) };
    defer switch (screen.*) {
        .gpu => |*device| device.deinit(),
        .software => |*device| device.deinit(arena),
    };
    var driver: srd3d.srd3d.Driver = try .init(arena, screen.interface());
    defer driver.deinit();
    var pacer: platform.window.Pacer = .{};

    var context: srapi.Context = .{
        .projection = (camera.Camera{}).projection(initial_size[0], initial_size[1]),
        .detail = game.main.high_detail,
        .finer = options.detail_reach.finer(),
        .budget = options.draw_budget.limit(),
    };
    var rand: engine.libcmt.Rand = .{};
    const space = try game.backdrop.Backdrop.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.backdrop.star_map_name)), &rand, context.projection.near, options.sun);
    const sky = try game.nebula.Sky.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.nebula.dome_image_name)));
    try sky.select(&textures, game.nebula.default_nebula, &space.lights);
    // What the mission's script asks of its space: the nebula it shows.
    var environment: game.environfx.Environment = .{ .sky = sky, .textures = &textures, .lights = &space.lights };

    // The engine glows every ship's thrusters burn, built once and shared by them all.
    const glows: game.environfx.Glows = try .create(arena, &textures);
    // The muzzle flashes' flares, built with the shots' looks (`guns_init`).
    const flashes: game.guns.flash.Looks = try .create(arena, &textures, options.flashes);
    // The radar's backing, which the cockpit's view draws under the radar.
    const backing = try game.main.RadarBacking.create(arena, &textures);
    // The display's shapes, whose global palette the ships' schematics are drawn with too.
    const shapes = try spr.Sprite.parse(try resources.readFile(arena, game.hud.hardware_shapes));
    const global_palette = game.hud.globalPalette(shapes);
    // The ship types' stats as `stats_load_ships` leaves them, their models, loaded as the objects
    // need them, and the cockpit a mission's start loads for the player's ship.
    const tables = try arena.create(game.create.Stats);
    tables.* = .initial;
    tables.load(ship_stats);
    var cockpit: game.main.cockpit.Cockpit = .{};
    defer cockpit.deinit();
    var types: game.create.library.TypeCache = .{
        .gpa = gpa,
        .resources = &resources,
        .textures = &textures,
        .looks = .{ .light_sprites = try .load(&textures), .glows = &glows, .flashes = &flashes },
        .global_palette = global_palette,
    };
    defer types.deinit();
    // The objects, every slot standing in until a mission's start makes them, with every gun's,
    // missile's and pilot's figures; the loadout's ship, where one is chosen.
    const objects = try game.create.Objects.create(gpa, &rand);
    defer objects.destroy();
    objects.gun_stats.load(gun_stats);
    objects.missile_stats.load(missile_stats);
    objects.pilots.load(pilot_stats);
    if (options.ship) |ship| objects.loadout_ships[objects.player] = @enumFromInt(ship);
    // What the shots are drawn with, built once (`guns_init`); the Turret Flak's shell is loaded as
    // each mission starts.
    objects.bullets.looks = try game.guns.Looks.create(arena, &textures);
    objects.bullets.shot_lights = options.shot_lights;
    var player: engine.input.Player = .{};
    var devices: engine.input.Devices = .{};
    // The game's settings file, which `load_key_config` reads the input settings from and the
    // pause menu's screens write to. If it's missing, every setting keeps its default.
    var settings_file: engine.profile.File = .{ .arena = arena, .profile = .read(io, arena, directory) };
    // The joystick or gamepad the game uses, opened as `input_init` opens a joystick, and again
    // whenever a controller is connected or disconnected.
    try platform.joystick.init(.game);
    defer platform.joystick.deinit();
    _ = platform.joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, platform.joystick.mappings_name }));
    var controller: ?platform.joystick.Controller = null;
    defer if (controller) |*open| open.close();
    // A screenshot reads no controls, so that it comes out the same whatever is plugged in.
    if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile);

    // Sound: Miles's calls, played by OpenAL Soft or OpenReliant's own mixer through SDL3's audio,
    // with the voices `WinMain` asks `sound_init` for, the volumes of `[Sound]`, and the 3D
    // provider it opens; silent where there is no device, or with `--no-sound`.
    const output: ?*platform.audio.Output = if (options.sound) |chosen| platform.audio.Output.create(gpa, chosen) catch |err| none: {
        std.log.warn("playing without sound: {s}", .{@errorName(err)});
        break :none null;
    } else null;
    defer if (output) |open| open.destroy();
    const sound = try arena.create(game.hog_snd.Sound);
    sound.init(if (output) |open| open.driver() else null, sound_voices, .{ .gpa = gpa, .io = io, .dir = directory });
    defer sound.shutdown();
    sound.volumes = .read(settings_file.profile);
    sound.objects = objects;
    sound.missile_sound = options.missile_sound;
    // `bank_stdsmp`, which the positional sounds of a frame play from, and `smp3d.fat`, which the
    // 3D sounds do.
    const stdsmp = try openreliant.fat.Bank.parse(try resources.readFile(arena, "stdsmp.fat"));
    sound.betty = try openreliant.fat.Bank.parse(try resources.readFile(arena, "betty.fat"));
    sound.stdsmp = stdsmp;
    sound.open3D(try openreliant.fat.Bank.parse(try resources.readFile(arena, "smp3d.fat")));

    // The options' cockpit setting and the brightness, as `[Device]` keeps them, and the camera,
    // which keeps the setting and starts in the cockpit mode it picks, as a mission's start does.
    const video = game.hudoptions.screens.Video;
    const cockpit_setting: camera.CockpitSetting = options.cockpit orelse @enumFromInt(settings_file.profile.int(video.section, video.view_key, 0));
    var brightness = @as(f32, @floatFromInt(settings_file.profile.int(video.section, video.gamma_key, video.gamma_scale))) / video.gamma_scale;
    var view: camera.Camera = .{ .setting = cockpit_setting, .cockpit_mode = cockpit_setting.mode(), .missiles = &objects.missiles };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    clock.start(platform.window.ticks());
    const hearing: game.hog_snd.Hearing = .{ .sound = sound, .camera = &view.place, .clock = &clock };
    // What the explosions leave for the frames after them, and the particles they send out.
    var explosions: game.explode.Explosions = try .init(gpa, try .load(&textures));
    defer explosions.deinit();
    explosions.settings.debris_lights = options.debris_lights;
    explosions.settings.bit_pool = options.bit_pool;
    explosions.settings.fireballs = options.fireballs;
    explosions.settings.uber = options.uber;
    var particles: game.particles.Pool = try .load(gpa, &textures, .standard, .{ .distant = options.distant });
    defer particles.deinit();
    // The damaged ships' smoke, from pools of its own.
    var smoke: game.main.smoke.Pools = try .load(gpa, &textures, .{ .distant = options.distant, .variety = options.smoke });
    defer smoke.deinit();
    var gun_particles: game.guns.effects.Pools = try .load(gpa, &textures, .{ .distant = options.distant });
    defer gun_particles.deinit();
    var shockwaves: game.shockwave.Shockwaves = try .create(gpa, &textures, options.rings);
    defer shockwaves.deinit(gpa);
    var trails: game.missiles.trail.Trails = .init(gpa, try .load(&textures));
    defer trails.deinit();
    var rays: game.erayfx.Rays = try .init(gpa, &textures);
    defer rays.deinit();
    var tractors: game.tractor.Tractors = try .init(gpa, &textures);
    defer tractors.deinit();
    var flash: game.main.flash.Flash = .{};
    // The countermeasures' model, read once for the whole run, as `decoys_init` reads it.
    var effects_models: game.create.library.MountCache = .{ .gpa = arena, .resources = &resources, .textures = &textures };
    var countermeasures: game.cloak.Countermeasures = .init(gpa, effects_models.mounts());
    defer countermeasures.reset();
    const lock_rings: *game.main.lock.Rings = try .create(gpa, &textures);
    defer lock_rings.destroy(gpa);
    const chase_objects: *game.hud.chase.Chase = try .create(gpa, &textures);
    defer chase_objects.destroy(gpa);
    var sparks: game.sparks.Sparks = try .create(gpa, &textures);
    defer sparks.deinit();
    var shields: game.shield.Shields = try .create(gpa, &textures, explosions.settings.detail, context.hardware, options.shields);
    defer shields.deinit(gpa);
    // The force feedback's effects, and what plays them on the player's controller.
    const found_forces = engine.input.force.load(io, arena, directory);
    var lacking = found_forces.lacking.iterator();
    while (lacking.next()) |effect| std.log.warn("forces\\{s} is missing or isn't an effect file: it plays nothing", .{effect.fileName()});
    var force_feedback: engine.input.force.Forces = .{ .library = &found_forces.library, .settings = options.forces };
    // What the objects run in, the camera's view brought up to date each frame.
    var world: game.gameobj.World = .{ .forces = &force_feedback, .objects = objects, .player = &player, .clock = &clock, .view = view.view, .shake = &view.hit_shake, .random = &rand, .difficulty = options.difficulty, .hearing = hearing, .camera = &view, .explosions = &explosions, .particles = &particles, .smoke = &smoke, .gun_particles = &gun_particles, .shockwaves = &shockwaves, .trails = &trails, .countermeasures = &countermeasures, .sparks = &sparks, .shields = &shields, .rays = &rays, .tractors = &tractors, .flash = &flash, .spawn = .{ .tables = tables, .types = types.types() }, .environment = &environment };

    // The pause menu, which stands in the display's place while the game is paused.
    var pause_menu: game.hudoptions.PauseMenu = .{};
    defer pause_menu.close();
    // The head-up display: what it draws with, and what draws it over the finished scene.
    var display: Display = .{
        .resources = try .load(arena, resources, shapes),
        .edge_line = options.edge_line,
        .gpa = arena,
        .target = undefined,
        .screen = .{ 0, 0 },
        .objects = objects,
        .play = undefined,
        .clock = &clock,
        .player = &player,
        .view = &view,
        .random = &rand,
        .strings = &strings,
        .pause_menu = &pause_menu,
        .devices = &devices,
        .settings = .{
            .file = &settings_file,
            .sound = sound,
            .stdsmp = stdsmp,
            .camera = &view,
            .brightness = &brightness,
        },
    };
    world.display = &display.state;

    // The mission, read once from the game's files, or for mission 0, where the game has none, from
    // the copy `openreliant` carries, and started; it starts again as each attempt ends.
    var play: Play = .{
        .gpa = gpa,
        .number = options.mission,
        .file = try missionFile(io, arena, directory, &resources, options.mission),
        .clock = &clock,
        .tables = tables,
        .types = &types,
        .cockpit = &cockpit,
        .display = &display.state,
        .view = &view,
    };
    defer play.end();
    display.play = &play;
    try play.start(.{ .world = world, .clock = &clock, .devices = &devices });
    // A piece of music asked for, as a mission's script plays one (`cmd_PlayMusic`): from `music\`,
    // for ever, at 80.
    if (options.music) |name| {
        const path = try std.fmt.allocPrint(arena, "music\\{s}", .{name});
        sound.playMusic(path, 0, 80, true);
    }
    // A screenshot waits for the chase view to settle, then runs its ticks, one a frame, at least
    // until the second frame, which draws the sun by how much of it the first found showing.
    var frames_left: ?usize = null;
    if (options.screenshot != null) {
        const subject = camera.Subject.of(&objects.slots[objects.player]);
        for (0..settling_frames) |_| _ = view.frame(.{ .object = subject, .player = subject, .ticks = 1 });
        frames_left = options.screenshot_ticks;
    }

    var scene: srcore.Scene = .{};
    defer scene.deinit(arena);
    // What a frame needs until it is drawn, kept from frame to frame.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    // The window's activation, which a screenshot doesn't wait on.
    var app: game.winmain.App = .{};
    // What `game_pause` pauses the game with, and resumes it. With no front end yet, the mission
    // starts in the pause menu; a screenshot never does.
    const pausing: game.main.Pausing = .{
        .gpa = gpa,
        .clock = &clock,
        .sound = sound,
        .menu = &pause_menu,
        .archive = resources,
        .camera = &view,
        .player = &objects.player,
    };
    if (options.pause_menu and frames_left == null) try game.main.pause(pausing, true);
    // Whether the system's pointer shows over the window, and whether the window holds the mouse.
    var pointer_shown = true;
    var mouse_held = false;
    while (true) {
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| if (options.screenshot == null) {
                devices.keyboard.down[@intFromEnum(key.scan)] = key.down;
            },
            .controllers => if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile),
            .active => |active| app.active = active or frames_left != null,
            .pointer => |pointer| if (options.screenshot == null) {
                devices.mouse.at = pointer.at;
                // The movement counts only while the window holds the mouse, as DirectInput's
                // exclusive mouse moves only for the game.
                if (mouse_held) devices.mouse.motion = @as(@Vector(2, f32), devices.mouse.motion) + @as(@Vector(2, f32), pointer.moved);
            },
            .button => |button| if (options.screenshot == null) switch (button.which) {
                .left => devices.mouse.buttons.left = button.down,
                .right => devices.mouse.buttons.right = button.down,
            },
        };
        // While the window is inactive, the sound is paused, as the message pump pauses it, and
        // the game too.
        try game.winmain.followActivation(&app, pausing);
        if (output) |open| open.update();
        // The timer's ticks since the last pass, then a game tick for each, as `mission_run` paces
        // them: the simulation steps on every fourth, reading the keyboard as it goes, and runs the
        // objects' updates. A screenshot takes one tick a frame so that the camera settles the same
        // way on every run.
        const now = platform.window.nanoseconds();
        if (frames_left != null) clock.advanceBy(now / platform.window.tick_nanoseconds, 1) else clock.advanceToFine(now, platform.window.tick_nanoseconds);
        // While the communications window is open the keys 1 to 8 are its menu's.
        devices.keyboard.numbers_taken = display.state.windows.status.get(.comms).phase == .open;
        world.view = view.view;
        world.cockpit = if (cockpit.shown) |*shown| &shown.model else null;
        world.mission = if (play.loaded) |loaded| &loaded.bound else null;
        world.events = if (play.loaded) |loaded| &loaded.events else null;
        const orders: game.aigeneric.Context = .{ .world = world, .clock = &clock, .devices = &devices };
        while (clock.nextTick(&devices, world)) |_| {}
        clock.frameBegin();
        const slot = &objects.slots[objects.player];
        // `mission_frame` looks for Escape before its work, and pausing into the menu leaves the
        // work out.
        if (!clock.paused and devices.keyboard.pressed(engine.input.scan.escape, .none, true)) try game.main.pause(pausing, true);
        if (clock.paused) {
            game.main.pausedFrame(&devices, hearing, world);
        } else {
            // The force feedback plays while the controller rumbles and its setting lets it.
            force_feedback.feedback = devices.joystick.rumbles;
            force_feedback.setting = devices.settings.force_feedback;
            // Each frame `mission_frame` runs every object's orders, which fly the ships and read
            // the player's controls, and then, before anything is drawn, has every object's frames
            // drawn between its last two places, as far into the step as the clock is; the camera
            // follows the player's.
            const over = game.main.missionFrame(orders, .of(&clock, options.smooth_motion), play.loaded);
            // The mission over, once the camera has watched the player's end or the pilot's pickup,
            // or once its script ends it, it starts again where the game would go to its
            // debriefing.
            if (over) try play.again(orders);
            for (test_keys.ship_keys) |step| {
                if (devices.keyboard.pressed(@intFromEnum(step[0]), .none, true)) try play.changeShip(orders, step[1]);
            }
            if (devices.keyboard.pressed(@intFromEnum(test_keys.wing_key), .none, true)) test_keys.bringWing(orders);

            game.main.controlsFrame(.{
                .orders = orders,
                .devices = &devices,
                .camera = &view,
                .display = &display.state,
                .sight = display.sight,
                .screen = display.screen,
                .last_view = last_view,
                .cockpit = if (cockpit.shown) |*shown| shown else null,
                .forces = &force_feedback,
                .random = &rand,
                .smooth_motion = options.smooth_motion,
            });
        }

        // The GPU draws at the display's own resolution; the software device at the window's size
        // in points, made again when it changes.
        const size = switch (screen.*) {
            .gpu => |*device| device.frameSize(),
            .software => |*device| resized: {
                const size = options.settings.size orelse window.size();
                if (device.width != size[0] or device.height != size[1]) {
                    device.deinit(arena);
                    device.* = try .init(arena, size[0], size[1]);
                }
                break :resized size;
            },
        };

        context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
        context.projection = view.projection(size[0], size[1]);
        // The cockpit's model hangs from the camera, and the radar's backing stands on the radar.
        if (cockpit.shown) |*shown| if (view.cockpit_place) |placed| game.main.cockpit.place(&shown.model, view.place, placed);
        backing.place(context.projection, view.place, game.hud.scaleFor(size));
        _ = frame_arena.reset(.retain_capacity);
        display.target = screen.interface();
        display.screen = size;
        display.sight = .{ .place = view.place, .projection = context.projection };
        display.last_view = last_view;
        display.cockpit_mode = view.cockpit_mode;
        try game.main.drawFrame(arena, frame_arena.allocator(), &scene, &context, .{
            .objects = objects,
            .seat = if (slot.object.flags.hidden) objects.player else null,
            .shown = .of(&player),
            .space = space,
            .sky = sky,
            .view = view.view,
            .cockpit_mode = view.cockpit_mode,
            .jumping_in = player.jumping_in,
            .last_view = last_view,
            .cut = view.cut,
            .overlay = display.overlay(),
            .cockpit = if (cockpit.shown) |*shown| &shown.model else null,
            // The paused frame hides the radar's backing, whose radar the menu stands in place of.
            .backing = if (clock.paused) null else backing,
            .kills_shown = devices.active(.display_kills, false),
            .particles = &particles,
            .smoke = &smoke,
            .gun_particles = &gun_particles,
            .sparks = &sparks,
            .ahead = game.objects.pastTick(&clock, options.smooth_motion),
            .explosions = &explosions,
            .shockwaves = &shockwaves,
            .trails = &trails,
            .countermeasures = &countermeasures,
            .lock = &display.state.lock,
            .lock_rings = lock_rings,
            .chase = chase_objects,
            .display = &display.state,
            .shields = &shields,
            .rays = &rays,
            .tractors = &tractors,
            .flash = &flash,
            .interference = &display.state.interference,
            .ticks = @intCast(clock.frameTicks()),
            .paused = clock.paused,
            .attachments = .{
                .camera = view.place.position,
                .frame_start = clock.frame_start,
                .random = &rand,
            },
        }, driver.interface());
        last_view = view.view;
        view.cut = false;
        // What the menu's choice ends the pause in, as `mission_paused_frame` acts on it: the
        // mission starts again for RESTART, and LEAVE MISSION leaves it.
        if (pause_menu.outcome()) |outcome| {
            try game.main.pause(pausing, false);
            switch (outcome) {
                .continue_mission => {},
                .restart => try play.again(orders),
                .leave_mission => return,
            }
        }
        // The menu draws its own pointer over the window, in place of the system's.
        if (pause_menu.isOpen() == pointer_shown) {
            pointer_shown = !pointer_shown;
            window.showPointer(pointer_shown);
        }
        // Steering by the mouse, the window holds it in flight, as the game holds DirectInput's
        // mouse while it is in the foreground.
        const hold = devices.settings.control_mode == .mouse and !pause_menu.isOpen() and app.active and options.screenshot == null;
        if (hold != mouse_held) {
            mouse_held = hold;
            // Where the system won't hold it, the mouse steers by the pointer's movement over the
            // window, and the failure is logged.
            window.holdMouse(hold) catch {};
        }
        // What the menu's screens saved goes to the file.
        if (settings_file.changed) {
            settings_file.changed = false;
            directory.writeFile(io, .{ .sub_path = engine.profile.settings_name, .data = settings_file.profile.text }) catch |err|
                std.log.warn("the settings can't be saved to {s}: {s}", .{ engine.profile.settings_name, @errorName(err) });
        }
        if (screen.* == .software) try window.present(try screen.software.rgba(frame_arena.allocator()), size[0], size[1]);
        if (frames_left) |*left| {
            left.* -= 1;
            if (left.* == 0) {
                const rgba = switch (screen.*) {
                    .gpu => |*device| try device.capture(frame_arena.allocator()),
                    .software => |*device| try device.rgba(frame_arena.allocator()),
                };
                return save(io, frame_arena.allocator(), options.screenshot.?, rgba, size);
            }
        }
        if (options.frameRate(window)) |rate| pacer.wait(rate);
    }
}

/// The view a ship that does not launch is shown in at first: view 0, as a launch ends in, in
/// `mode`. The chase mode sits a fixed distance behind, which the camera keeps per ship type, so a
/// ship whose own radius is larger than that distance would not fit in it, as the ships `--ship`
/// and the test keys give the player that the game never does. Those are shown in the external
/// view, which orbits at a distance worked out from the ship's own size.
fn startingView(slot: *const game.create.Slot, mode: camera.CockpitMode) camera.View {
    if (mode != .chase) return .cockpit;
    const behind = camera.Chase.offset(slot.object.type).distance;
    return if (slot.object.radius > behind) .external else .cockpit;
}

/// Frames the chase view takes to settle, at a tick a frame.
const settling_frames = 200;
const minimum_screenshot_ticks = 2;

fn save(io: Io, gpa: Allocator, path: []const u8, rgba: []const u8, size: [2]u32) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try openreliant.png.writeRgba(gpa, &writer.interface, size[0], size[1], rgba);
    try writer.interface.flush();
}

/// The mission being played: the file it starts from, and the mission loaded for play, which
/// starts again as each attempt ends, with what each start readies (`game.main.startMission`).
const Play = struct {
    gpa: Allocator,
    number: u16,
    /// The mission's file as read, of which each start binds a copy, as the game reads the file
    /// again for each.
    file: []const u8,
    loaded: ?*game.mission.Loaded = null,
    clock: *game.main.Clock,
    tables: *game.create.Stats,
    types: *game.create.library.TypeCache,
    cockpit: *game.main.cockpit.Cockpit,
    display: *game.hud.State,
    /// The camera, which shows the player's ship in the view it starts in (`startingView`).
    view: *camera.Camera,

    /// Starts the mission, letting go of the one before.
    fn start(play: *Play, orders: game.aigeneric.Context) !void {
        play.end();
        play.loaded = try game.main.startMission(play.gpa, .{
            .orders = orders,
            .clock = play.clock,
            .tables = play.tables,
            .types = play.types,
            .cockpit = play.cockpit,
            .display = play.display,
        }, try play.gpa.dupe(u8, play.file), play.number);
        // A launch holds the camera until the ship is out; a ship that does not launch starts in
        // its view at once.
        const all = orders.world.objects;
        if (!play.view.locked) _ = play.view.setView(startingView(&all.slots[all.player], play.view.cockpit_mode), all.player, false, true, play.clock.viewTime());
    }

    /// Starts the mission again as an attempt ends, the kills kept where the ending keeps them, as
    /// when the ejected pilot is picked up by a nanny ship (`gameflow.endMission`).
    fn again(play: *Play, orders: game.aigeneric.Context) !void {
        game.gameflow.endMission(orders.world.player);
        try play.start(orders);
    }

    /// Starts the mission again with the loadout's ship the type `step` on from the player's
    /// (`test_keys.nextShipType`), passing over the types whose models the game lacks; with none
    /// to go to, in the ship it was.
    fn changeShip(play: *Play, orders: game.aigeneric.Context, step: isize) !void {
        const all = orders.world.objects;
        const was: usize = all.slots[all.player].object.type.untwinned().number();
        var candidate = was;
        while (true) {
            candidate = test_keys.nextShipType(candidate, step);
            all.loadout_ships[all.player] = @enumFromInt(candidate);
            try play.start(orders);
            if (all.slots[all.player].type != null or candidate == was) return;
            std.log.warn("ship type {d} is left out: the game has no model for it", .{candidate});
        }
    }

    fn end(play: *Play) void {
        if (play.loaded) |loaded| loaded.destroy();
        play.loaded = null;
    }
};

/// The file of mission `number`, as the game reads it (`game.mission.bind.read`): from the game's
/// `missions` folder, or from `resource.hog`. Mission 0, OpenReliant's own, comes from the copy
/// `openreliant` carries where the game has none.
fn missionFile(io: Io, arena: Allocator, directory: Io.Dir, resources: *const game.bigfile.Hog, number: u16) ![]const u8 {
    var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
    const path = game.winmain.missionPath(&path_buffer, number, false, false);
    if (try game.mission.bind.read(io, arena, directory, resources, path)) |file| return file.image;
    if (number == mission0.number) return @embedFile("mission0.dte");
    std.debug.print("openreliant: the game has no mission {d}: neither its missions folder nor {s} holds {s}\n", .{ number, game.bigfile.resource_name, std.fs.path.basenameWindows(path) });
    return error.MissingMission;
}

/// What draws the head-up display over the finished scene: `hud_draw`, given the mission's game.
/// `srcore.render` reaches it where Surrender reaches `hud_draw`, through the overlay it is handed.
const Display = struct {
    resources: game.hud.Resources,
    gpa: Allocator,
    /// Filled in each frame, before the scene is drawn.
    target: srd3d.device.Device,
    screen: [2]u32,
    /// Last frame's view, which is what `hud_draw` reads to know whether to draw the instruments.
    last_view: camera.View = .cockpit,
    /// What the cockpit view shows, which leaves the reticle out of the chase view.
    cockpit_mode: camera.CockpitMode = .cockpit,
    /// The scene as it is drawn, which the targeting keys find the object under the reticle by
    /// and the target is drawn over; null until the first frame.
    sight: ?game.hud.Sight = null,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine,
    /// The objects, whose player's ship the display shows, and the mission being played, whose
    /// script has what is ready for JUMP DRIVE; filled in once the mission is ready to start.
    objects: *game.create.Objects,
    play: *const Play,
    clock: *const game.main.Clock,
    player: *const engine.input.Player,
    /// The camera, whose shake shakes the power ball too.
    view: *const camera.Camera,
    /// The C runtime's `rand`, which the camera and the display both draw from.
    random: *engine.libcmt.Rand,
    /// The display's own state, `hud.cpp`'s globals.
    state: game.hud.State = .{},
    /// What the display shows ready for JUMP DRIVE while no mission is loaded: nothing.
    idle: game.hud.Readiness = .{},
    /// The game's strings, which the views without the instruments are named by.
    strings: *const game.language.Language,
    /// The pause menu, which stands in the display's place while the game is paused, the devices
    /// its pointer reads, and the settings its screens change.
    pause_menu: *game.hudoptions.PauseMenu,
    devices: *engine.input.Devices,
    settings: game.hudoptions.Settings,

    fn overlay(display: *Display) srcore.Overlay {
        return .{ .context = display, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const display: *Display = @ptrCast(@alignCast(context));
        display.drawOverlay() catch |err| switch (err) {
            error.OutOfMemory => |out| return out,
            // A shape the file does not hold draws nothing, as it does in the game.
            else => {},
        };
    }

    /// What Surrender's overlay slot (`sr + 0x88`) holds: the pause menu while paused
    /// (`pause_menu_draw`), and the display otherwise (`hud_draw`).
    fn drawOverlay(display: *Display) !void {
        if (display.pause_menu.isOpen()) return display.pause_menu.draw(.{
            .target = display.target,
            .screen = display.screen,
            .art = &display.resources.art,
            .font = &display.resources.font,
            .strings = display.strings,
            .devices = display.devices,
            .settings = display.settings,
            .version = version.string,
        });
        try game.hud.draw(&display.state, &display.resources, .{
            .gpa = display.gpa,
            .target = display.target,
            .screen = display.screen,
            .sight = display.sight,
            .all = display.objects,
            .player = display.player,
            .clock = display.clock,
            .last_view = display.last_view,
            .mode = display.cockpit_mode,
            .strings = display.strings,
            .hit_shake = display.view.hit_shake,
            .view = display.view.view,
            .sound = display.settings.sound,
            .random = display.random,
            .ready = if (display.play.loaded) |loaded| &loaded.script.variables.ready else &display.idle,
            .edge_line = display.edge_line,
        });
    }
};

test {
    _ = install;
    _ = joysticks;
    _ = mission0;
    _ = missions;
    _ = test_keys;
    _ = version;
}

/// The options `args` play with, for the tests.
fn parsed(args: []const [:0]const u8) error{Usage}!Options {
    return switch (Options.parse(args)) {
        .play => |options| options,
        .help, .version, .wrong => error.Usage,
    };
}

test Options {
    try std.testing.expectEqualStrings(".", (try parsed(&.{})).directory);
    const given = try parsed(&.{ "game/install", "--ship", "3" });
    try std.testing.expectEqualStrings("game/install", given.directory);
    try std.testing.expectEqual(3, given.ship);
    try std.testing.expectEqual(null, given.cockpit);
    try std.testing.expectEqual(camera.CockpitSetting.chase, (try parsed(&.{ "--view", "1" })).cockpit.?);
    try std.testing.expectError(error.Usage, parsed(&.{ "--view", "3" }));
    try std.testing.expectError(error.Usage, parsed(&.{"--ship"}));
    // The mission by its number, mission 0 by default.
    try std.testing.expectEqual(mission0.number, (try parsed(&.{})).mission);
    try std.testing.expectEqual(25, (try parsed(&.{ "--mission", "25" })).mission);
    try std.testing.expectEqual(null, (try parsed(&.{})).ship);
    try std.testing.expectError(error.Usage, parsed(&.{ "--mission", "x" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--ship", "0x0E" }));
    try std.testing.expectError(error.Usage, parsed(&.{"--bogus"}));
    try std.testing.expectEqualStrings("shot.png", (try parsed(&.{ "--screenshot", "shot.png" })).screenshot.?);
    // Medium, the game's own default, unless told otherwise.
    try std.testing.expectEqual(.medium, (try parsed(&.{})).difficulty);
    try std.testing.expectEqual(.hard, (try parsed(&.{ "--difficulty", "hard" })).difficulty);
    try std.testing.expectEqual(.medium, (try parsed(&.{ "--original", "--difficulty", "medium" })).difficulty);
    try std.testing.expectError(error.Usage, parsed(&.{ "--difficulty", "ace" }));

    // The improvements on by default; the original's look, and single settings after it.
    const plain = try parsed(&.{});
    try std.testing.expectEqual(platform.gpu.Settings{}, plain.settings);
    try std.testing.expectEqual(null, plain.fps);
    const retro = try parsed(&.{ "--original", "--msaa", "8", "--no-vsync", "--fps", "0" });
    try std.testing.expect(retro.settings.sixteen_bit);
    try std.testing.expectEqual(.off, retro.settings.shadows);
    try std.testing.expectEqual(.low, (try parsed(&.{ "--shadows", "low" })).settings.shadows);
    try std.testing.expect(!(try parsed(&.{"--no-cockpit-shadows"})).settings.cockpit_shadows);
    try std.testing.expect(!(try parsed(&.{"--gamma-space"})).settings.linear_light);
    try std.testing.expect(!retro.settings.linear_light);
    try std.testing.expectEqual(.original, retro.settings.filter);
    try std.testing.expectEqual(8, retro.settings.samples);
    try std.testing.expect(!retro.settings.vsync);
    try std.testing.expectEqual(0, retro.fps.?);
    try std.testing.expect(!retro.smooth_motion);
    try std.testing.expectEqual(.latest_two, retro.shot_lights);
    try std.testing.expectEqual(game.guns.flash.Settings.original, retro.flashes);
    try std.testing.expectEqual(game.guns.flash.Settings{}, plain.flashes);
    try std.testing.expectEqual(engine.input.force.Settings.original, retro.forces);
    try std.testing.expectEqual(engine.input.force.Settings{}, plain.forces);
    try std.testing.expectEqual(.stays, retro.missile_sound);
    try std.testing.expectEqual(.every_light, retro.debris_lights);
    try std.testing.expectEqual(.like_ships, plain.debris_lights);
    try std.testing.expectEqual(.lasting, plain.bit_pool);
    try std.testing.expectEqual(.original, retro.bit_pool);
    try std.testing.expectEqual(.original, retro.fireballs);
    try std.testing.expectEqual(.original, retro.uber);
    try std.testing.expectEqual(.fuller, plain.uber);
    try std.testing.expectEqual(.octagon, retro.rings);
    try std.testing.expectEqual(.thinned, retro.distant);
    try std.testing.expectEqual(.alike, retro.smoke);
    try std.testing.expectEqual(.varied, plain.smoke);
    try std.testing.expectEqual(.fuller, plain.fireballs);
    try std.testing.expectEqual(.smooth, plain.shields);
    try std.testing.expectEqual(.original, retro.shields);
    try std.testing.expectEqual(.far, plain.detail_reach);
    try std.testing.expectEqual(.original, retro.detail_reach);
    try std.testing.expectEqual(.roomy, plain.draw_budget);
    try std.testing.expectEqual(.original, retro.draw_budget);
    try std.testing.expect(!(try parsed(&.{"--no-smooth-motion"})).smooth_motion);
    try std.testing.expectEqual(.latest_two, (try parsed(&.{"--few-shot-lights"})).shot_lights);
    // Sound is on unless told otherwise, and the mission's script plays its music.
    try std.testing.expect((try parsed(&.{})).sound.?.player == .openal);
    try std.testing.expectEqual(null, (try parsed(&.{"--no-sound"})).sound);
    try std.testing.expectEqual(null, (try parsed(&.{ "--no-sound", "--hrtf" })).sound);
    // The original's sound is the plain mixer with no master bus; OpenAL's settings bring OpenAL
    // back.
    const original_sound = (try parsed(&.{"--original"})).sound.?;
    try std.testing.expect(original_sound.player == .software and original_sound.master == null);
    const headphones = (try parsed(&.{ "--original", "--hrtf", "--no-reverb" })).sound.?;
    try std.testing.expect(headphones.player.openal.hrtf == .on and !headphones.player.openal.reverb);
    try std.testing.expectEqual(.auto, (try parsed(&.{})).sound.?.player.openal.hrtf);
    try std.testing.expectEqual(.off, (try parsed(&.{"--no-hrtf"})).sound.?.player.openal.hrtf);
    const uncompressed = (try parsed(&.{"--no-compressor"})).sound.?.master.?;
    try std.testing.expectEqual(1, uncompressed.ratio);
    try std.testing.expectEqual(null, (try parsed(&.{})).music);
    try std.testing.expectEqualStrings("New_Sim01.wav", (try parsed(&.{ "--music", "New_Sim01.wav" })).music.?);
    try std.testing.expectEqual(null, (try parsed(&.{ "--music", "none" })).music);
    try std.testing.expect((try parsed(&.{})).smooth_motion);
    try std.testing.expectEqual([2]u32{ 3840, 2160 }, (try parsed(&.{ "--size", "3840x2160" })).settings.size.?);
    for ([_][:0]const u8{ "3840", "0x100", "100x", "1x2x3", "99999x100" }) |bad| {
        try std.testing.expectError(error.Usage, parsed(&.{ "--size", bad }));
    }
    const chosen = try parsed(&.{ "--filter", "trilinear", "--16-bit", "--software", "--fullscreen" });
    try std.testing.expectEqual(.trilinear, chosen.settings.filter);
    try std.testing.expect(chosen.settings.sixteen_bit and chosen.software and chosen.fullscreen);
    try std.testing.expectError(error.Usage, parsed(&.{ "--msaa", "3" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--filter", "sharp" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--fps", "-1" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--fps", "nan" }));
}

test "Options asks for help or the version, and says what is wrong" {
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{"--help"})));
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{ "game", "-h" })));
    try std.testing.expectEqual(.version, std.meta.activeTag(Options.parse(&.{ "game", "--version" })));
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { []const [:0]const u8, []const u8 }{
        .{ &.{"--bogus"}, "unknown option '--bogus'" },
        .{ &.{"--msaa"}, "--msaa takes a value, <1|2|4|8>" },
        .{ &.{ "--msaa", "3" }, "--msaa takes <1|2|4|8>, not '3'" },
        .{ &.{ "--no-sound", "--view", "cockpit" }, "--view takes <0|1|2>, not 'cockpit'" },
    };
    for (cases) |case| {
        const problem = Options.parse(case[0]).wrong;
        try std.testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
    }
}

test help_page {
    // It starts with the version, every option is on it, and it fits in 80 columns.
    try std.testing.expect(std.mem.startsWith(u8, help_page, "OpenReliant " ++ version.string ++ " plays"));
    for (std.enums.values(Arg)) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, help_page, @tagName(arg)) != null);
    }
    var lines = std.mem.splitScalar(u8, help_page, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= help.width);
}
