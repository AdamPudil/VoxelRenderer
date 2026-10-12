const std = @import("std");

pub const Voxel = packed struct(u64) {
    r: u8,
    g: u8,
    b: u8,
    refractive_index: u8,
    opacity: u8,
    reflectiveness: u8,
    luminescence: u8,
    metallic: u8,

    pub fn empty() Voxel {
        return .{
            .r = 0,
            .g = 0,
            .b = 0,
            .refractive_index = 0,
            .opacity = 0,
            .reflectiveness = 0,
            .luminescence = 0,
            .metallic = 0,
        };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Voxel {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .refractive_index = 0,
            .opacity = 255,
            .reflectiveness = 0,
            .luminescence = 0,
            .metallic = 0,
        };
    }

    pub fn getVoxel(
        r: u8,
        g: u8,
        b: u8,
        refractive_index: u8,
        opacity: u8,
        reflectiveness: u8,
        luminescence: u8,
    ) Voxel {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .refractive_index = refractive_index,
            .opacity = opacity,
            .reflectiveness = reflectiveness,
            .luminescence = luminescence,
            .metallic = 0,
        };
    }

    /// 0 = non-transmitting/empty; 1..255 encodes IOR 1..2.5.
    pub fn encodeIor(ior: f32) u8 {
        return 1 + @as(u8, @intFromFloat(@round((ior - 1) / 1.5 * 254)));
    }

    pub fn isEmpty(self: Voxel) bool {
        return self.opacity == 0 and self.refractive_index == 0;
    }
};
