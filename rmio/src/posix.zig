pub const AF = enum(u32) {
    INET = sys.AF.INET,
    UNIX = sys.AF.UNIX,
};

pub const SOCK = enum(u32) {
    pub const Flags = enum(u32) {
        NONBLOCK = sys.SOCK.NONBLOCK,
        CLOEXEC = sys.SOCK.CLOEXEC,
        _,

        /// 'enabled' is a tuple of `Flag` fields
        pub fn flags(comptime enabled: anytype) Flags {
            var f: u32 = 0;
            inline for (enabled) |flag|
                f |= @intFromEnum(@as(Flags, flag));

            return @enumFromInt(f);
        }

        pub inline fn isActive(set: Flags, check: Flags) bool {
            return (@intFromEnum(set) & @intFromEnum(check)) != 0;
        }
    };

    STREAM = sys.SOCK.STREAM,
    DGRAM = sys.SOCK.DGRAM,
    _,

    pub inline fn with(sock: SOCK, flag: Flags) SOCK {
        return @enumFromInt(@intFromEnum(sock) | @intFromEnum(flag));
    }

    pub inline fn hasFlag(sock: SOCK, flag: Flags) bool {
        return (@intFromEnum(sock) & @intFromEnum(flag)) != 0;
    }

    pub inline fn init(sock: SOCK, flags: Flags) SOCK {
        return @enumFromInt(@intFromEnum(sock) | @intFromEnum(flags));
    }
};

pub const IPPROTO = enum(u32) {
    TCP = sys.IPPROTO.TCP,
    UDP = sys.IPPROTO.UDP,
};

pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
};

pub const socket_t = sys.fd_t;

pub fn socket(af: AF, sock: SOCK, ipproto: IPPROTO) SocketError!socket_t {
    const rc = sys.socket(@intFromEnum(af), @intFromEnum(sock), @intFromEnum(ipproto));
    return switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        else => |e| unexpectedErrno(e),
    };
}

pub const Sockaddr = union(enum) {
    pub const In = sys.sockaddr.in;

    in: In,

    pub const ParseIp4Error = error{
        InvalidAddress,
        InvalidPort,
    };

    pub fn parseIp4(string: []const u8) ParseIp4Error!Sockaddr {
        const port_sep_i = std.mem.findScalar(u8, string, ':') orelse
            return error.InvalidAddress;

        const port = std.fmt.parseInt(u16, string[port_sep_i + 1 ..], 10) catch
            return error.InvalidPort;

        var octets: [4]u8 = undefined;
        var octets_it = std.mem.splitScalar(u8, string[0..port_sep_i], '.');

        for (&octets) |*octet|
            octet.* = std.fmt.parseInt(u8, octets_it.next() orelse return error.InvalidAddress, 10) catch
                return error.InvalidAddress;

        if (octets_it.rest().len != 0) return error.InvalidAddress;

        return .{ .in = .{
            .addr = @bitCast(octets),
            .port = std.mem.nativeToBig(u16, port),
        } };
    }

    pub fn raw(sa: *const Sockaddr) *const sys.sockaddr {
        return switch (sa.*) {
            inline else => |*addr| @ptrCast(addr),
        };
    }

    pub fn rawMut(sa: *Sockaddr) *sys.sockaddr {
        return switch (sa.*) {
            inline else => |*addr| @ptrCast(addr),
        };
    }

    pub fn len(sa: *const Sockaddr) socklen_t {
        return switch (sa.*) {
            inline else => |addr| @sizeOf(@TypeOf(addr)),
        };
    }

    pub fn format(sa: *const Sockaddr, writer: *std.Io.Writer) !void {
        switch (sa.*) {
            .in => |addr| {
                const octets: [4]u8 = @bitCast(addr.addr);
                const port = std.mem.bigToNative(u16, addr.port);

                try writer.print(
                    "{d}.{d}.{d}.{d}:{d}",
                    .{ octets[0], octets[1], octets[2], octets[3], port },
                );
            },
        }
    }
};

pub const socklen_t = sys.socklen_t;

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressUnavailable,
    SystemResources,
};

pub fn bind(fd: socket_t, addr: *const Sockaddr) BindError!void {
    return switch (sys.errno(sys.bind(fd, addr.raw(), addr.len()))) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .NOMEM => error.SystemResources,
        else => |e| unexpectedErrno(e),
    };
}

pub const ListenError = error{
    AddressInUse,
};

pub fn listen(fd: socket_t, backlog: u31) ListenError!void {
    return switch (sys.errno(sys.listen(fd, backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        else => |e| unexpectedErrno(e),
    };
}

pub const SOL = enum(i32) {
    SOCKET = sys.SOL.SOCKET,
};

pub const SO = struct {
    pub const Name = enum(i32) {
        REUSEADDR = sys.SO.REUSEADDR,
    };

    pub const Val = struct {
        pub const REUSEADDR = i32;
    };
};

pub fn setsockopt(
    fd: socket_t,
    level: SOL,
    comptime optname: SO.Name,
    optval: @field(SO.Val, @tagName(optname)),
) void {
    switch (sys.errno(sys.setsockopt(
        fd,
        @intFromEnum(level),
        @intFromEnum(optname),
        @ptrCast(&optval),
        @sizeOf(@TypeOf(optval)),
    ))) {
        .SUCCESS => {},
        else => |e| unexpectedErrno(e),
    }
}

pub fn close(fd: socket_t) void {
    _ = sys.close(fd);
}

pub const pollfd = sys.pollfd;

pub const POLL = sys.POLL;

pub const PollError = error{
    Interrupted,
    SystemResources,
};

pub fn poll(pollfds: []pollfd, timeout: i32) PollError!usize {
    const rc = sys.poll(pollfds.ptr, pollfds.len, timeout);
    return switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .NOMEM => error.SystemResources,
        else => |e| unexpectedErrno(e),
    };
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    BlockedByFirewall,
    ProtocolError,
};

pub fn accept(fd: socket_t, addr: *Sockaddr, flags: SOCK.Flags) AcceptError!socket_t {
    var addrlen: socklen_t = addr.len();

    // TODO: use accept4(2) where applicable

    const accept_rc = sys.accept(fd, addr.rawMut(), &addrlen);
    const accepted_fd: socket_t = switch (sys.errno(accept_rc)) {
        .SUCCESS => @intCast(accept_rc),
        .AGAIN => return error.WouldBlock,
        .CONNABORTED => return error.ConnectionAborted,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .PERM => return error.BlockedByFirewall,
        .PROTO => return error.ProtocolError,
        else => |e| unexpectedErrno(e),
    };

    if (flags.isActive(.NONBLOCK)) {
        const getfl_rc = sys.fcntl(accepted_fd, sys.F.GETFL, 0);
        const existing_flags: usize = switch (sys.errno(getfl_rc)) {
            .SUCCESS => @intCast(getfl_rc),
            else => |e| unexpectedErrno(e),
        };

        const new_flags = existing_flags | (1 << @bitOffsetOf(sys.O, "NONBLOCK"));
        switch (sys.errno(sys.fcntl(accepted_fd, sys.F.SETFL, new_flags))) {
            .SUCCESS => {},
            else => |e| unexpectedErrno(e),
        }
    }

    if (flags.isActive(.CLOEXEC)) {
        const getfd_rc = sys.fcntl(accepted_fd, sys.F.GETFD, 0);
        const existing_flags: usize = switch (sys.errno(getfd_rc)) {
            .SUCCESS => @intCast(getfd_rc),
            else => |e| unexpectedErrno(e),
        };

        const new_flags = existing_flags | sys.FD_CLOEXEC;
        switch (sys.errno(sys.fcntl(accepted_fd, sys.F.SETFD, new_flags))) {
            .SUCCESS => {},
            else => |e| unexpectedErrno(e),
        }
    }

    return accepted_fd;
}

pub const ClockId = enum(u32) {
    REALTIME = @intFromEnum(@field(sys.clockid_t, "REALTIME")),
    MONOTONIC = @intFromEnum(@field(sys.clockid_t, "MONOTONIC")),
};

pub const timespec = sys.timespec;

pub const ClockGetTimeError = error{
    UnsupportedClock,
};

pub fn clock_gettime(id: ClockId) ClockGetTimeError!timespec {
    var spec: timespec = undefined;
    return switch (sys.errno(sys.clock_gettime(@enumFromInt(@intFromEnum(id)), &spec))) {
        .SUCCESS => spec,
        .INVAL => error.UnsupportedClock,
        else => |e| unexpectedErrno(e),
    };
}

pub inline fn timespecToNs(tp: timespec) i96 {
    return @intCast(@as(i96, tp.sec) * std.time.ns_per_s + tp.nsec);
}

pub const RecvmsgError = error{
    WouldBlock,
    SystemResources,
    PeerUnresponsive,
};

pub const msghdr = std.posix.msghdr;
pub const msghdr_const = std.posix.msghdr_const;

pub const iovec = std.posix.iovec;
pub const iovec_const = std.posix.iovec_const;

pub fn recvmsg(fd: socket_t, msg: *msghdr, flags: u32) RecvmsgError!usize {
    const rc = sys.recvmsg(fd, msg, flags);
    return switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .NOMEM => error.SystemResources,
        .TIMEDOUT => error.PeerUnresponsive,
        else => |e| unexpectedErrno(e),
    };
}

pub const SendmsgError = error{
    WouldBlock,
    SystemResources,
    ConnectionReset,
    MessageOversize,
    WriteHalfShutdown,
};

pub fn sendmsg(fd: socket_t, msg: *const msghdr_const, flags: u32) SendmsgError!usize {
    const new_flags = if (@hasDecl(sys.MSG, "NOSIGNAL"))
        flags | sys.MSG.NOSIGNAL
    else
        flags;

    const rc = sys.sendmsg(fd, msg, new_flags);
    return switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        .MSGSIZE => error.MessageOversize,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PIPE => error.WriteHalfShutdown,
        else => |e| unexpectedErrno(e),
    };
}

fn unexpectedErrno(errno: anytype) noreturn {
    if (builtin.mode == .Debug)
        std.debug.panic("unexpected errno: {t}", .{errno})
    else
        std.process.abort();
}

const sys = std.posix.system;

const builtin = @import("builtin");
const std = @import("std");
