pub fn getWeaponData(txn: *handlers.Transaction(.GetWeaponDataCsReq, .{})) !void {
    txn.respond(.init);
}

pub fn getEquipData(txn: *handlers.Transaction(.GetEquipDataCsReq, .{})) !void {
    txn.respond(.init);
}

pub fn getItemData(txn: *handlers.Transaction(.GetItemDataCsReq, .{})) !void {
    var materials: std.ArrayList(pb.MaterialInfo) = try .initCapacity(
        txn.arena,
        templates.avatar_skin_base.entries.len,
    );

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    txn.respond(.{
        .material_list = materials,
    });
}

pub fn getWishlistData(txn: *handlers.Transaction(.GetWishlistDataCsReq, .{})) !void {
    txn.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
