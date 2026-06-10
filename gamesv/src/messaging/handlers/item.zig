pub fn getWeaponData(txn: handlers.Transaction(.GetWeaponDataCsReq)) !void {
    try txn.respond(.init);
}

pub fn getEquipData(txn: handlers.Transaction(.GetEquipDataCsReq)) !void {
    try txn.respond(.init);
}

pub fn getItemData(txn: handlers.Transaction(.GetItemDataCsReq)) !void {
    var materials_buf: [templates.avatar_skin_base.entries.len]pb.MaterialInfo = undefined;
    var materials: std.ArrayList(pb.MaterialInfo) = .initBuffer(&materials_buf);

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    try txn.respond(.{
        .material_list = materials,
    });
}

pub fn getWishlistData(txn: handlers.Transaction(.GetWishlistDataCsReq)) !void {
    try txn.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
