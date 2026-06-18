const log = std.log.scoped(.@"remielle-dpsv::routes");

pub const Response = struct {
    buffer: [buffer_size]u8,
    /// Amount of bytes copied into `buffer`.
    /// After this, it's `undefined`.
    buffer_end: usize,
    /// Taken from `Data`.
    body: ?[]const u8,

    pub const init: Response = .{
        .buffer = undefined,
        .buffer_end = 0,
        .body = null,
    };

    // This is only used for the request line; in case of `fail` also for the reason phrase.
    const buffer_size: usize = 1024;

    pub fn ok(
        rsp: *Response,
        /// Must be statically allocated and have a static lifetime.
        body: []const u8,
    ) void {
        const string = fmt.bufPrint(
            &rsp.buffer,
            "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        ) catch unreachable;

        rsp.buffer_end = string.len;
        rsp.body = body;
    }

    pub fn fail(
        rsp: *Response,
        status: u16,
        /// Will be copied into `rsp.buffer`.
        reason: []const u8,
    ) void {
        const string = fmt.bufPrint(
            &rsp.buffer,
            "HTTP/1.1 {0d} {1s}\r\nConnection: keep-alive\r\nContent-Length: {2d}\r\n\r\n{1s}",
            .{ status, reason, reason.len },
        ) catch
            unreachable; // `buffer_size` exceeded.

        rsp.buffer_end = string.len;
    }

    pub fn toSlices(rsp: *Response, slices_buf: *[2][]const u8) [][]const u8 {
        slices_buf[0] = rsp.buffer[0..rsp.buffer_end];
        const body = rsp.body orelse return slices_buf[0..1];

        slices_buf[1] = body;
        return slices_buf;
    }
};

pub fn process(data: *const Data, request: *const http.RequestLine, response: *Response) void {
    const DispatchParameters = struct {
        version: []const u8,
        language: u32,
        channel_id: u32,
        sub_channel_id: u32,
        platform: u32,
    };

    const GatewayParameters = struct {
        version: []const u8,
        rsa_ver: u32,
        language: u32,
        platform: u32,
        seed: []const u8,
        channel_id: u32,
        sub_channel_id: u32,
        token: []const u8,
    };

    if (std.mem.eql(u8, request.path, "/query_dispatch")) {
        const parameters = request.extractQuery(DispatchParameters) catch
            return response.fail(400, "Bad Request");

        return response.ok(data.region_list_map.get(parameters.version) orelse unsupported: {
            log.warn("unsupported version: {s}", .{parameters.version});
            break :unsupported
            \\{"retcode":70}
            ;
        });
    } else if (std.mem.startsWith(u8, request.path, "/query_gateway/")) {
        const server = std.meta.stringToEnum(Data.Server, request.path["/query_gateway/".len..]) orelse
            return response.fail(599, "599 Service Unavailable");

        const parameters = request.extractQuery(GatewayParameters) catch
            return response.fail(400, "Bad Request");

        const version = std.meta.stringToEnum(Data.Version, parameters.version) orelse
            return response.ok(
                \\{"retcode": 70}
            );

        return response.ok(data.gateway_map.get(.{ .version = version, .server = server }) orelse
            \\{"retcode": 70}
        );
    } else {
        return response.fail(599, "599 Service Unavailable");
    }
}

const fmt = std.fmt;

const http = @import("http.zig");
const Data = @import("Data.zig");

const std = @import("std");
