pub fn getAvatarData(
    input: handlers.Input(pb.GetAvatarDataCsReq),
    output: handlers.Output(pb.GetAvatarDataScRsp),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    const metas = avatar.meta();
    const weapon_uids = avatar.weaponUids();
    const equipment_uids = avatar.equipmentUids();

    var infos: ArrayList(pb.AvatarInfo) = try .initCapacity(output.arena, metas.len);

    const talent_switch_buf = try output.arena.alloc(
        bool,
        Avatar.TalentSwitch.count * metas.len,
    );

    const dressed_equip_buf = try output.arena.alloc(
        pb.DressedEquip,
        Avatar.equipment_slots * equipment_uids.len,
    );

    const avatar_skills_buf = try output.arena.alloc(
        pb.AvatarSkillLevel,
        Avatar.Skill.count * metas.len,
    );

    for (metas, weapon_uids, equipment_uids, 0..) |meta, weapon_uid, equipment, index| {
        const info = infos.addOneAssumeCapacity();
        const talent_switch = talent_switch_buf[Avatar.TalentSwitch.count * index ..][0..Avatar.TalentSwitch.count];
        talent_switch.* = meta.talent_switch.toBools();

        const avatar_skills = avatar_skills_buf[Avatar.Skill.count * index ..][0..Avatar.Skill.count];
        for (avatar_skills, meta.skill_levels, 0..) |*avatar_skill, level, skill_type|
            avatar_skill.* = .{ .skill_type = @intCast(skill_type), .level = level.toInt() };

        info.* = .{
            .id = @intFromEnum(avatar.ids[index]),
            .level = meta.level.toInt(),
            .rank = meta.rank.toInt(),
            .unlocked_talent_num = meta.talents.toInt(),
            .talent_switch_list = .fromOwnedSlice(talent_switch),
            .skill_type_level = .fromOwnedSlice(avatar_skills),
            .passive_skill_level = meta.skill_levels[Avatar.Skill.core_skill.toInt()].toInt() - 1,
            .cur_weapon_uid = weapon_uid.unwrap() orelse 0,
            .dressed_equip_list = .initBuffer(
                dressed_equip_buf[Avatar.equipment_slots * index ..][0..Avatar.equipment_slots],
            ),
            .is_favorite = meta.flags.favorite,
        };

        for (equipment, 1..) |maybe_uid, slot| if (maybe_uid.unwrap()) |uid| {
            info.dressed_equip_list.appendAssumeCapacity(.{
                .index = @intCast(slot),
                .equip_uid = uid,
            });
        };
    }

    output.respond(.{ .avatar_list = infos });
}

pub fn avatarFavorite(
    input: handlers.Input(pb.AvatarFavoriteCsReq),
    output: handlers.Output(pb.AvatarFavoriteScRsp),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, input.message.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return output.bail(.{ .retcode = 1 });

    var meta = avatar.metas[index];

    if (meta.flags.favorite != input.message.is_favorite) {
        meta.flags.favorite = input.message.is_favorite;

        const changes = try output.arena.alloc(logic.Changes.Avatar, 1);

        changes[0] = .{
            .id = avatar.ids[index],
            .meta = meta,
            .weapon_uid = avatar.weapon_uids[index],
            .equipment_uids = avatar.equipment_uids[index],
        };

        output.changes.avatars = changes;
    }

    output.respond(.init);
}

const Avatar = Properties.Avatar;
const ArrayList = std.ArrayList;
const templates = Assets.templates;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
