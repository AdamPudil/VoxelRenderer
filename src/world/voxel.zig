const std = @import("std");

pub const Voxel = packed struct(u64) {
    r: u8,
    g: u8,
    b: u8,
    transparency: u8,
    opacity: u8,
    reflectiveness: u8,
    luminescence: u8,
    padding: u8,

    pub fn empty() Voxel {
        return .{
            .r = 0,
            .g = 0,
            .b = 0,
            .transparency = 0,
            .opacity = 0,
            .reflectiveness = 0,
            .luminescence = 0,
            .padding = 0,
        };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Voxel {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .transparency = 0,
            .opacity = 255,
            .reflectiveness = 0,
            .luminescence = 0,
            .padding = 0,
        };
    }

    pub fn isEmpty(self: Voxel) bool {
        return self.opacity == 0;
    }
};

pub fn makeVoxel(
    r: u8,
    g: u8,
    b: u8,
    transparency: u8,
    opacity: u8,
    reflectiveness: u8,
    luminescence: u8,
) Voxel {
    return .{
        .r = r,
        .g = g,
        .b = b,
        .transparency = transparency,
        .opacity = opacity,
        .reflectiveness = reflectiveness,
        .luminescence = luminescence,
        .padding = 0,
    };
}
