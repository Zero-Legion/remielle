const log = std.log.scoped(.@"remielle-gamesv");

// TODO: a better name for this;
// a more or less sane structure will arise
// on its own when we'll start to track more state.
pub const ClientVariables = struct {
    packet_id_counters: []u32,
    xorpads: []messaging.Xorpad,

    pub fn initAlloc(uninit: *ClientVariables, arena: Allocator, slots: usize) Allocator.Error!void {
        uninit.packet_id_counters = try arena.alloc(u32, slots);
        uninit.xorpads = try arena.alloc(messaging.Xorpad, slots);
    }
};

pub fn bind(io: Io, gpa: Allocator, csprng: Random, bind_address: net.IpAddress) u8 {
    const socket = bind_address.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        switch (err) {
            error.AddressInUse => log.err(
                "the address {f} is already in use; another instance of this server might be already running",
                .{bind_address},
            ),
            else => |e| log.err("failed to bind at {f}: {t}", .{ bind_address, e }),
        }

        return 1;
    };

    defer socket.close(io);

    var server: kcp.Server = undefined;
    const slots: usize = 16;

    server.initAlloc(gpa, slots) catch {
        log.err("failed to allocate {d} kcp conversation slots", .{slots});
        return 1;
    };

    var conv_map: std.array_hash_map.Auto(kcp.ConvId, u32) = .empty;
    conv_map.ensureTotalCapacity(gpa, slots) catch {
        log.err("failed to allocate {d} conversation map slots", .{slots});
        return 1;
    };

    var cvars_arena: heap.ArenaAllocator = .init(gpa);
    defer cvars_arena.deinit();

    var cvars: ClientVariables = undefined;
    cvars.initAlloc(cvars_arena.allocator(), slots) catch {
        log.err("failed to allocate {d} client variable slots", .{slots});
        return 1;
    };

    const random_num = csprng.int(u64);
    var conv_counter: kcp.ConvId.Counter = .init;

    var per_message_arena: heap.ArenaAllocator = .init(gpa);
    defer per_message_arena.deinit();

    receive_loop: while (true) {
        var buffer: [kcp.mtu]u8 = undefined;
        const in_message = socket.receive(io, &buffer) catch |err| switch (err) {
            // Currently nothing will ever cancel it, but this will be a thing for graceful shutdown.
            error.Canceled => break :receive_loop,

            // The size of packet was greater than `mtu`,
            // this should not happen for well-behaved clients.
            error.MessageOversize => continue,

            else => |e| {
                log.err("UDP packet receive failed: {t}", .{e});
                continue;
            },
        };

        if (in_message.data.len == kcp.Control.size) {
            var out_buf: [kcp.Control.size]u8 = undefined;
            const ev = handleControlPacket(
                &conv_counter,
                random_num,
                &in_message.from,
                in_message.data[0..kcp.Control.size],
                &out_buf,
            );

            if (ev.ack) socket.send(io, &in_message.from, &out_buf) catch |err| switch (err) {
                error.Canceled => break :receive_loop,
                else => continue,
            };

            switch (ev.free_conv_id) {
                .none => {},
                _ => |conv_id| if (conv_map.fetchSwapRemove(conv_id)) |kv| {
                    // Release the resources associated with this `conv_id`.
                    const client = kv.value;

                    server.release(client);
                    log.debug("player from {f} disconnected", .{in_message.from});
                },
            }
        } else if (in_message.data.len >= kcp.Header.size) {
            const header = kcp.Header.decode(in_message.data[0..kcp.Header.size]) catch |err| switch (err) {
                error.InvalidCmd => continue,
            };

            if (header.conv_id == .none)
                continue; // ill-formed

            if (in_message.data.len < header.len + kcp.Header.size)
                continue; // ill-formed

            const token = header.token.upgrade(
                random_num,
                @bitCast(in_message.from.ip4.bytes),
                header.conv_id,
            ) orelse {
                // This may happen if server has been restarted, but the game
                // had an active session.

                var ctl: [kcp.Control.size]u8 = undefined;
                kcp.Control.encode(&ctl, .disconnect, header.conv_id, header.token, 404);
                socket.send(io, &in_message.from, &ctl) catch |err| switch (err) {
                    error.Canceled => break :receive_loop,
                    else => {},
                };

                continue;
            };

            if (conv_map.get(header.conv_id)) |client| {
                server.input(client, in_message.data) catch |err| {
                    log.err("input failed for conv {d}: {t}", .{ header.conv_id.toInt(), err });
                    continue;
                };

                const current_time: Io.Timestamp = .now(io, .real);

                while (true) {
                    var reader = server.reader(client) orelse break;
                    defer server.toss(client);
                    defer _ = per_message_arena.reset(.retain_capacity);

                    messaging.handlers.process(
                        per_message_arena.allocator(),
                        &server,
                        &cvars,
                        current_time,
                        &reader.interface,
                        client,
                    ) catch |err| {
                        log.err("failed to process message: {t}", .{err});
                        break;
                    };
                }

                drainOutgoingPackets(io, socket, current_time, &server, client, &in_message.from) catch |err| switch (err) {
                    error.Canceled => break :receive_loop,
                    else => {},
                };
            } else {
                const data = in_message.data[kcp.Header.size..][0..header.len];
                if (data.len < messaging.Header.size) continue; // ill-formed

                const msg_header = messaging.Header.decode(data[0..messaging.Header.size]) catch |err| switch (err) {
                    error.InvalidMagic => continue,
                };

                if (msg_header.head_len + msg_header.body_len > data.len - messaging.Header.size)
                    continue;

                if (msg_header.cmd_id != rmpb.main_desc.PlayerGetTokenCsReq.cmd_id) {
                    log.debug(
                        "received unexpected first cmd_id '{d}' from '{f}'",
                        .{ msg_header.cmd_id, in_message.from },
                    );
                    continue;
                }

                // For strings inside of PlayerGetTokenCsReq
                // ideally, we should introduce an option to protobuf decoder
                // for not copying strings which would be applicable in this case.
                var fb: [1024]u8 = undefined;
                var fba: heap.FixedBufferAllocator = .init(&fb);

                const body = msg_header.takeBody(data);
                messaging.Xorpad.initial.xor(.beginning, body);

                var br: Io.Reader = .fixed(body);
                const request = rmpb.decode(.main, rmpb.main.PlayerGetTokenCsReq, fba.allocator(), &br) catch {
                    log.debug("received malformed PlayerGetTokenCsReq from '{f}'", .{in_message.from});
                    continue;
                };

                const client_rand_key = decryptClientRandKey(request.client_rand_key) orelse {
                    log.debug("failed to decrypt client_rand_key from '{f}'", .{in_message.from});
                    continue;
                };

                const server_rand_key = csprng.int(u64);
                var encrypted_rand_key: [block_size_base64]u8 = undefined;
                var sign: [block_size_base64]u8 = undefined;

                encryptAndSignServerRandKey(server_rand_key, &encrypted_rand_key, &sign);

                const uid: u32 = 666; // TODO
                const rsp: rmpb.main.PlayerGetTokenScRsp = .{
                    .uid = uid,
                    .server_rand_key = &encrypted_rand_key,
                    .sign = &sign,
                };

                const client = switch (server.create(header.conv_id, token, .now(io, .real)) catch continue) {
                    .none => continue, // TODO: evict a client
                    _ => |index| index.toInt(),
                };

                server.input(client, in_message.data) catch |err| {
                    log.err("server.input failed: {t}", .{err});
                    server.release(client);
                    continue;
                };

                _ = server.reader(client) orelse {
                    log.err("server.reader returned null for first packet", .{});
                    server.release(client);
                    continue;
                };

                server.toss(client);

                const length = messaging.encodingLength(.init, rsp);
                const writer_head = server.allocPushSegments(client, length) catch {
                    log.err("message oversize for PlayerGetTokenScRsp", .{});
                    server.release(client);
                    continue;
                };

                var writer: kcp.Server.SegWriter = .init(
                    &server.conversations.rings[client].send,
                    writer_head,
                );

                const cmd_id = comptime rmpb.Descriptors.main.message(rmpb.main.PlayerGetTokenScRsp).?.descriptor.cmd_id;
                messaging.encode(&writer.interface, .initial, cmd_id, .init, rsp) catch unreachable;

                drainOutgoingPackets(io, socket, .now(io, .real), &server, client, &in_message.from) catch |err| switch (err) {
                    error.Canceled => break :receive_loop,
                    else => {},
                };

                conv_map.putAssumeCapacity(header.conv_id, client);

                cvars.packet_id_counters[client] = 1;
                cvars.xorpads[client].fillSeeded(.init(client_rand_key, server_rand_key));

                log.debug("player from {f} has logged in into account with uid {d}", .{ in_message.from, uid });
            }
        }
    }

    return 0;
}

fn drainOutgoingPackets(
    io: Io,
    socket: net.Socket,
    current_time: Io.Timestamp,
    server: *kcp.Server,
    client: u32,
    destination: *const net.IpAddress,
) !void {
    server.update(client, current_time);

    const send_ring = &server.conversations.rings[client].send;
    const ring_head = send_ring.head;
    defer send_ring.head = ring_head;

    var output: [kcp.mtu]u8 = undefined;
    while (true) {
        const n_send = server.drain(client, &output);
        if (n_send == 0) break;

        try socket.send(io, destination, output[0..n_send]);
    }
}

const block_size_base64 = std.base64.standard.Encoder.calcSize(rmcrypt.rsa.block_size);

fn decryptClientRandKey(b64: []const u8) ?u64 {
    if (b64.len != block_size_base64)
        return null;

    var ciphertext: [rmcrypt.rsa.block_size]u8 = undefined;

    std.base64.standard.Decoder.decode(&ciphertext, b64) catch
        return null;

    var plaintext_buf: [rmcrypt.rsa.block_size]u8 = undefined;
    const plaintext = rmcrypt.rsa.server_private_key.decrypt(&ciphertext, &plaintext_buf) orelse
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
    var ciphertext: [rmcrypt.rsa.block_size]u8 = undefined;
    var sign: [rmcrypt.rsa.block_size]u8 = undefined;

    rmcrypt.rsa.client_public_key.encrypt(std.mem.asBytes(&server_rand_key), &ciphertext);
    rmcrypt.rsa.server_private_key.sign(std.mem.asBytes(&server_rand_key), &sign);

    _ = std.base64.standard.Encoder.encode(out_ciphertext, &ciphertext);
    _ = std.base64.standard.Encoder.encode(out_sign, &sign);
}

const ControlEvent = struct {
    /// `out_ctl` has been populated and must be sent.
    ack: bool = false,

    /// The resources associated with this conversation id can be freed.
    free_conv_id: kcp.ConvId = .none,
};

fn handleControlPacket(
    conv_counter: *kcp.ConvId.Counter,
    random: u64,
    from: *const net.IpAddress,
    in_ctl: *const [kcp.Control.size]u8,
    out_ctl: *[kcp.Control.size]u8,
) ControlEvent {
    const control: kcp.Control = .{ .buffer = in_ctl };

    switch (control.kind()) {
        .connect => {
            const conv_id = conv_counter.next();
            const token: kcp.Token = .init(&.{
                .random = random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
            });

            kcp.Control.encode(out_ctl, .send_back_conv, conv_id, token.downgrade(), 0);
            return .{ .ack = true };
        },
        .disconnect => {
            const conv_id = control.conv();
            const token: kcp.Token = .init(&.{
                .random = random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
            });

            if (control.isToken(token)) {
                kcp.Control.encode(out_ctl, .disconnect, conv_id, token.downgrade(), 0);
                return .{ .ack = true, .free_conv_id = conv_id };
            } else {
                return .{};
            }
        },
        .send_back_conv, _ => return .{}, // Clients should not send this
    }
}

const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const net = std.Io.net;
const heap = std.heap;

const kcp = @import("kcp.zig");
const messaging = @import("messaging.zig");

const rmcrypt = @import("rmcrypt");
const rmpb = @import("rmpb");
const std = @import("std");
