pub fn getWeaponData(txn: handlers.Transaction(.GetWeaponDataCsReq)) !void {
    try txn.respond(.init);
}

pub fn getEquipData(txn: handlers.Transaction(.GetEquipDataCsReq)) !void {
    try txn.respond(.init);
}

pub fn getItemData(txn: handlers.Transaction(.GetItemDataCsReq)) !void {
    try txn.respond(.init);
}

pub fn getWishlistData(txn: handlers.Transaction(.GetWishlistDataCsReq)) !void {
    try txn.respond(.init);
}

const handlers = @import("../handlers.zig");
