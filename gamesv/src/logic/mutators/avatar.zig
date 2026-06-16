pub fn mutateAvatar(
    input: Inputs(.{logic.Changes.Avatar}),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    for (input.changes.avatars) |change| {
        const index = avatar.indexes.get(change.id).?;

        avatar.metas[index] = change.meta;
        avatar.weapon_uids[index] = change.weapon_uid;
        avatar.equipment_uids[index] = change.equipment_uids;
    }
}

const Inputs = mutators.Inputs;

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
