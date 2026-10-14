const World = @import("world.zig").World;
const Block = @import("block.zig").Block;
const Voxel = @import("voxel.zig").Voxel;

/// Block coordinates: exterior X/Z 0..15, floor Y=-1, room Y=0..3,
/// roof Y=4. One-block walls leave a 14x14x4-block interior.
/// Seed once at startup; setBlock keeps the structure editable and protects it
/// from background chunk generation. Materials are opaque and nonreflective.
pub fn place(world: *World) !void {
    const wall = Block.initMono(0, Voxel.rgb(128, 128, 128));
    const floor = Block.initMono(0, Voxel.rgb(145, 65, 45));
    for (0..16) |z| for (0..16) |x| {
        const bx: i32 = @intCast(x);
        const bz: i32 = @intCast(z);
        try world.setBlock(.{ bx, -1, bz }, &floor);
        try world.setBlock(.{ bx, 4, bz }, &wall);
        if (x != 0 and x != 15 and z != 0 and z != 15) continue;
        for (0..4) |y| {
            // Two-block-wide, three-block-high doorway facing negative Z.
            if (z == 0 and (x == 7 or x == 8) and y < 3) continue;
            try world.setBlock(.{ bx, @intCast(y), bz }, &wall);
        }
    };
}
