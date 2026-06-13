pub fn mutateAvatar(
    input: mutators.Input(logic.Changes.Avatar),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    for (input.changes) |change| {
        const index = avatar.indexes.get(change.id).?;

        avatar.metas[index] = .{
            .level = change.level,
            .exp = change.exp,
            .rank = change.rank,
            .talents = change.talents,
            .talent_switch = change.talent_switch,
            .flags = change.flags,
            .skill_levels = change.skill_levels,
        };

        avatar.weapon_uids[index] = change.weapon_uid;
        avatar.equipment_uids[index] = change.equipment_uids;
    }
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
