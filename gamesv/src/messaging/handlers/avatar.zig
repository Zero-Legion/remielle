pub fn getAvatarData(
    input: handlers.Input(pb.GetAvatarDataCsReq),
    output: handlers.Output(pb.GetAvatarDataScRsp),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    const metas = avatar.meta();
    const weapon_uids = avatar.weaponUids();
    const equipment_uids = avatar.equipmentUids();

    var infos: std.ArrayList(pb.AvatarInfo) = try .initCapacity(output.arena, metas.len);

    const talent_switch_buf = try output.arena.alloc(
        bool,
        Properties.Avatar.TalentSwitch.count * metas.len,
    );

    const dressed_equip_buf = try output.arena.alloc(
        pb.DressedEquip,
        Properties.Avatar.equipment_slots * equipment_uids.len,
    );

    // TODO
    const skill_types = comptime std.enums.values(SkillType);
    var avatar_skills: std.ArrayList(pb.AvatarSkillLevel) = try .initCapacity(output.arena, skill_types.len);

    for (skill_types) |skill_type| avatar_skills.appendAssumeCapacity(.{
        .skill_type = @intFromEnum(skill_type),
        .level = switch (skill_type) {
            .core_skill => 7,
            else => 12,
        },
    });

    for (metas, weapon_uids, equipment_uids, 0..) |meta, weapon_uid, equipment, index| {
        const info = infos.addOneAssumeCapacity();
        const talent_switch = talent_switch_buf[Properties.Avatar.TalentSwitch.count * index ..][0..Properties.Avatar.TalentSwitch.count];

        talent_switch.* = meta.talent_switch.toBools();

        info.* = .{
            .id = @intFromEnum(avatar.ids[index]),
            .level = meta.level.toInt(),
            .rank = meta.rank.toInt(),
            .unlocked_talent_num = meta.talents.toInt(),
            .talent_switch_list = .fromOwnedSlice(talent_switch),
            .skill_type_level = avatar_skills, // TODO
            .cur_weapon_uid = weapon_uid.unwrap() orelse 0,
            .dressed_equip_list = .initBuffer(
                dressed_equip_buf[Properties.Avatar.equipment_slots * index ..][0..Properties.Avatar.equipment_slots],
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

const SkillType = enum(u32) {
    common_attack = 0,
    special_attack = 1,
    evade = 2,
    cooperate_skill = 3,
    unique_skill = 4,
    core_skill = 5,
    assist_skill = 6,
};

const ArrayList = std.ArrayList;
const templates = Assets.templates;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
