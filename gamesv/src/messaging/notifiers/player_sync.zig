pub fn playerSync(
    properties: logic.Properties.Immutable(.{
        logic.Properties.BasicInfo,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.ControlAvatar,
        logic.Changes.ControlGuiseAvatar,
        logic.Changes.Avatar,
    }),
    notify: Notify(pb.PlayerSyncScNotify),
) !void {
    var sync: pb.PlayerSyncScNotify = .init;

    sync.self_basic_info = try buildSelfBasicInfo(
        notify.allocator,
        properties.basic_info,
        changes.control_avatar,
        changes.control_guise_avatar,
    );

    sync.avatar = try buildAvatarSync(notify.allocator, changes.avatars);

    sync.misc = .{
        .player_accessory = try buildPlayerAccessory(notify.allocator, changes.control_guise_avatar),
    };

    notify.one(sync);
}

fn buildSelfBasicInfo(
    allocator: Allocator,
    info: *const Properties.BasicInfo,
    control_avatar: ?logic.Changes.ControlAvatar,
    control_guise_avatar: ?logic.Changes.ControlGuiseAvatar,
) !?pb.SelfBasicInfo {
    if (control_avatar == null and control_guise_avatar == null)
        return null;

    return try packers.packSelfBasicInfo(allocator, info);
}

fn buildAvatarSync(allocator: Allocator, changes: []const logic.Changes.Avatar) !?pb.AvatarSync {
    if (changes.len == 0) return null;

    var sync: pb.AvatarSync = .{
        .avatar_list = try .initCapacity(allocator, changes.len),
    };

    for (changes) |change| sync.avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
        allocator,
        change.id,
        &change.meta,
        change.weapon_uid,
        change.equipment_uids,
    ));

    return sync;
}

fn buildPlayerAccessory(
    allocator: Allocator,
    maybe_control_guise_avatar: ?logic.Changes.ControlGuiseAvatar,
) !?pb.PlayerAccessorySync {
    _ = allocator;

    const control_guise_avatar = maybe_control_guise_avatar orelse
        return null;

    return .{ .control_guise_avatar_id = control_guise_avatar.toInt() };
}

const Notify = notifiers.Notify;

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
