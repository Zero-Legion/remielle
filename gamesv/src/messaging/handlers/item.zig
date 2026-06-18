pub fn getWeaponData(
    message: Message(pb.GetWeaponDataCsReq),
    response: Response(pb.GetWeaponDataScRsp),
) !void {
    _ = message;
    response.set(.init);
}

pub fn getEquipData(
    message: Message(pb.GetEquipDataCsReq),
    response: Response(pb.GetEquipDataScRsp),
) !void {
    _ = message;
    response.set(.init);
}

pub fn getItemData(
    message: Message(pb.GetItemDataCsReq),
    response: Response(pb.GetItemDataScRsp),
) !void {
    _ = message;

    var materials: std.ArrayList(pb.MaterialInfo) = try .initCapacity(
        response.allocator,
        templates.avatar_skin_base.entries.len,
    );

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    response.set(.{
        .material_list = materials,
    });
}

pub fn getWishlistData(
    message: Message(pb.GetWishlistDataCsReq),
    response: Response(pb.GetWishlistDataScRsp),
) !void {
    _ = message;
    response.set(.init);
}

const templates = Assets.templates;

const Message = handlers.Message;
const Response = handlers.Response;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
