test {
    _ = @import("core/logging/logging.zig");
    _ = @import("core/events/event.zig");
}

test "Procedural generation" {
    _ = @import("world/generation/terrainGeneratorTest.zig");
    _ = @import("world/generation/noises/perlin.zig");
    //_ = @import("world/generation/noises/voronoi.zig");
    //_ = @import("world/generation/noises/domainWarped.zig");
    //_ = @import("world/generation/remapingFunctions/basic.zig");
    //_ = @import("world/generation/remapingFunctions/curve.zig");
}
