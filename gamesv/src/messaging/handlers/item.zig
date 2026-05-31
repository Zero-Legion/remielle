pub fn getWeaponData(request: handlers.Request(.GetWeaponDataCsReq)) !void {
    try request.respond(.GetWeaponDataScRsp, .init);
}

pub fn getEquipData(request: handlers.Request(.GetEquipDataCsReq)) !void {
    try request.respond(.GetEquipDataScRsp, .init);
}

pub fn getItemData(request: handlers.Request(.GetItemDataCsReq)) !void {
    try request.respond(.GetItemDataScRsp, .init);
}

pub fn getWishlistData(request: handlers.Request(.GetWishlistDataCsReq)) !void {
    try request.respond(.GetWishlistDataScRsp, .init);
}

const handlers = @import("../handlers.zig");
