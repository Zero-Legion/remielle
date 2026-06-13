pub fn getAvatarData(
    input: handlers.Input(pb.GetAvatarDataCsReq),
    output: handlers.Output(pb.GetAvatarDataScRsp),
) !void {
    const avatar = &input.frame.cvars.properties.avatar[input.frame.target_index];

    const metas = avatar.meta();
    const weapon_uids = avatar.weaponUids();
    const equipment_uids = avatar.equipmentUids();

    var infos: ArrayList(pb.AvatarInfo) = try .initCapacity(output.arena, metas.len);

    for (metas, weapon_uids, equipment_uids, 0..) |*meta, weapon_uid, equipment, index|
        infos.appendAssumeCapacity(try packers.packAvatarInfo(
            output.arena,
            avatar.ids[index],
            meta,
            weapon_uid,
            equipment,
        ));

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

pub fn avatarSkinDress(
    input: handlers.Input(pb.AvatarSkinDressCsReq),
    output: handlers.Output(pb.AvatarSkinDressScRsp),
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

    if (meta.skin.toInt() != input.message.avatar_skin_id) {
        // TODO: check if it belongs to this avatar and if it's unlocked.

        meta.skin = @enumFromInt(input.message.avatar_skin_id);

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

pub fn avatarSkinUnDress(
    input: handlers.Input(pb.AvatarSkinUnDressCsReq),
    output: handlers.Output(pb.AvatarSkinUnDressScRsp),
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

    if (meta.skin != .none) {
        meta.skin = .none;

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
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
