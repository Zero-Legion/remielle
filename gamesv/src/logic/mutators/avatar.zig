pub fn mutateAvatar(
    changes: logic.Changes.Subset(.{
        logic.Changes.Avatar,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Avatar,
    }),
) !void {
    for (changes.avatars) |change| {
        const index = properties.avatar.indexes.get(change.id).?;

        properties.avatar.metas[index] = change.meta;
        properties.avatar.weapon_uids[index] = change.weapon_uid;
        properties.avatar.equipment_uids[index] = change.equipment_uids;
    }
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
