const config = @import("config");

const RegionListMap = std.array_hash_map.String([]const u8);
const GatewayMap = std.array_hash_map.Auto(GatewayKey, []const u8);

// version-to-response (query_dispatch)
region_list_map: RegionListMap,
gateway_map: GatewayMap,

pub const Server = std.meta.FieldEnum(@TypeOf(config.servers));

pub const Version = std.meta.FieldEnum(@TypeOf(config.versions));

pub const GatewayKey = struct {
    server: Server,
    version: Version,
};

/// Constructs and serializes all of the possible responses
/// according to the config.zon
///
/// although the configuration is comptime, the construction of JSON
/// happens here, at startup.
pub fn build(arena: Allocator) Allocator.Error!Data {
    return .{
        .region_list_map = try buildRegionListMap(arena),
        .gateway_map = try buildGatewayMap(arena),
    };
}

fn buildRegionListMap(arena: Allocator) Allocator.Error!RegionListMap {
    var map: RegionListMap = .empty;
    try map.ensureTotalCapacity(arena, @typeInfo(Version).@"enum".fields.len);

    const ServerListInfo = struct {
        retcode: i32,
        name: []const u8,
        title: []const u8,
        dispatch_url: []const u8,
        ping_url: []const u8,
        biz: []const u8,
        area: u8,
        env: u8,
        is_recommend: bool,
    };

    inline for (std.enums.values(Version)) |version| {
        const server_names = @field(config.versions, @tagName(version)).servers;
        var region_list: [server_names.len]ServerListInfo = undefined;

        inline for (server_names, &region_list) |name, *list_info| {
            const server_config = @field(config.servers, name);
            list_info.* = .{
                .name = name,
                .title = server_config.title,
                .dispatch_url = config.outer_address ++ "/query_gateway/" ++ name,
                .biz = "nap_global",
                .env = 2,
                .area = 2,
                .retcode = 0,
                .ping_url = "",
                .is_recommend = true,
            };
        }

        map.putAssumeCapacity(
            @tagName(version),
            try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(
                .{ .retcode = 0, .region_list = region_list },
                .{},
            )}),
        );
    }

    return map;
}

fn buildGatewayMap(arena: Allocator) Allocator.Error!GatewayMap {
    var map: GatewayMap = .empty;
    try map.ensureTotalCapacity(arena, comptime count: {
        var entries: usize = 0;
        for (std.enums.values(Version)) |version|
            entries += @field(config.versions, @tagName(version)).servers.len;

        break :count entries;
    });

    inline for (std.enums.values(Version)) |version_tag| {
        const version = @field(config.versions, @tagName(version_tag));
        inline for (version.servers) |server_name| {
            const server = @field(config.servers, server_name);
            const server_tag = @field(Server, server_name);

            const data = .{
                .retcode = 0,
                .title = server.title,
                .region_name = server_name,
                .client_secret_key = server.client_secret_key,
                .gateway = server.gateway,
                .region_ext = .{ .func_switch = .{ .isKcp = 1 } },
                .cdn_conf_ext = version.cdn_conf,
            };

            const plaintext = try std.fmt.allocPrint(
                arena,
                "{f}",
                .{std.json.fmt(data, .{})},
            );

            const num_blocks = std.math.divCeil(usize, plaintext.len, rmcrypt.rsa.max_unpadded_size) catch
                unreachable; // `max_unpadded_size` is nonzero.

            const blocks = try arena.alloc(u8, num_blocks * rmcrypt.rsa.block_size);
            for (0..num_blocks) |n| {
                var plain_block = plaintext[n * rmcrypt.rsa.max_unpadded_size ..];
                plain_block.len = @min(plain_block.len, rmcrypt.rsa.max_unpadded_size);

                rmcrypt.rsa.client_public_key.encrypt(
                    plain_block,
                    blocks[n * rmcrypt.rsa.block_size ..][0..rmcrypt.rsa.block_size],
                );
            }

            var sign: [rmcrypt.rsa.block_size]u8 = undefined;
            rmcrypt.rsa.server_private_key.sign(plaintext, &sign);

            map.putAssumeCapacity(
                .{ .version = version_tag, .server = server_tag },
                try std.fmt.allocPrint(arena,
                    \\{{"content": "{b64}", "sign": "{b64}"}}
                , .{ blocks, &sign }),
            );
        }
    }

    return map;
}

const Allocator = std.mem.Allocator;

const rmcrypt = @import("rmcrypt");
const std = @import("std");
const Data = @This();
