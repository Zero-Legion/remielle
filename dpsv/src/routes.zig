const log = std.log.scoped(.@"remielle-dpsv::routes");

pub const Result = struct {
    status_line: []const u8,
    body: ?[]const u8,

    pub fn fail(comptime status: u16, comptime reason: []const u8) Result {
        return .{ .status_line = fmt.comptimePrint(
            "HTTP/1.1 {0d} {1s}\r\nConnection: close\r\n\r\n{1s}",
            .{ status, reason },
        ), .body = null };
    }

    pub fn ok(body: []const u8) Result {
        return .{
            .status_line = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n",
            .body = body,
        };
    }

    pub fn toSlices(result: *const Result, slices_buf: *[2][]const u8) [][]const u8 {
        slices_buf[0] = result.status_line;
        const body = result.body orelse return slices_buf[0..1];

        slices_buf[1] = body;
        return slices_buf;
    }
};

pub fn process(data: *const Data, request: *const http.RequestLine) Result {
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
            return .fail(400, "Bad Request");

        return .ok(data.region_list_map.get(parameters.version) orelse unsupported: {
            log.warn("unsupported version: {s}", .{parameters.version});
            break :unsupported
            \\{"retcode":70}
            ;
        });
    } else if (std.mem.startsWith(u8, request.path, "/query_gateway/")) {
        const server = std.meta.stringToEnum(Data.Server, request.path["/query_gateway/".len..]) orelse
            return .fail(599, "599 Service Unavailable");

        const parameters = request.extractQuery(GatewayParameters) catch
            return .fail(400, "Bad Request");

        const version = std.meta.stringToEnum(Data.Version, parameters.version) orelse
            return .ok(
                \\{"retcode": 70}
            );

        return .ok(data.gateway_map.get(.{ .version = version, .server = server }) orelse
            \\{"retcode": 70}
        );
    } else {
        return .fail(599, "599 Service Unavailable");
    }
}

const fmt = std.fmt;

const http = @import("http.zig");
const Data = @import("Data.zig");
const rmio = @import("rmio");

const std = @import("std");
