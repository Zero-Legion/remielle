const account_uid_map_path = "Persistent/LocalStorage/GENERAL_DATA.bin";

const AccountUidMap = std.array_hash_map.Auto(AccountUid, void);
const base_player_uid = @import("config").base_player_uid;

root: Io.Dir,
account_uid_map: AccountUidMap,

pub fn init(io: Io, gpa: Allocator, root: Io.Dir) !Persistent {
    try ensureDirectories(io, root);

    return .{
        .root = root,
        .account_uid_map = try loadAccountUidMap(io, gpa, root),
    };
}

pub fn deinit(persistent: *Persistent, gpa: Allocator) void {
    persistent.account_uid_map.deinit(gpa);
}

pub const AccountUid = enum(u64) {
    _,

    pub const Error = error{InvalidUidString};

    pub fn fromString(account_uid: []const u8) Error!AccountUid {
        return @enumFromInt(std.fmt.parseInt(u64, account_uid, 10) catch
            return error.InvalidUidString);
    }
};

pub fn getPlayerUidByAccountUid(persistent: *Persistent, uid: AccountUid) ?u32 {
    return if (persistent.account_uid_map.getIndex(uid)) |index|
        @intCast(base_player_uid + index)
    else
        null;
}

/// It's caller's responsibility to check if it doesn't already exist.
/// After this, `saveAccountUidMap` should be called as well.
pub fn createPlayerUidForAccountUid(persistent: *Persistent, gpa: Allocator, uid: AccountUid) !u32 {
    try persistent.account_uid_map.put(gpa, uid, {});
    return @intCast(base_player_uid + (persistent.account_uid_map.count() - 1));
}

fn loadAccountUidMap(io: Io, gpa: Allocator, root: Io.Dir) !AccountUidMap {
    const bytes = root.readFileAllocOptions(io, account_uid_map_path, gpa, .unlimited, .of(u64), null) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => |e| return e,
    };

    defer gpa.free(bytes);

    var map: AccountUidMap = .empty;
    try map.reinit(gpa, @ptrCast(bytes), &.{});

    return map;
}

pub fn saveAccountUidMap(persistent: *const Persistent, io: Io) !void {
    try persistent.root.writeFile(io, .{
        .sub_path = account_uid_map_path,
        .data = @ptrCast(persistent.account_uid_map.keys()),
    });
}

pub fn loadPlayer(
    persistent: *const Persistent,
    io: Io,
    arena: Allocator,
    player_uid: u32,
) !PlayerSave {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "Persistent/LocalStorage/USD_{d}.bin", .{player_uid}) catch
        unreachable;

    const file = try persistent.root.openFile(io, path, .{});
    defer file.close(io);

    var reader_buf: [1024]u8 = undefined;
    var fr = file.reader(io, &reader_buf);

    return try rmpb.decode(.stable, PlayerSave, arena, &fr.interface);
}

pub fn savePlayer(
    persistent: *const Persistent,
    io: Io,
    player_uid: u32,
    save: PlayerSave,
) !void {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "Persistent/LocalStorage/USD_{d}.bin", .{player_uid}) catch
        unreachable;

    const file = try persistent.root.createFile(io, path, .{});
    defer file.close(io);

    var writer_buf: [1024]u8 = undefined;
    var fw = file.writer(io, &writer_buf);

    try rmpb.encode(.stable, &fw.interface, save);
    try fw.interface.flush();
}

fn ensureDirectories(io: Io, root: Io.Dir) !void {
    try root.createDirPath(io, "Persistent/LocalStorage/");
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const PlayerSave = rmpb.stable.PlayerSave;

const rmpb = @import("rmpb");
const std = @import("std");
const Persistent = @This();
