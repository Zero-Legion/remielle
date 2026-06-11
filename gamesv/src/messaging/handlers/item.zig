pub fn getWeaponData(
    input: handlers.Input(pb.GetWeaponDataCsReq),
    output: handlers.Output(pb.GetWeaponDataScRsp, .{}),
) !void {
    _ = input;
    output.respond(.init);
}

pub fn getEquipData(
    input: handlers.Input(pb.GetEquipDataCsReq),
    output: handlers.Output(pb.GetEquipDataScRsp, .{}),
) !void {
    _ = input;
    output.respond(.init);
}

pub fn getItemData(
    input: handlers.Input(pb.GetItemDataCsReq),
    output: handlers.Output(pb.GetItemDataScRsp, .{}),
) !void {
    _ = input;

    var materials: std.ArrayList(pb.MaterialInfo) = try .initCapacity(
        output.arena,
        templates.avatar_skin_base.entries.len,
    );

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    output.respond(.{
        .material_list = materials,
    });
}

pub fn getWishlistData(
    input: handlers.Input(pb.GetWishlistDataCsReq),
    output: handlers.Output(pb.GetWishlistDataScRsp, .{}),
) !void {
    _ = input;
    output.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
