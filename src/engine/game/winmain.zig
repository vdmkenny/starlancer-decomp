//! `C:\lancer\game\winmain.cpp`: the game's entry, `WinMain` (`0x004A8B10`), and its message pump.
//! **Unverified:** the pump (`0x004AAB20`) lies after the last of the file's code that its
//! assertions place; by what it does it is this file's.
//!
//! Ported so far: what the pump does as the game's window goes inactive and active again, as far
//! as the sound and the pause go. `openreliant`'s own frame loop stands in for the rest.

const std = @import("std");

const main = @import("main.zig");
const Clock = main.Clock;
const input = @import("../input.zig");
const camera = @import("camera.zig");
const hog_snd = @import("hog_snd.zig");
const hudoptions = @import("hudoptions.zig");
const Sound = hog_snd.Sound;

/// The window's activation, as the pump follows it.
pub const App = struct {
    /// Whether the game's window is the active one. The pump goes by `window_suspended`
    /// (`0x005DDD28`), which `0x004A8260` sets as it puts the window away and `input_init`
    /// clears, while the renderer runs (`app_active`, `0x005D6CAC`). **Unverified:** what puts the
    /// window away.
    active: bool = true,
    /// `app_inactive_paused` (`0x005D6CAD`): whether the pump has paused the game for the window
    /// going inactive.
    paused: bool = false,
};

/// `message_pump` (`0x004AAB20`), the part that follows the window's activation. Going inactive,
/// the music, the 3D voices and the voices pause, and the pump waits on the window's messages
/// until it is active again; then the sound goes on. Only in a multiplayer session does it pause
/// the mission as well (`game_pause`), which it then leaves in its pause menu. The textures, which
/// DirectDraw loses with the window, need nothing in OpenReliant.
///
/// **Improvement.** OpenReliant pauses the mission into its menu in single player too, where the
/// game pauses only the sound and the timer's ticks pile up while the window is away. Active again,
/// the music goes on; the rest waits for the menu's CONTINUE.
pub fn followActivation(app: *App, pausing: main.Pausing) !void {
    if (app.active and app.paused) {
        pausing.sound.pauseMusic(false);
        app.paused = false;
    } else if (!app.active and !app.paused) {
        pausing.sound.pauseMusic(true);
        try main.pause(pausing, true);
        app.paused = true;
    }
}

test followActivation {
    const mss = @import("../mss.zig");
    const fat = @import("../../formats/fat.zig");
    const gpa = std.testing.allocator;
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    const v = sound.play(try fat.Bank.parse(&bytes), 1, hog_snd.loudest, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch).?;
    var archive = try hudoptions.testing.fontArchive(gpa);
    defer archive.close(gpa);
    var app: App = .{};
    var clock: Clock = .{};
    var view: camera.Camera = .{};
    const player: u16 = 0;
    var menu: hudoptions.PauseMenu = .{};
    defer menu.close();
    const pausing: main.Pausing = .{
        .gpa = gpa,
        .clock = &clock,
        .sound = &sound,
        .menu = &menu,
        .archive = archive.hog,
        .camera = &view,
        .player = &player,
    };

    // Active, nothing changes.
    try followActivation(&app, pausing);
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));

    // Inactive, the sound and the clock stop, once, and the menu opens.
    app.active = false;
    try followActivation(&app, pausing);
    try followActivation(&app, pausing);
    try std.testing.expect(clock.paused and app.paused and menu.isOpen());
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));

    // Active again, the mission waits in the menu; continuing, the voices go on.
    app.active = true;
    try followActivation(&app, pausing);
    try std.testing.expect(clock.paused and !app.paused);
    try main.pause(pausing, false);
    try std.testing.expect(!clock.paused and !menu.isOpen());
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));
}

/// The longest name `missionPath` makes; the game's buffer is far larger.
pub const mission_path_size = 32;

/// The mission file `WinMain` names for mission `number` at the mission's start (`0x004A9C42`,
/// `0x004AA40A`): `.\missions\mission<number>.dte`. Mission 25, once its first part is won
/// (`mission25_second_part`, `0x00587CDC`), is `mission251.dte`, its second part; and in a
/// multiplayer game mission 3 is `mission311.dte`.
pub fn missionPath(buffer: *[mission_path_size]u8, number: u16, second_part: bool, multiplayer: bool) []const u8 {
    if (number == second_part_mission and second_part) return second_part_path;
    if (number == multiplayer_mission and multiplayer) return multiplayer_path;
    return std.fmt.bufPrint(buffer, "{s}{d}" ++ file_end, .{ path_start, number }) catch unreachable;
}

/// A mission's file, `mission<number>.dte`, and where it lies.
const file_start = "mission";
const file_end = ".dte";
const path_start = ".\\missions\\" ++ file_start;
/// Mission 25, whose second part is a file of its own (`0x00509728`), and mission 3, whose
/// multiplayer game is (`0x0050970C`).
const second_part_mission = 25;
const second_part_path = path_start ++ "251" ++ file_end;
const multiplayer_mission = 3;
const multiplayer_path = path_start ++ "311" ++ file_end;

/// The number in a mission file's name, `mission<number>.dte` as `missionPath` names it, whatever
/// its case; null for any other name. Added for OpenReliant, which lists the missions a game's
/// folder holds (`openreliant missions`).
pub fn missionNumber(name: []const u8) ?u16 {
    if (name.len <= file_start.len + file_end.len) return null;
    if (!std.ascii.startsWithIgnoreCase(name, file_start) or !std.ascii.endsWithIgnoreCase(name, file_end)) return null;
    return std.fmt.parseInt(u16, name[file_start.len .. name.len - file_end.len], 10) catch null;
}

test missionNumber {
    try std.testing.expectEqual(1, missionNumber("mission1.dte"));
    try std.testing.expectEqual(251, missionNumber("MISSION251.DTE"));
    try std.testing.expectEqual(null, missionNumber("mission.dte"));
    try std.testing.expectEqual(null, missionNumber("missionx.dte"));
    try std.testing.expectEqual(null, missionNumber("mission1.shp"));
    // Every name `missionPath` makes reads back.
    var buffer: [mission_path_size]u8 = undefined;
    try std.testing.expectEqual(25, missionNumber(std.fs.path.basenameWindows(missionPath(&buffer, 25, false, false))));
}

/// What `WinMain` does before each single-player mission (`0x004A99CC`): puts back the pilot's
/// kills as the last mission the pilot came through kept them (`gameflow.endMission`). **Not
/// ported:** the rank, the medals and the other tallies it puts back with them, which no screen
/// of OpenReliant shows.
pub fn startMission(player: *input.Player) void {
    player.kills.count = player.kills.kept;
}

test startMission {
    var player: input.Player = .{ .kills = .{ .count = 9, .kept = 4 } };
    startMission(&player);
    try std.testing.expectEqual(4, player.kills.count);
}

test missionPath {
    var buffer: [mission_path_size]u8 = undefined;
    try std.testing.expectEqualStrings(".\\missions\\mission1.dte", missionPath(&buffer, 1, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission25.dte", missionPath(&buffer, 25, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission251.dte", missionPath(&buffer, 25, true, false));
    try std.testing.expectEqualStrings(".\\missions\\mission3.dte", missionPath(&buffer, 3, false, false));
    try std.testing.expectEqualStrings(".\\missions\\mission311.dte", missionPath(&buffer, 3, false, true));
    try std.testing.expectEqualStrings(".\\missions\\mission65535.dte", missionPath(&buffer, 65535, false, false));
}
