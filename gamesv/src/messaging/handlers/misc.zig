pub fn getServerTimestamp(txn: handlers.Transaction(.GetServerTimestampCsReq)) !void {
    try txn.respond(.{
        .timestamp = @intCast(posix.timespecToMs(txn.time)),
    });
}

pub fn getMiscData(txn: handlers.Transaction(.GetMiscDataCsReq)) !void {
    var unlocked_list_buf: [templates.unlock_config.entries.len]i32 = undefined;
    var unlocked_list: std.ArrayList(i32) = .initBuffer(&unlocked_list_buf);

    for (templates.unlock_config.entries) |config|
        unlocked_list.appendAssumeCapacity(@intCast(config.id));

    var post_girls_buf: [templates.post_girl_config.entries.len]pb.PostGirlItem = undefined;
    var post_girls: std.ArrayList(pb.PostGirlItem) = .initBuffer(&post_girls_buf);

    for (templates.post_girl_config.entries) |config|
        post_girls.appendAssumeCapacity(.{ .id = config.id });

    var show_post_girls_buf: [1]u32 = .{
        @intFromEnum(templates.post_girl_config.Id.Avatar_Female_Size03_Promeia),
    };

    const show_post_girls: std.ArrayList(u32) = .fromOwnedSlice(&show_post_girls_buf);

    try txn.respond(.{ .data = .{
        .unlock = .{ .unlocked_list = unlocked_list },
        .post_girl = .{
            .post_girl_item_list = post_girls,
            .show_post_girl_id_list = show_post_girls,
        },
        .business_card = .init,
        .player_accessory = .{
            .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
        },
    } });
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const posix = @import("rmio").posix;
const pb = @import("rmpb").main;
const std = @import("std");
