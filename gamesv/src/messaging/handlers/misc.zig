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

    var post_girls_buffer: [1]pb.PostGirlItem = undefined;
    var post_girls: std.ArrayList(pb.PostGirlItem) = .initBuffer(&post_girls_buffer);

    var show_post_girls_buffer: [1]u32 = undefined;
    var show_post_girls: std.ArrayList(u32) = .initBuffer(&show_post_girls_buffer);
    show_post_girls.appendSliceAssumeCapacity(&.{3500001});

    post_girls.appendAssumeCapacity(.{ .id = 3500001 });

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
