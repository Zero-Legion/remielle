pub fn getAvatarData(txn: *handlers.Transaction(.GetAvatarDataCsReq, .{})) !void {
    var avatars: std.ArrayList(pb.AvatarInfo) = try .initCapacity(txn.arena, templates.avatar_base.entries.len);

    var talent_switch: std.ArrayList(bool) = try .initCapacity(txn.arena, 6);
    talent_switch.appendSliceAssumeCapacity(&(@as([3]bool, @splat(false)) ++ @as([3]bool, @splat(true))));

    const skill_types = comptime std.enums.values(SkillType);
    var avatar_skills: std.ArrayList(pb.AvatarSkillLevel) = try .initCapacity(txn.arena, skill_types.len);

    for (skill_types) |skill_type| avatar_skills.appendAssumeCapacity(.{
        .skill_type = @intFromEnum(skill_type),
        .level = switch (skill_type) {
            .core_skill => 7,
            else => 12,
        },
    });

    for (templates.avatar_base.entries) |entry| if (entry.camp != 0) {
        avatars.appendAssumeCapacity(.{
            .id = entry.id,
            .skill_type_level = avatar_skills,
            .is_favorite = entry.getId() == .velina,
            .talent_switch_list = talent_switch,
            .level = 60,
            .rank = 6,
            .unlocked_talent_num = 6,
        });
    };

    txn.respond(.{ .avatar_list = avatars });
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

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
