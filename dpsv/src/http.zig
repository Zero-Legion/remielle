pub const RequestLine = struct {
    pub const Method = enum {
        GET,
        HEAD,

        pub fn hasResponseBody(method: Method) bool {
            return switch (method) {
                .GET => true,
                .HEAD => false,
            };
        }
    };

    method: Method,
    path: []const u8,
    query: []const u8,

    pub const ParseError = error{
        /// The request line didn't fit into `reader.buffer`.
        StreamTooLong,
        /// The request line doesn't contain the required components in canonical form.
        MissingComponents,
        /// The specified request method is not defined in `Method`.
        UnsupportedMethod,
    } || Io.Reader.Error;

    /// `reader` must have a non-zero buffer size.
    pub fn parse(reader: *Io.Reader) ParseError!RequestLine {
        const line = try reader.takeDelimiterInclusive('\r');

        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const raw_method = parts.next() orelse return error.MissingComponents;
        const method = std.meta.stringToEnum(Method, raw_method) orelse
            return error.UnsupportedMethod;

        const target = parts.next() orelse return error.MissingComponents;

        const query_start = std.mem.findScalar(u8, target, '?') orelse
            return .{ .method = method, .path = target, .query = "" };

        return .{
            .method = method,
            .path = target[0..query_start],
            .query = if (target.len > query_start + 1)
                target[query_start + 1 ..]
            else
                "",
        };
    }

    pub const ExtractQueryError = error{
        /// The query string is formed in an unexpected way
        Malformed,
        /// Non-optional query parameters are missing
        MissingParameters,
        /// Query string has parameters not defined in resulting struct
        UnexpectedParameters,
        TypeMismatch,
    };

    pub fn extractQuery(rl: *const RequestLine, comptime Q: type) ExtractQueryError!Q {
        var it = std.mem.tokenizeScalar(u8, rl.query, '&');
        var result: Q = undefined;

        const Name = std.meta.FieldEnum(Q);
        var set: EnumSet(std.meta.FieldEnum(Q)) = .empty;

        while (it.next()) |pair| {
            var split = std.mem.splitScalar(u8, pair, '=');
            const param = split.next().?;
            const value = split.next() orelse return error.Malformed;
            if (split.next() != null) return error.Malformed;

            const name = std.meta.stringToEnum(Name, param) orelse
                return error.UnexpectedParameters;

            set.insert(name);

            switch (name) {
                inline else => |n| @field(result, @tagName(n)) = switch (@FieldType(Q, @tagName(n))) {
                    []const u8 => value,
                    u32, u64 => |T| std.fmt.parseInt(T, value, 10) catch return error.TypeMismatch,
                    else => |T| @compileError("Unsupported type " ++ @typeName(T)),
                },
            }
        } else if (!set.eql(.full)) return error.MissingParameters;

        return result;
    }
};

const Io = std.Io;
const EnumSet = std.EnumSet;

const std = @import("std");
