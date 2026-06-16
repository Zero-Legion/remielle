pub fn playerSync(
    inputs: Inputs(.{
        logic.Changes.ControlAvatar,
        logic.Changes.ControlGuiseAvatar,
        logic.Changes.Avatar,
    }),
    output: Output(pb.PlayerSyncScNotify),
) !void {
    var notify: pb.PlayerSyncScNotify = .init;

    notify.self_basic_info = try buildSelfBasicInfo(
        output.arena,
        &inputs.frame.cvars.properties.basic_info[inputs.frame.target_index],
        inputs.changes.control_avatar,
        inputs.changes.control_guise_avatar,
    );

    notify.avatar = try buildAvatarSync(output.arena, inputs.changes.avatars);

    notify.misc = .{
        .player_accessory = try buildPlayerAccessory(output.arena, inputs.changes.control_guise_avatar),
    };

    output.one(notify);
}

fn buildSelfBasicInfo(
    arena: Allocator,
    info: *const Properties.BasicInfo,
    control_avatar: ?logic.Changes.ControlAvatar,
    control_guise_avatar: ?logic.Changes.ControlGuiseAvatar,
) !?pb.SelfBasicInfo {
    if (control_avatar == null and control_guise_avatar == null)
        return null;

    return try packers.packSelfBasicInfo(arena, info);
}

fn buildAvatarSync(arena: Allocator, changes: []const logic.Changes.Avatar) !?pb.AvatarSync {
    if (changes.len == 0) return null;

    var sync: pb.AvatarSync = .{
        .avatar_list = try .initCapacity(arena, changes.len),
    };

    for (changes) |change| sync.avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
        arena,
        change.id,
        &change.meta,
        change.weapon_uid,
        change.equipment_uids,
    ));

    return sync;
}

fn buildPlayerAccessory(
    arena: Allocator,
    maybe_control_guise_avatar: ?logic.Changes.ControlGuiseAvatar,
) !?pb.PlayerAccessorySync {
    _ = arena;

    const control_guise_avatar = maybe_control_guise_avatar orelse
        return null;

    return .{ .control_guise_avatar_id = control_guise_avatar.toInt() };
}

const Inputs = notifiers.Inputs;
const Output = notifiers.Output;

const Avatar = Properties.Avatar;
const Allocator = std.mem.Allocator;
const Properties = logic.Properties;

const templates = Assets.templates;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
