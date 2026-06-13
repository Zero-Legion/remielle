pub fn playerSync(
    control_avatar: notifiers.Input(logic.Changes.ControlAvatar),
    control_guise_avatar: notifiers.Input(logic.Changes.ControlGuiseAvatar),
    avatar: notifiers.Input(logic.Changes.Avatar),
    output: notifiers.Output(pb.PlayerSyncScNotify),
) !void {
    var notify: pb.PlayerSyncScNotify = .init;

    notify.self_basic_info = try buildSelfBasicInfo(
        output.arena,
        &control_avatar.frame.cvars.properties.basic_info[control_avatar.frame.target_index],
        control_avatar.changes,
        control_guise_avatar.changes,
    );

    notify.avatar = try buildAvatarSync(output.arena, avatar.changes);

    notify.misc = .{
        .player_accessory = try buildPlayerAccessory(output.arena, control_guise_avatar.changes),
    };

    output.one(notify);
}

fn buildSelfBasicInfo(
    arena: Allocator,
    property: *const Properties.BasicInfo,
    control_avatar: []const logic.Changes.ControlAvatar,
    control_guise_avatar: []const logic.Changes.ControlGuiseAvatar,
) !?pb.SelfBasicInfo {
    _ = arena;

    if (control_avatar.len == 0 and control_guise_avatar.len == 0)
        return null;

    return .{
        .level = property.level.toInt(),
        .nick_name = "xeondev", // TODO
        .name_change_times = 1, // TODO
        .avatar_id = property.avatar.toInt(),
        .control_avatar_id = property.control_avatar.toInt(),
        .control_guise_avatar_id = property.control_guise_avatar.toInt(),
    };
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
    control_guise_avatar: []const logic.Changes.ControlGuiseAvatar,
) !?pb.PlayerAccessorySync {
    _ = arena;

    if (control_guise_avatar.len == 0)
        return null;

    return .{ .control_guise_avatar_id = control_guise_avatar[0].toInt() };
}

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
