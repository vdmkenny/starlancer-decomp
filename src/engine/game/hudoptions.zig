//! `hudoptions.cpp`: the pause menu, which the game draws in place of the display while a mission
//! is paused, and whose screens change the settings.
//! [`pause-menu.md`](../../../docs/engine/pause-menu.md) describes it.
//!
//! **Unverified:** the file's name, which no assertion gives; the doc says where it comes from.
//!
//! Ported so far: the menu's items, how they are drawn and found under the pointer, and the
//! widgets the screens share ([`hudoptions/menu.zig`](hudoptions/menu.zig)); the pointer, the
//! fonts and the screens' order (`pause_menu_draw`); and the main, audio and video screens
//! ([`hudoptions/screens.zig`](hudoptions/screens.zig)). Not yet: the controls screen, and F1,
//! which opens it (#210); the multiplayer screen (#211); and the two screens nothing reaches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fat = @import("../../formats/fat.zig");
const fnt = @import("../../formats/fnt.zig");
const device = @import("../surrender/srd3d/device.zig");
const input = @import("../input.zig");
const profile = @import("../profile.zig");
const bigfile = @import("bigfile.zig");
const camera = @import("camera.zig");
const hog_snd = @import("hog_snd.zig");
const hud = @import("hud.zig");
const language = @import("language.zig");

pub const menu = @import("hudoptions/menu.zig");
pub const screens = @import("hudoptions/screens.zig");

test {
    _ = menu;
    _ = screens;
}

/// A screen of the menu: `pause_screen` 1, 3 and 4.
pub const Screen = enum { main, audio, video };

/// What a choice ends the pause in, which `mission_paused_frame` acts on: `pause_screen` 5, 6 and
/// 7.
pub const Outcome = enum { restart, continue_mission, leave_mission };

/// Where a screen's choice goes.
pub const Next = union(enum) {
    screen: Screen,
    outcome: Outcome,
};

/// What the screens show and change, as the game keeps it in its globals, and the file they save
/// it to as they are left.
pub const Settings = struct {
    file: *profile.File,
    sound: *hog_snd.Sound,
    /// `stdsmp.fat`, whose sound 14 tries the effects' volume.
    stdsmp: fat.Bank,
    /// The camera, whose cockpit setting (`Camera.setting`) the video screen changes, its cockpit
    /// mode following it.
    camera: *camera.Camera,
    /// The brightness (`sr + 0x15FA`), 0.5 to 2, and whether the device sets it
    /// (`sr + 0x38` bit 0), which shows its slider. OpenReliant's devices don't set it yet (#209):
    /// the slider stays hidden, as it does on hardware without gamma, and the brightness goes
    /// back to the file as it came, or as RESET DEFAULTS sets it, as the game does there.
    brightness: *f32,
    gamma: bool = false,
};

/// What a screen draws with and reads for a frame.
pub const Context = struct {
    ui: menu.Ui,
    pointer: menu.Pointer,
    /// Whether Escape went down since the last frame (`key_pressed`, once).
    escaped: bool,
    settings: Settings,
};

/// What `pause_menu_draw` draws with.
pub const Frame = struct {
    target: device.Device,
    screen: [2]u32,
    /// The display's set of shapes, and its font, the menus' font 0 (`hud_font`).
    art: *hud.Art,
    font: *hud.Opened,
    strings: *const language.Language,
    devices: *input.Devices,
    settings: Settings,
    /// **Improvement.** OpenReliant's version, written small in the menu's bottom right corner.
    version: ?[]const u8 = null,
};

/// The pause menu's state, which the game keeps in `hudoptions.cpp`'s globals.
pub const PauseMenu = struct {
    /// `pause_screen` (`0x0057DAA4`): the screen shown, or what a choice ended the pause in.
    at: Next = .{ .screen = .main },
    /// `pause_screen_entered` (`0x0057DABC`): the screen whose enter routine last ran.
    entered: ?Screen = null,
    pointer: menu.Pointer = .{},
    /// The menu's fonts, open while it is.
    fonts: ?Fonts = null,
    /// Each screen's own state.
    screens: struct {
        main: screens.Main = .{},
        audio: screens.Audio = .{},
        video: screens.Video = .{},
    } = .{},
    /// `pause_view_setting` (`0x00582E88`), `main.cpp`'s: the cockpit setting as the game paused,
    /// which resuming compares.
    view_setting: camera.CockpitSetting = .cockpit,

    /// `optfnt.fnt` and `smlfnt2.fnt`, as `hog_load` read them and `font_open` opened them
    /// (`menu_font_large`, `menu_font_small`), and what holds them and their glyphs' images.
    const Fonts = struct {
        gpa: Allocator,
        small: hud.Opened,
        large: hud.Opened,
        files: [2][]u8,
    };

    pub const small_font = "interface\\smlfnt2.fnt";
    pub const large_font = "interface\\optfnt.fnt";

    pub fn isOpen(pause_menu: PauseMenu) bool {
        return pause_menu.fonts != null;
    }

    /// `pause_menu_open` (`0x00490600`), as the game pauses: opens the fonts from `archive` and
    /// starts on the main screen. The game also ends the missile lock tone; missiles are not
    /// ported yet (#39).
    pub fn open(pause_menu: *PauseMenu, gpa: Allocator, archive: bigfile.Hog) !void {
        const small = try archive.readFile(gpa, small_font);
        errdefer gpa.free(small);
        const large = try archive.readFile(gpa, large_font);
        errdefer gpa.free(large);
        pause_menu.fonts = .{
            .gpa = gpa,
            .small = .ramp(try fnt.Font.parse(small)),
            .large = .ramp(try fnt.Font.parse(large)),
            .files = .{ small, large },
        };
        pause_menu.at = .{ .screen = .main };
        pause_menu.entered = null;
    }

    /// `pause_menu_close` (`0x004906D0`), as the game resumes: frees the fonts.
    pub fn close(pause_menu: *PauseMenu) void {
        const fonts = if (pause_menu.fonts) |*open_fonts| open_fonts else return;
        fonts.small.deinit(fonts.gpa);
        fonts.large.deinit(fonts.gpa);
        for (fonts.files) |file| fonts.gpa.free(file);
        pause_menu.fonts = null;
        pause_menu.at = .{ .screen = .main };
    }

    /// What a choice has ended the pause in, once one has, while the menu is open: the paused
    /// frame acts on it once, and resuming closes the menu.
    pub fn outcome(pause_menu: PauseMenu) ?Outcome {
        if (!pause_menu.isOpen()) return null;
        return switch (pause_menu.at) {
            .screen => null,
            .outcome => |ended| ended,
        };
    }

    /// `pause_menu_draw` (`0x004906F0`), the overlay while paused, with the pointer brought up to
    /// date first as `mission_paused_frame` does (`menu_mouse_update`). A screen shown for the
    /// first time runs its enter routine; if its choice goes elsewhere, it runs its leave routine.
    /// The pointer is drawn last.
    pub fn draw(pause_menu: *PauseMenu, frame: Frame) menu.Error!void {
        const fonts = if (pause_menu.fonts) |*open_fonts| open_fonts else return;
        pause_menu.pointer.update(frame.devices.mouse, frame.screen);
        const ui: menu.Ui = .{
            .gpa = fonts.gpa,
            .target = frame.target,
            .screen = frame.screen,
            .scale = hud.scaleFor(frame.screen),
            .art = frame.art,
            .fonts = .{ .display = frame.font, .small = &fonts.small, .large = &fonts.large },
            .strings = frame.strings,
        };
        const screen = switch (pause_menu.at) {
            .screen => |shown| shown,
            .outcome => return,
        };
        if (pause_menu.entered != screen) {
            switch (screen) {
                inline else => |entering| {
                    const state = &@field(pause_menu.screens, @tagName(entering));
                    if (@hasDecl(@TypeOf(state.*), "enter")) state.enter(frame.settings);
                },
            }
            pause_menu.entered = screen;
        }
        const context: Context = .{
            .ui = ui,
            .pointer = pause_menu.pointer,
            .escaped = frame.devices.keyboard.pressed(input.scan.escape, .none, true),
            .settings = frame.settings,
        };
        const next = switch (screen) {
            inline else => |shown| try @field(pause_menu.screens, @tagName(shown)).frame(context),
        };
        if (next) |going| if (!std.meta.eql(going, pause_menu.at)) {
            switch (screen) {
                inline else => |leaving| {
                    const state = &@field(pause_menu.screens, @tagName(leaving));
                    if (@hasDecl(@TypeOf(state.*), "leave")) try state.leave(frame.settings);
                },
            }
            pause_menu.at = going;
        };
        if (frame.version) |version| try writeVersion(ui, version);
        try ui.drawPointer(pause_menu.pointer);
    }

    /// OpenReliant's name and version, dimmed, right-aligned in the bottom right corner.
    fn writeVersion(ui: menu.Ui, version: []const u8) Allocator.Error!void {
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "OpenReliant {s}", .{version}) catch version;
        const height: i32 = @intCast(ui.fonts.small.font.header.height);
        const at: [2]i32 = .{ ui.across(1) - ui.scaled(8), ui.down(1) - ui.scaled(8 + height) };
        try ui.writeText(.small, at, text, menu.lit(menu.orange, 0.5), .right);
    }
};

pub const testing = struct {
    /// An archive with the menu's two fonts, in a directory of its own.
    pub const FontArchive = struct {
        tmp: std.testing.TmpDir,
        hog: bigfile.Hog,

        pub fn close(fonts: *FontArchive, gpa: Allocator) void {
            fonts.hog.close(gpa);
            fonts.tmp.cleanup();
        }
    };

    pub fn fontArchive(gpa: Allocator) !FontArchive {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const font = comptime fnt.testing.font(true);
        try bigfile.testing.write(gpa, std.testing.io, tmp.dir, bigfile.resource_name, &.{
            .{ .name = "smlfnt2.fnt", .data = font },
            .{ .name = "optfnt.fnt", .data = font },
        });
        return .{ .tmp = tmp, .hog = try .open(gpa, std.testing.io, tmp.dir, bigfile.resource_name) };
    }
};

test "PauseMenu.outcome" {
    const gpa = std.testing.allocator;
    var archive = try testing.fontArchive(gpa);
    defer archive.close(gpa);
    var pause_menu: PauseMenu = .{};
    try pause_menu.open(gpa, archive.hog);
    try std.testing.expectEqual(null, pause_menu.outcome());
    pause_menu.at = .{ .outcome = .restart };
    try std.testing.expectEqual(Outcome.restart, pause_menu.outcome().?);
    // Once the game resumes and the menu closes, the choice is spent: it is acted on once.
    pause_menu.close();
    try std.testing.expectEqual(null, pause_menu.outcome());
    try std.testing.expectEqual(Next{ .screen = .main }, pause_menu.at);
}
