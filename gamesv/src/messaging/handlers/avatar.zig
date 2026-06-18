pub fn getAvatarData(
    message: Message(pb.GetAvatarDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    response: Response(pb.GetAvatarDataScRsp),
) !void {
    _ = message;

    const count = properties.avatar.count();

    const metas = properties.avatar.meta[0..count];
    const weapon_uids = properties.avatar.weapon_uids[0..count];
    const equipment_uids = properties.avatar.equipment_uids[0..count];

    var infos: ArrayList(pb.AvatarInfo) = try .initCapacity(response.allocator, metas.len);

    for (metas, weapon_uids, equipment_uids, 0..) |*meta, weapon_uid, equipment, index|
        infos.appendAssumeCapacity(try packers.packAvatarInfo(
            response.allocator,
            properties.avatar.ids[index],
            meta,
            weapon_uid,
            equipment,
        ));

    response.set(.{ .avatar_list = infos });
}

pub fn avatarFavorite(
    message: Message(pb.AvatarFavoriteCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarFavoriteScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.flags.favorite != message.data.is_favorite) {
        meta.flags.favorite = message.data.is_favorite;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
        };

        changes.insert(avatars);
    }

    response.set(.init);
}

pub fn avatarSkinDress(
    message: Message(pb.AvatarSkinDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarSkinDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.skin.toInt() != message.data.avatar_skin_id) {
        // TODO: check if it belongs to this avatar and if it's unlocked.

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
        };

        changes.insert(avatars);
    }

    response.set(.init);
}

pub fn avatarSkinUnDress(
    message: Message(pb.AvatarSkinUnDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarSkinUnDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.skin != .none) {
        meta.skin = .none;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
        };

        changes.insert(avatars);
    }

    response.set(.init);
}

const Avatar = Properties.Avatar;
const ArrayList = std.ArrayList;
const templates = Assets.templates;

const Changes = logic.Changes;
const Properties = logic.Properties;

const Message = handlers.Message;
const Response = handlers.Response;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
