pub fn getServerTimestamp(
    input: handlers.Input(pb.GetServerTimestampCsReq),
    output: handlers.Output(pb.GetServerTimestampScRsp, .{}),
) !void {
    output.respond(.{
        .timestamp = @intCast(posix.timespecToMs(input.time)),
    });
}

pub fn getMiscData(
    input: handlers.Input(pb.GetMiscDataCsReq),
    output: handlers.Output(pb.GetMiscDataScRsp, .{}),
) !void {
    _ = input;

    var unlocked_list: std.ArrayList(i32) = try .initCapacity(
        output.arena,
        templates.unlock_config.entries.len,
    );

    var post_girls: std.ArrayList(pb.PostGirlItem) = try .initCapacity(
        output.arena,
        templates.post_girl_config.entries.len,
    );

    for (templates.unlock_config.entries) |config|
        unlocked_list.appendAssumeCapacity(@intCast(config.id));

    for (templates.post_girl_config.entries) |config|
        post_girls.appendAssumeCapacity(.{ .id = config.id });

    var show_post_girls: std.ArrayList(u32) = try .initCapacity(output.arena, 1);
    show_post_girls.appendAssumeCapacity(
        @intFromEnum(templates.post_girl_config.Id.Avatar_Female_Size03_Promeia),
    );

    output.respond(.{ .data = .{
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
