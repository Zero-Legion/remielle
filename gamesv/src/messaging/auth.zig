pub const PlayerToken = struct {
    response: PlayerGetTokenScRsp,
    key: Xorpad.Key,
    uid: u32,
};

pub const PlayerGetTokenError = error{
    RandKeyDecryptFail,
};

pub const string_buffer_size = block_size_base64 * 2;

pub fn playerGetToken(
    csprng: Random,
    request: *const PlayerGetTokenCsReq,
    string_buffer: *[string_buffer_size]u8,
) PlayerGetTokenError!PlayerToken {
    const client_rand_key = decryptClientRandKey(request.client_rand_key) orelse
        return error.RandKeyDecryptFail;

    const server_rand_key = csprng.int(u64);
    const encrypted_rand_key = string_buffer[0..block_size_base64];
    const sign = string_buffer[block_size_base64..];

    encryptAndSignServerRandKey(server_rand_key, encrypted_rand_key, sign);

    const uid: u32 = 666; // TODO
    const response: nrmpb.main.PlayerGetTokenScRsp = .{
        .uid = uid,
        .server_rand_key = encrypted_rand_key,
        .sign = sign,
    };

    return .{
        .response = response,
        .key = .init(client_rand_key, server_rand_key),
        .uid = uid,
    };
}

fn decryptClientRandKey(b64: []const u8) ?u64 {
    if (b64.len != block_size_base64)
        return null;

    var ciphertext: [nrmcrypt.rsa.block_size]u8 = undefined;

    base64.Decoder.decode(&ciphertext, b64) catch
        return null;

    var plaintext_buf: [nrmcrypt.rsa.block_size]u8 = undefined;
    const plaintext = nrmcrypt.rsa.server_private_key.decrypt(&ciphertext, &plaintext_buf) orelse
        return null;

    if (plaintext.len != @sizeOf(u64))
        return null;

    return std.mem.readInt(u64, plaintext[0..@sizeOf(u64)], .little);
}

fn encryptAndSignServerRandKey(
    server_rand_key: u64,
    out_ciphertext: *[block_size_base64]u8,
    out_sign: *[block_size_base64]u8,
) void {
    var ciphertext: [nrmcrypt.rsa.block_size]u8 = undefined;
    var sign: [nrmcrypt.rsa.block_size]u8 = undefined;

    nrmcrypt.rsa.client_public_key.encrypt(std.mem.asBytes(&server_rand_key), &ciphertext);
    nrmcrypt.rsa.server_private_key.sign(std.mem.asBytes(&server_rand_key), &sign);

    _ = base64.Encoder.encode(out_ciphertext, &ciphertext);
    _ = base64.Encoder.encode(out_sign, &sign);
}

const block_size_base64 = base64.Encoder.calcSize(nrmcrypt.rsa.block_size);

const Random = std.Random;
const PlayerGetTokenCsReq = nrmpb.main.PlayerGetTokenCsReq;
const PlayerGetTokenScRsp = nrmpb.main.PlayerGetTokenScRsp;

const base64 = std.base64.standard;

const Xorpad = @import("Xorpad.zig");

const nrmcrypt = @import("nrmcrypt");
const nrmpb = @import("nrmpb");
const std = @import("std");
