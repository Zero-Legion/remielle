pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;

    var writer: Writer = .init(std.Io.File.stderr().handle, &buffer);
    const terminal: std.Io.Terminal = .{
        .writer = &writer.interface,
        .mode = .escape_codes,
    };

    std.log.defaultLogFileTerminal(level, scope, format, args, terminal) catch {};
    writer.interface.flush() catch {};
}

const Writer = struct {
    file: posix.fd_t,
    interface: std.Io.Writer,

    pub fn init(file: posix.fd_t, buffer: []u8) Writer {
        return .{
            .file = file,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        var splat_backup_buffer: [64]u8 = undefined;
        var iovecs_buffer: [16]posix.iovec_const = undefined;
        var iovecs_count: usize = 0;

        if (io_w.end != 0)
            _ = addVec(&iovecs_buffer, &iovecs_count, io_w.buffer[0..io_w.end]);

        // `data` -> `iovecs_buffer`
        for (data[0 .. data.len - 1]) |buf| {
            if (!addVec(&iovecs_buffer, &iovecs_count, buf))
                break;
        } else {
            const pattern = data[data.len - 1];

            if (iovecs_count != iovecs_buffer.len) switch (splat) {
                0 => {},
                1 => _ = addVec(&iovecs_buffer, &iovecs_count, pattern),
                else => amortize_splat: switch (pattern.len) {
                    0 => {},
                    1 => {
                        const memset_len = @min(splat_backup_buffer.len, splat);
                        @memset(&splat_backup_buffer, pattern[0]);
                        var remaining_splat = splat - memset_len;

                        while (remaining_splat >= splat_backup_buffer.len) {
                            if (!addVec(&iovecs_buffer, &iovecs_count, &splat_backup_buffer))
                                // Ran out of iovecs
                                break :amortize_splat;

                            remaining_splat -= splat_backup_buffer.len;
                        }

                        _ = addVec(&iovecs_buffer, &iovecs_count, splat_backup_buffer[0..remaining_splat]);
                    },
                    else => while (addVec(&iovecs_buffer, &iovecs_count, pattern)) {},
                },
            };
        }

        if (iovecs_count == 0) {
            @branchHint(.cold);
            return 0;
        }

        const written = posix.writev(writer.file, iovecs_buffer[0..iovecs_count]) catch
            return error.WriteFailed;

        if (io_w.end == 0) return written;

        if (written >= io_w.end) {
            io_w.end = 0;
            return written - io_w.end;
        } else {
            _ = io_w.consume(written);
            return 0;
        }
    }

    fn addVec(iovecs: []posix.iovec_const, count: *usize, data: []const u8) bool {
        if (data.len == 0 or iovecs.len == count.*) return false;
        defer count.* += 1;

        iovecs[count.*] = .{ .base = data.ptr, .len = @intCast(data.len) };
        return true;
    }
};

const posix = rmio.posix;
const rmio = @import("root.zig");
const std = @import("std");
