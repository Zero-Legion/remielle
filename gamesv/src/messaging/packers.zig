pub fn packAvatarInfo(
    arena: Allocator,
    id: Avatar.Id,
    meta: *const Avatar.Meta,
    weapon_uid: Avatar.OptionalUID,
    equipment_uids: [Avatar.equipment_slots]Avatar.OptionalUID,
) !pb.AvatarInfo {
    var avatar_skills: [Avatar.Skill.count]pb.AvatarSkillLevel = undefined;

    for (&avatar_skills, meta.skill_levels, 0..) |*avatar_skill, level, skill_type|
        avatar_skill.* = .{ .skill_type = @intCast(skill_type), .level = level.toInt() };

    var dressed_equip_list: ArrayList(pb.DressedEquip) = try .initCapacity(arena, Avatar.equipment_slots);

    for (equipment_uids, 1..) |maybe_uid, slot| if (maybe_uid.unwrap()) |uid|
        dressed_equip_list.appendAssumeCapacity(.{
            .index = @intCast(slot),
            .equip_uid = uid,
        });

    return .{
        .id = @intFromEnum(id),
        .level = meta.level.toInt(),
        .rank = meta.rank.toInt(),
        .unlocked_talent_num = meta.talents.toInt(),
        .talent_switch_list = .fromOwnedSlice(try arena.dupe(bool, &meta.talent_switch.toBools())),
        .skill_type_level = .fromOwnedSlice(try arena.dupe(pb.AvatarSkillLevel, &avatar_skills)),
        .passive_skill_level = meta.skill_levels[Avatar.Skill.core_skill.toInt()].toInt() - 1,
        .cur_weapon_uid = weapon_uid.unwrap() orelse 0,
        .dressed_equip_list = dressed_equip_list,
        .is_favorite = meta.flags.favorite,
        .avatar_skin_id = meta.skin.toInt(),
    };
}

const ArrayList = std.ArrayList;
const Avatar = Properties.Avatar;
const Properties = logic.Properties;
const Allocator = std.mem.Allocator;

const logic = @import("../logic.zig");

const pb = @import("rmpb").main;
const std = @import("std");
