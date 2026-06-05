//! Namespace defining The Portable Operating System Interface (POSIX).
//! It includes:
//! * timers
//! * entropy
//! * networking
//! * I/O multiplexing
//! This namespace allows programmers to write *truly* optimal, reusable code while
//! participating in these operations.

pub const fd_t = sys.fd_t;

pub const WriteVError = error{
    WouldBlock,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    PermissionDenied,
    BrokenPipe,
    DeviceBusy,
};

pub fn writev(file: fd_t, iovecs: []const iovec_const) WriteVError!usize {
    if (native_os == .windows) {
        // TODO: loop over NtWriteFile/WriteFile
        @compileError("TODO writev windows");
    }

    const rc = sys.writev(file, iovecs.ptr, @truncate(iovecs.len));
    return switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .BUSY => error.DeviceBusy,
        else => |e| unexpectedErrno(e),
    };
}

pub const AF = enum(u32) {
    INET = sys.AF.INET,
    UNIX = sys.AF.UNIX,
};

pub const SOCK = enum(u32) {
    pub const Flags = enum(u32) {
        NONBLOCK = sys.SOCK.NONBLOCK,
        CLOEXEC = sys.SOCK.CLOEXEC,
        _,

        pub fn flags(enabled: FlagStruct(Flags)) Flags {
            var f: u32 = 0;

            inline for (@typeInfo(Flags).@"enum".fields) |field| {
                if (@field(enabled, field.name))
                    f |= field.value;
            }

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

pub const invalid_fd: socket_t = switch (native_os) {
    .windows => @ptrFromInt(std.math.maxInt(usize)),
    else => -1,
};

pub fn socket(af: AF, sock: SOCK, ipproto: IPPROTO) SocketError!socket_t {
    const socket_type = if (is_windows)
        @intFromEnum(sock) & ~@as(u32, sys.SOCK.NONBLOCK | sys.SOCK.CLOEXEC)
    else
        @intFromEnum(sock);

    const rc = sys.socket(@intFromEnum(af), socket_type, @intFromEnum(ipproto));
    return if (!is_windows) switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        else => |e| unexpectedErrno(e),
    } else if (rc == invalid_fd) switch (sys.WSAGetLastError()) {
        .WSAEACCES => error.AccessDenied,
        .WSAEMFILE => error.ProcessFdQuotaExceeded,
        .WSAENOBUFS => error.SystemResources,
        .WSAEPROTONOSUPPORT => error.ProtocolNotSupported,
        .WSANOTINITIALISED => startup: {
            var wsa_data: sys.WSADATA = undefined;
            break :startup switch (sys.WSAStartup(0x0202, &wsa_data)) {
                // Retry
                0 => socket(af, sock, ipproto),

                else => |error_rc| unexpectedErrno(
                    @as(sys.WinsockError, @enumFromInt(@as(u16, @intCast(error_rc)))),
                ),
            };
        },
        else => |e| unexpectedErrno(e),
    } else if (sock.hasFlag(.NONBLOCK)) nonblocking: {
        var argp: u32 = 1;
        if (sys.ioctlsocket(rc, sys.FIONBIO, &argp) == sys.SOCKET_ERROR)
            unexpectedErrno(sys.WSAGetLastError());

        break :nonblocking rc;
    } else rc;
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
    const rc = sys.bind(fd, addr.raw(), addr.len());
    return if (!is_windows) switch (sys.errno(rc)) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .NOMEM => error.SystemResources,
        else => |e| unexpectedErrno(e),
    } else if (rc == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
        .WSAEACCES => error.AccessDenied,
        .WSAEADDRINUSE => error.AddressInUse,
        .WSAEADDRNOTAVAIL => error.AddressUnavailable,
        .WSAENOBUFS => error.SystemResources,
        else => |e| unexpectedErrno(e),
    };
}

pub const ListenError = error{
    AddressInUse,
};

pub fn listen(fd: socket_t, backlog: u31) ListenError!void {
    const rc = sys.listen(fd, backlog);
    return if (!is_windows) switch (sys.errno(rc)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        else => |e| unexpectedErrno(e),
    } else if (rc == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
        .WSAEADDRINUSE => error.AddressInUse,
        else => |e| unexpectedErrno(e),
    } else {};
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
    const rc = sys.setsockopt(
        fd,
        @intFromEnum(level),
        @intFromEnum(optname),
        @ptrCast(&optval),
        @sizeOf(@TypeOf(optval)),
    );

    return if (!is_windows) switch (sys.errno(rc)) {
        .SUCCESS => {},
        else => |e| unexpectedErrno(e),
    } else if (rc == sys.SOCKET_ERROR) unexpectedErrno(sys.WSAGetLastError());
}

pub fn close(fd: sys.fd_t) void {
    if (!is_windows) {
        _ = sys.close(fd);
    } else {
        // Closing a socket is different from closing a file handle on windows
        // that is, winsock has to do additional state cleanup for socket handles.
        // Try to close it as a socket first, otherwise fallback to NtClose.

        if (sys.closesocket(fd) == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
            .WSAENOTSOCK => _ = std.os.windows.ntdll.NtClose(fd),
            else => |e| unexpectedErrno(e),
        };
    }
}

pub const pollfd = sys.pollfd;

pub const POLL = sys.POLL;

pub const PollError = error{
    Interrupted,
    SystemResources,
};

pub fn poll(pollfds: []pollfd, timeout: i32) PollError!usize {
    const rc = sys.poll(pollfds.ptr, @intCast(pollfds.len), timeout);

    return if (!is_windows) switch (sys.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .NOMEM => error.SystemResources,
        else => |e| unexpectedErrno(e),
    } else if (rc == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
        .WSAENOBUFS => error.SystemResources,
        else => |e| unexpectedErrno(e),
    } else @intCast(rc);
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

    if (@hasDecl(sys, "accept4")) {
        const rc = sys.accept4(fd, addr.rawMut(), &addrlen, @intFromEnum(flags));
        return switch (sys.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            .CONNABORTED => error.ConnectionAborted,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .PERM => error.BlockedByFirewall,
            .PROTO => error.ProtocolError,
            else => |e| unexpectedErrno(e),
        };
    }

    if (is_windows) {
        const rc = sys.accept(fd, addr.rawMut(), &addrlen);
        return if (rc != invalid_fd) set_flags: {
            if (flags.isActive(.NONBLOCK)) {
                var argp: u32 = 1;
                if (sys.ioctlsocket(rc, sys.FIONBIO, &argp) == sys.SOCKET_ERROR)
                    unexpectedErrno(sys.WSAGetLastError());
            }

            break :set_flags rc;
        } else switch (sys.WSAGetLastError()) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionAborted,
            .WSAEMFILE => error.ProcessFdQuotaExceeded,
            .WSAENOBUFS => error.SystemResources,
            else => |e| unexpectedErrno(e),
        };
    }

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

    if (!is_windows) return switch (sys.errno(sys.clock_gettime(@enumFromInt(@intFromEnum(id)), &spec))) {
        .SUCCESS => spec,
        .INVAL => error.UnsupportedClock,
        else => |e| unexpectedErrno(e),
    } else switch (id) {
        // emulate `clock_gettime` through windows APIs.
        .REALTIME => {
            const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
            return nsToTimespec(@as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns);
        },
        .MONOTONIC => {
            const qpf: u64 = qpf: {
                var qpf: std.os.windows.LARGE_INTEGER = undefined;
                if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool())
                    return std.mem.zeroes(timespec);

                break :qpf @bitCast(qpf);
            };

            const qpc: u64 = qpc: {
                var qpc: std.os.windows.LARGE_INTEGER = undefined;
                if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool())
                    return std.mem.zeroes(timespec);

                break :qpc @bitCast(qpc);
            };

            const common_qpf = 10_000_000;

            const ns: i96 = if (qpf == common_qpf)
                qpc * (std.time.ns_per_s / common_qpf)
            else scale: {
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                break :scale @intCast((@as(u96, qpc) * scale) >> 32);
            };

            return nsToTimespec(ns);
        },
    }
}

pub inline fn timespecToNs(tp: timespec) i96 {
    return @intCast(@as(i96, tp.sec) * std.time.ns_per_s + tp.nsec);
}

pub inline fn timespecToMs(tp: timespec) i64 {
    return @intCast(@as(i64, tp.sec) * std.time.ms_per_s + @divFloor(tp.nsec, std.time.ns_per_ms));
}

pub inline fn nsToTimespec(ns: i96) timespec {
    return .{
        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

pub inline fn msToTimespec(ms: i64) timespec {
    return .{
        .sec = @intCast(@divFloor(ms, std.time.ms_per_s)),
        .nsec = @intCast(@mod(ms, std.time.ms_per_s) * std.time.ns_per_ms),
    };
}

pub const msghdr = switch (native_os) {
    .windows => sys.msghdr,
    else => std.posix.msghdr,
};

pub const msghdr_const = switch (native_os) {
    .windows => sys.msghdr_const,
    else => std.posix.msghdr_const,
};

pub const iovec = switch (native_os) {
    .windows => sys.iovec,
    else => std.posix.iovec,
};

pub const iovec_const = switch (native_os) {
    .windows => sys.iovec_const,
    else => std.posix.iovec_const,
};

pub const RecvmsgError = error{
    WouldBlock,
    ConnectionReset,
    SystemResources,
    PeerUnresponsive,
    MessageOversize,
};

pub fn recvmsg(fd: socket_t, msg: *msghdr, flags: u32) RecvmsgError!usize {
    if (is_windows) {
        var lpNumberOfBytesRecvd: u32 = undefined;
        const rc = sys.WSARecvFrom(
            fd,
            msg.iov,
            msg.iovlen,
            &lpNumberOfBytesRecvd,
            &msg.flags,
            msg.name,
            &msg.namelen,
            null, // lpOverlapped
            null, // lpCompletionRoutine
        );

        return if (rc == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionReset,
            .WSAENOBUFS => error.SystemResources,
            .WSAEMSGSIZE => error.MessageOversize,
            .WSAETIMEDOUT => error.PeerUnresponsive,
            else => |e| unexpectedErrno(e),
        } else lpNumberOfBytesRecvd;
    } else { // POSIX
        const rc = sys.recvmsg(fd, msg, flags);
        return switch (sys.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            .CONNRESET => error.ConnectionReset,
            .NOMEM => error.SystemResources,
            .TIMEDOUT => error.PeerUnresponsive,
            else => |e| unexpectedErrno(e),
        };
    }
}

pub const SendmsgError = error{
    WouldBlock,
    SystemResources,
    ConnectionReset,
    MessageOversize,
    WriteHalfShutdown,
};

pub fn sendmsg(fd: socket_t, msg: *const msghdr_const, flags: u32) SendmsgError!usize {
    if (is_windows) {
        var lpNumberOfBytesSent: u32 = undefined;
        const rc = sys.WSASendTo(
            fd,
            msg.iov,
            msg.iovlen,
            &lpNumberOfBytesSent,
            flags,
            msg.name,
            msg.namelen,
            null, // lpOverlapped
            null, // lpCompletionRoutine
        );

        return if (rc == sys.SOCKET_ERROR) switch (sys.WSAGetLastError()) {
            .WSAENOBUFS => error.SystemResources,
            .WSAEMSGSIZE => error.MessageOversize,
            .WSAECONNRESET, .WSAENETRESET => error.ConnectionReset,
            else => |e| unexpectedErrno(e),
        } else lpNumberOfBytesSent;
    } else { // POSIX
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
}

pub const GetEntropyError = error{
    EntropyUnavailable,
};

pub fn getentropy(buf: []u8) GetEntropyError!void {
    return switch (native_os) {
        .windows => win32GenRandom(buf),
        else => readUrandom(buf),
    };
}

fn readUrandom(buf: []u8) GetEntropyError!void {
    const open_rc = sys.open("/dev/urandom", .{}, 0);
    const fd: sys.fd_t = switch (sys.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.EntropyUnavailable,
    };

    defer _ = sys.close(fd);

    var unfilled = buf;
    while (unfilled.len != 0) {
        const read_rc = sys.read(fd, unfilled.ptr, @intCast(unfilled.len));
        switch (sys.errno(read_rc)) {
            .SUCCESS => unfilled = unfilled[read_rc..],
            else => return error.EntropyUnavailable,
        }
    }
}

fn win32GenRandom(buf: []u8) GetEntropyError!void {
    var unfilled = buf;

    while (unfilled.len != 0) {
        const n_fill: std.os.windows.ULONG = @truncate(unfilled.len);
        if (sys.RtlGenRandom(unfilled.ptr, n_fill) == .FALSE)
            return error.EntropyUnavailable;

        unfilled = unfilled[n_fill..];
    }
}

fn unexpectedErrno(errno: anytype) noreturn {
    if (builtin.mode == .Debug)
        std.debug.panic("unexpected errno: {t}", .{errno})
    else
        std.process.abort();
}

/// For an enum type representing flags,
/// returns a struct with each flag as a boolean field.
///
/// The fields themselves do not correlate with actual flag values.
fn FlagStruct(comptime FlagEnum: type) type {
    const enum_fields = @typeInfo(FlagEnum).@"enum".fields;
    var field_names: [enum_fields.len][]const u8 = undefined;

    inline for (enum_fields, &field_names) |enum_field, *field_name|
        field_name.* = enum_field.name;

    return @Struct(
        .auto,
        null,
        &field_names,
        &@splat(bool),
        &@splat(.{ .default_value_ptr = &false }),
    );
}

const sys = switch (native_os) {
    .windows => @import("posix/win32.zig"),
    else => std.posix.system,
};

const is_windows = native_os == .windows;
const native_os = builtin.os.tag;

const builtin = @import("builtin");
const std = @import("std");
