const std = @import("std");

// Legacy modes remain representable for existing event producers; only developer
// has a mapping today. Requests for other modes receive unsupported_mode.
pub const Mode = enum { developer, gameplay, UI, console };
pub const Key = enum {
    SPACE,
    APOSTROPHE,
    COMMA,
    MINUS,
    PERIOD,
    SLASH,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    SEMICOLON,
    EQUAL,
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    LEFT_BRACKET,
    BACKSLASH,
    RIGHT_BRACKET,
    GRAVE_ACCENT,
    WORLD_1,
    WORLD_2,
    ESCAPE,
    ENTER,
    TAB,
    BACKSPACE,
    INSERT,
    DELETE,
    RIGHT,
    LEFT,
    DOWN,
    UP,
    PAGE_UP,
    PAGE_DOWN,
    HOME,
    END,
    CAPS_LOCK,
    SCROLL_LOCK,
    NUM_LOCK,
    PRINT_SCREEN,
    PAUSE,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
    F21,
    F22,
    F23,
    F24,
    F25,
    KP_0,
    KP_1,
    KP_2,
    KP_3,
    KP_4,
    KP_5,
    KP_6,
    KP_7,
    KP_8,
    KP_9,
    KP_DECIMAL,
    KP_DIVIDE,
    KP_MULTIPLY,
    KP_SUBTRACT,
    KP_ADD,
    KP_ENTER,
    KP_EQUAL,
    LEFT_SHIFT,
    LEFT_CONTROL,
    LEFT_ALT,
    LEFT_SUPER,
    RIGHT_SHIFT,
    RIGHT_CONTROL,
    RIGHT_ALT,
    RIGHT_SUPER,
    MENU,
};
pub const Mouse = enum { left, right, middle, button4, button5, button6, button7, button8 };
pub const Source = union(enum) { key: Key, mouse: Mouse };
pub const Action = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
    remove,
    place,
    toggle_removal,
    toggle_menu,
    back,
    activate,
    deselect,
    screenshot,
    toggle_fps,
    look,
    pointer,
};
pub const action_count = std.meta.fields(Action).len;
pub const Phase = enum { started, ended, cancelled, changed };
pub const ActionEvent = struct {
    sequence: u64 = 0,
    frame: u64,
    generation: u64,
    action: Action,
    phase: Phase,
    value: [2]f32 = .{ 0, 0 },
};
pub const Bindings = struct {
    count: u8 = 0,
    sources: [4]Source = [_]Source{.{ .key = .W }} ** 4,

    pub fn one(source: Source) Bindings {
        var result: Bindings = .{};
        result.count = 1;
        result.sources[0] = source;
        return result;
    }
};
pub const Profile = struct {
    version: u32 = 1,
    mode: Mode = .developer,
    bindings: [action_count]Bindings = defaults(),
};
pub const Replace = struct { request_id: u64, mode: Mode = .developer, action: Action, bindings: Bindings };
pub const Request = struct { request_id: u64, mode: Mode = .developer };
pub const ApplyProfile = struct { request_id: u64, profile: Profile };
pub const Rebind = struct { request_id: u64, mode: Mode = .developer, action: Action };
pub const Status = enum { applied, invalid_binding, unsupported_mode, invalid_version, capturing, cancelled };
pub const Result = struct { request_id: u64, status: Status, revision: u64 };
pub const BindingState = struct { request_id: u64, revision: u64, action: Action, bindings: Bindings };
pub const Candidate = struct { request_id: u64, action: Action, source: Source, conflict: ?Action };

pub fn defaults() [action_count]Bindings {
    var map = [_]Bindings{.{}} ** action_count;
    const actions = [_]Action{ .forward, .backward, .left, .right, .up, .down, .toggle_removal, .toggle_menu, .back, .screenshot, .toggle_fps };
    const keys = [_]Key{ .W, .S, .A, .D, .SPACE, .LEFT_SHIFT, .V, .TAB, .ESCAPE, .F2, .F3 };
    for (actions, keys) |action, key| map[@intFromEnum(action)] = Bindings.one(.{ .key = key });
    for ([_]Action{ .remove, .activate }) |action| map[@intFromEnum(action)] = Bindings.one(.{ .mouse = .left });
    for ([_]Action{ .place, .deselect }) |action| map[@intFromEnum(action)] = Bindings.one(.{ .mouse = .right });
    return map;
}

pub fn worldAction(action: Action) bool {
    return switch (action) {
        .forward, .backward, .left, .right, .up, .down, .remove, .place, .toggle_removal, .look => true,
        else => false,
    };
}
pub fn menuAction(action: Action) bool {
    return action == .activate or action == .deselect or action == .pointer;
}
pub fn bindable(action: Action) bool {
    return action != .look and action != .pointer;
}
pub fn validate(profile: Profile) Status {
    if (profile.version != 1) return .invalid_version;
    if (profile.mode != .developer) return .unsupported_mode;
    for (profile.bindings, 0..) |bindings, i| {
        if (bindings.count > bindings.sources.len) return .invalid_binding;
        if (!bindable(@enumFromInt(i)) and bindings.count != 0) return .invalid_binding;
    }
    return .applied;
}

// Files use stable action/source names; omitted entries inherit defaults and
// an empty source list explicitly unbinds an action.
const Entry = struct { action: Action, sources: []const Source };
const FileProfile = struct { version: u32 = 1, mode: Mode = .developer, bindings: []const Entry };
pub fn parseProfile(allocator: std.mem.Allocator, json: []const u8) !Profile {
    const parsed = try std.json.parseFromSlice(FileProfile, allocator, json, .{});
    defer parsed.deinit();
    var profile = Profile{ .version = parsed.value.version, .mode = parsed.value.mode };
    var seen = [_]bool{false} ** action_count;
    for (parsed.value.bindings) |entry| {
        const i = @intFromEnum(entry.action);
        if (seen[i] or entry.sources.len > 4) return error.InvalidProfile;
        seen[i] = true;
        var bindings = Bindings{ .count = @intCast(entry.sources.len) };
        @memcpy(bindings.sources[0..entry.sources.len], entry.sources);
        profile.bindings[i] = bindings;
    }
    if (validate(profile) != .applied) return error.InvalidProfile;
    return profile;
}
pub fn encodeProfile(allocator: std.mem.Allocator, profile: Profile) ![]u8 {
    if (validate(profile) != .applied) return error.InvalidProfile;
    var entries: [action_count]Entry = undefined;
    for (&entries, 0..) |*entry, i| entry.* = .{
        .action = @enumFromInt(i),
        .sources = profile.bindings[i].sources[0..profile.bindings[i].count],
    };
    return std.json.stringifyAlloc(allocator, FileProfile{ .bindings = &entries }, .{ .whitespace = .indent_2 });
}
pub fn loadProfile(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !Profile {
    const json = try dir.readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(json);
    return parseProfile(allocator, json);
}
pub fn saveProfile(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, profile: Profile) !void {
    const json = try encodeProfile(allocator, profile);
    defer allocator.free(json);
    var file = try dir.atomicFile(path, .{});
    defer file.deinit();
    try file.file.writeAll(json);
    try file.finish();
}
