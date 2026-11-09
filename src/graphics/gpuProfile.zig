//! Runtime identification of the active OpenGL device, independent of quality.
const std = @import("std");

pub const Profile = enum {
    auto,
    thinkpad,
    desktop,
    rtx3060,
    vega56,
    vega,

    pub fn parse(name: []const u8) !Profile {
        return std.meta.stringToEnum(Profile, name) orelse error.InvalidShaderProfile;
    }

    pub fn shaderPath(self: Profile) []const u8 {
        return switch (self) {
            .auto => unreachable, // Resolve against the active context first.
            .thinkpad => "src/graphics/shaders/voxel",
            // Separate device selections currently share the desktop shader.
            // Tune only after measurement; GPU names are not quality rankings.
            .desktop, .rtx3060, .vega56, .vega => "src/graphics/shaders/desktop/voxel",
        };
    }
};

pub const Device = enum {
    unknown,
    rtx3060,
    vega56,
    vega_family,

    pub fn label(self: Device) []const u8 {
        return switch (self) {
            .unknown => "unrecognized GPU",
            .rtx3060 => "GeForce RTX 3060",
            .vega56 => "Radeon RX Vega 56",
            .vega_family => "Radeon RX Vega family (exact model not identified)",
        };
    }
};

fn contains(text: []const u8, part: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, part) != null;
}

fn hasModel(text: []const u8, model: []const u8) bool {
    const at = std.ascii.indexOfIgnoreCase(text, model) orelse return false;
    const end = at + model.len;
    return (at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) and
        (end == text.len or !std.ascii.isAlphanumeric(text[end]));
}

pub fn identify(vendor: []const u8, renderer: []const u8) Device {
    if (contains(renderer, "llvmpipe") or contains(renderer, "softpipe") or contains(renderer, "software")) return .unknown;
    if (contains(vendor, "nvidia") or contains(renderer, "nvidia")) {
        if (hasModel(renderer, "RTX 3060") and !contains(renderer, "3060 Ti")) return .rtx3060;
    }
    if (contains(vendor, "amd") or contains(vendor, "ati") or contains(vendor, "advanced micro devices") or contains(renderer, "radeon")) {
        if (hasModel(renderer, "Vega 56")) return .vega56;
        // Do not confuse integrated "Vega 8/10 Graphics" with discrete RX Vega.
        // Generic RX Vega / VEGA10 names cannot distinguish the 56 and 64 models.
        if (hasModel(renderer, "RX Vega") or hasModel(renderer, "VEGA10")) return .vega_family;
    }
    return .unknown;
}

pub const Selection = struct {
    device: Device,
    profile: Profile,
    compatibility_fallback: bool = false,
};

pub fn select(requested: Profile, vendor: []const u8, renderer: []const u8, major: i32, minor: i32) !Selection {
    if (major < 4 or (major == 4 and minor < 2)) return error.OpenGLContextUnsupported;
    const desktop_supported = major > 4 or (major == 4 and minor >= 6);
    const device = identify(vendor, renderer);
    if (requested != .auto) {
        if (requested != .thinkpad and !desktop_supported) return error.DesktopShaderUnsupported;
        return .{ .device = device, .profile = requested };
    }
    const detected: Profile = switch (device) {
        .rtx3060 => .rtx3060,
        .vega56 => .vega56,
        .vega_family => .vega,
        .unknown => .thinkpad,
    };
    const fallback = detected != .thinkpad and !desktop_supported;
    return .{ .device = device, .profile = if (fallback) .thinkpad else detected, .compatibility_fallback = fallback };
}

test "device detection handles explicit models, family names and unrelated GPUs" {
    const cases = .{
        .{ "NVIDIA Corporation", "NVIDIA GeForce RTX 3060/PCIe/SSE2", Device.rtx3060 },
        .{ "nvidia corporation", "nvidia geforce rtx 3060/pcie/sse2", Device.rtx3060 },
        .{ "NVIDIA Corporation", "NVIDIA GeForce RTX 3060 Ti/PCIe/SSE2", Device.unknown },
        .{ "NVIDIA Corporation", "NVIDIA GeForce RTX 30600", Device.unknown },
        .{ "ATI Technologies Inc.", "Radeon RX Vega 56", Device.vega56 },
        .{ "AMD", "AMD Radeon RX Vega (VEGA10, DRM 3.52, LLVM 15.0.7)", Device.vega_family },
        .{ "X.Org", "Radeon RX Vega (vega10, LLVM 15.0.7)", Device.vega_family },
        .{ "AMD", "Radeon RX Vega 64", Device.vega_family },
        .{ "AMD", "AMD Radeon Vega 10 Graphics", Device.unknown },
        .{ "AMD", "AMD Radeon RX 6800", Device.unknown },
        .{ "Intel", "Mesa Intel UHD Graphics", Device.unknown },
        .{ "Mesa", "llvmpipe (LLVM 15.0.7, 256 bits)", Device.unknown },
        .{ "", "", Device.unknown },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[2], identify(case[0], case[1]));
}

test "automatic profiles preserve identity across capability fallback and manual override" {
    const vega = try select(.auto, "AMD", "Radeon RX Vega 56", 4, 6);
    try std.testing.expectEqual(Profile.vega56, vega.profile);
    try std.testing.expectEqual(Profile.vega, (try select(.auto, "AMD", "Radeon RX Vega (VEGA10)", 4, 6)).profile);
    try std.testing.expectEqual(Profile.rtx3060, (try select(.auto, "NVIDIA", "GeForce RTX 3060", 4, 6)).profile);
    const fallback = try select(.auto, "AMD", "Radeon RX Vega 56", 4, 2);
    try std.testing.expectEqual(Device.vega56, fallback.device);
    try std.testing.expectEqual(Profile.thinkpad, fallback.profile);
    try std.testing.expect(fallback.compatibility_fallback);
    try std.testing.expectEqual(Profile.vega56, (try select(.vega56, "Mesa", "llvmpipe", 4, 6)).profile);
    try std.testing.expectEqual(Profile.thinkpad, (try select(.thinkpad, "NVIDIA", "GeForce RTX 3060", 4, 6)).profile);
    try std.testing.expectError(error.DesktopShaderUnsupported, select(.vega56, "AMD", "Radeon RX Vega 56", 4, 2));
    try std.testing.expectError(error.OpenGLContextUnsupported, select(.auto, "", "", 4, 1));
    for (std.enums.values(Profile)) |profile| try std.testing.expectEqual(profile, try Profile.parse(@tagName(profile)));
    try std.testing.expectError(error.InvalidShaderProfile, Profile.parse("fastest"));
}
