const std = @import("std");

const l = @import("../logging/logging.zig");

const event = @import("event.zig");
const eventDesc = @import("eventDescriptor.zig");

pub fn getEventQueue(rules: []const eventDesc.EventTypeDescriptor) type {
    var fields: [rules.len]std.builtin.Type.StructField = undefined;

    for (rules, 0..) |rule, i| {
        const fieldType: type = rule.eventType;
        const fieldName: [:0]const u8 = @tagName(rule.group);

        fields[i] = .{
            .name = fieldName,
            .type = RingBuffer(fieldType, rule.bufferSize),
            .default_value = &RingBuffer(fieldType, rule.bufferSize){},
            .is_comptime = false,
            .alignment = 0,
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = std.builtin.Type.ContainerLayout.auto,
        .fields = fields[0..],
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

pub const RingBufferError = error{ Full, Empty };

pub fn RingBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        writeIdx: usize = 0,
        readIdx: usize = 0,
        size: usize = 0,
        buffer: [size]T = undefined,

        pub fn write(self: *RingBuffer(T, size), eve: T) !void {
            if (self.size == size) return RingBufferError.Full;

            self.buffer[self.writeIdx] = eve;

            self.writeIdx += 1;
            self.size += 1;
            if (self.writeIdx == size) {
                self.writeIdx = 0;
            }
        }

        pub fn read(self: *RingBuffer(T, size)) !T {
            if (self.readIdx == self.writeIdx) return RingBufferError.Empty;

            const ret = self.buffer[self.readIdx];

            self.readIdx += 1;
            self.size -= 1;
            if (self.readIdx == size) {
                self.readIdx = 0;
            }

            return ret;
        }

        pub fn getCount(self: RingBuffer(T, size)) usize {
            if (self.readIdx < self.writeIdx) return self.writeIdx - self.readIdx;
            if (self.readIdx > self.writeIdx) return self.writeIdx + (size - self.readIdx);
            return 0;
        }

        pub fn print(self: RingBuffer(T, size)) void {
            if (self.readIdx == self.writeIdx)
                l.logger.info("Buffer status: {d}/{d}", .{ 0, size });
            if (self.readIdx < self.writeIdx) {
                l.logger.info("Buffer status: {d}/{d}", .{ self.writeIdx - self.readIdx, size });
            }
            if (self.readIdx > self.writeIdx) {
                l.logger.info("Buffer status: {d}/{d}", .{ self.writeIdx + (size - self.readIdx), size });
            }
        }
    };
}
