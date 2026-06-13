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

    const talent_switch_buf = try arena.alloc(
        bool,
        Avatar.TalentSwitch.count * changes.len,
    );

    const dressed_equip_buf = try arena.alloc(
        pb.DressedEquip,
        Avatar.equipment_slots * changes.len,
    );

    const avatar_skills_buf = try arena.alloc(
        pb.AvatarSkillLevel,
        Avatar.Skill.count * changes.len,
    );

    for (changes, 0..) |change, index| {
        const info = sync.avatar_list.addOneAssumeCapacity();

        const talent_switch = talent_switch_buf[Avatar.TalentSwitch.count * index ..][0..Avatar.TalentSwitch.count];
        talent_switch.* = change.meta.talent_switch.toBools();

        const avatar_skills = avatar_skills_buf[Avatar.Skill.count * index ..][0..Avatar.Skill.count];
        for (avatar_skills, change.meta.skill_levels, 0..) |*avatar_skill, level, skill_type|
            avatar_skill.* = .{ .skill_type = @intCast(skill_type), .level = level.toInt() };

        info.* = .{
            .id = @intFromEnum(change.id),
            .level = change.meta.level.toInt(),
            .rank = change.meta.rank.toInt(),
            .unlocked_talent_num = change.meta.talents.toInt(),
            .talent_switch_list = .fromOwnedSlice(talent_switch),
            .skill_type_level = .fromOwnedSlice(avatar_skills),
            .passive_skill_level = change.meta.skill_levels[Avatar.Skill.core_skill.toInt()].toInt() - 1,
            .cur_weapon_uid = change.weapon_uid.unwrap() orelse 0,
            .dressed_equip_list = .initBuffer(
                dressed_equip_buf[Avatar.equipment_slots * index ..][0..Avatar.equipment_slots],
            ),
            .is_favorite = change.meta.flags.favorite,
        };

        for (change.equipment_uids, 1..) |maybe_uid, slot| if (maybe_uid.unwrap()) |uid| {
            info.dressed_equip_list.appendAssumeCapacity(.{
                .index = @intCast(slot),
                .equip_uid = uid,
            });
        };
    }

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
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
