//! Win32-to-POSIX layer.

pub const fd_t = windows.HANDLE;
pub const socklen_t = u32;

pub const timespec = extern struct {
    sec: i64,
    nsec: c_long,
};

pub const clockid_t = enum(u32) {
    REALTIME = 0,
    MONOTONIC = 1,
};

pub const pollfd = extern struct {
    fd: fd_t,
    events: u16,
    revents: u16,
};

pub const sockaddr = extern struct {
    family: u16,
    data: [14]u8,

    pub const SS_MAXSIZE = 128;
    pub const storage = extern struct {
        family: u16 align(8),
        padding: [SS_MAXSIZE - @sizeOf(u16)]u8 = undefined,

        comptime {
            assert(@sizeOf(storage) == SS_MAXSIZE);
            assert(@alignOf(storage) == 8);
        }
    };

    /// IPv4 socket address
    pub const in = extern struct {
        family: u16 = AF.INET,
        port: USHORT,
        addr: u32,
        zero: [8]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    /// IPv6 socket address
    pub const in6 = extern struct {
        family: u16 = AF.INET6,
        port: USHORT,
        flowinfo: u32,
        addr: [16]u8,
        scope_id: u32,
    };

    /// UNIX domain socket address
    pub const un = extern struct {
        family: u16 = AF.UNIX,
        path: [108]u8,
    };
};

pub const msghdr = extern struct {
    name: ?*sockaddr,
    namelen: socklen_t,
    iov: [*]iovec,
    iovlen: u32,
    control: ?*anyopaque,
    controllen: usize,
    flags: u32,
};

pub const msghdr_const = extern struct {
    name: ?*const sockaddr,
    namelen: socklen_t,
    iov: [*]const iovec_const,
    iovlen: u32,
    control: ?*const anyopaque,
    controllen: usize,
    flags: u32,
};

pub const iovec = extern struct {
    len: ULONG,
    base: [*]u8,
};

pub const iovec_const = extern struct {
    len: ULONG,
    base: [*]const u8,
};

pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;

pub const NtWriteFile = windows.ntdll.NtWriteFile;
pub const NtOpenThread = windows.ntdll.NtOpenThread;

pub const PAPCFUNC = *const fn (ULONG_PTR) callconv(.winapi) void;

pub extern "kernel32" fn QueueUserAPC(
    PAPCFUNC,
    HANDLE,
    ULONG_PTR,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    *const fn (dwCtrlType: DWORD) callconv(.winapi) BOOL,
    BOOL,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn SystemFunction036(output: [*]u8, length: ULONG) callconv(.winapi) BOOL;
pub const RtlGenRandom = SystemFunction036;

pub extern "ws2_32" fn WSAStartup(wVersionRequired: WORD, lpWSAData: *WSADATA) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;
pub extern "ws2_32" fn socket(af: u32, st: u32, proto: u32) callconv(.winapi) fd_t;
pub extern "ws2_32" fn closesocket(s: fd_t) callconv(.winapi) i32;
pub extern "ws2_32" fn ioctlsocket(s: fd_t, cmd: i32, argp: *u32) callconv(.winapi) i32;
pub extern "ws2_32" fn bind(s: fd_t, name: *const sockaddr, namelen: u32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: fd_t, backlog: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn accept(s: fd_t, addr: ?*sockaddr, addrlen: ?*u32) callconv(.winapi) fd_t;

pub extern "ws2_32" fn WSASendTo(
    s: fd_t,
    lpBuffers: [*]const iovec_const,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpTo: ?*const sockaddr,
    iToLen: u32,
    lpOverlapped: ?*anyopaque,
    lpCompletionRounte: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSARecvFrom(
    s: fd_t,
    lpBuffers: [*]iovec,
    dwBuffercount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpFrom: ?*sockaddr,
    lpFromlen: ?*u32,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn setsockopt(
    s: fd_t,
    level: i32,
    optname: u32,
    optval: ?[*]const u8,
    optlen: u32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAPoll(fdArray: [*]pollfd, fds: u32, timeout: i32) callconv(.winapi) i32;

const AFD_POLL = struct {
    const READ: windows.ULONG = 0x0001;
    const OOB: windows.ULONG = 0x0002;
    const WRITE: windows.ULONG = 0x0004;
    const HUP: windows.ULONG = 0x0008;
    const RESET: windows.ULONG = 0x0010;
    const CLOSE: windows.ULONG = 0x0020;
    const CONNECT: windows.ULONG = 0x0040;
    const ACCEPT: windows.ULONG = 0x0080;
    const CONNECT_ERR: windows.ULONG = 0x0100;

    // Trailing: [*]HANDLE_INFO
    const INFO = extern struct {
        Timeout: windows.LARGE_INTEGER,
        NumberOfHandles: windows.ULONG,
        Exclusive: windows.ULONG,
    };

    const HANDLE_INFO = extern struct {
        Handle: windows.HANDLE,
        Events: windows.ULONG,
        Status: windows.NTSTATUS,
    };
};

threadlocal var thread_afd_handle = windows.INVALID_HANDLE_VALUE;
threadlocal var thread_poll_info: [*]u8 = undefined;
threadlocal var thread_poll_info_len: usize = 0;

pub const PollError = error{
    AfdCreationFailed,
    AfdIoctlFailed,
    SystemResources,
    Interrupted,
};

pub fn poll(fds: [*]pollfd, nfds: u32, timeout: i32) PollError!u31 {
    if (thread_afd_handle == windows.INVALID_HANDLE_VALUE) {
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        switch (ntdll.NtCreateFile(
            &thread_afd_handle,
            .{
                .GENERIC = .{ .WRITE = true, .READ = true },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            &.{
                .ObjectName = @constCast(&windows.UNICODE_STRING.init(
                    &.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'A', 'f', 'd', '\\', 'H', 'o', 'l', 'l', 'o', 'w' },
                )),
            },
            &iosb,
            null, // AllocationSize
            .{}, // FileAttributes
            .{ .READ = true, .WRITE = true },
            .OPEN_IF,
            .{ .IO = .ASYNCHRONOUS },
            null, // EaBuffer
            0, // EaLength
        )) {
            .SUCCESS => {},
            else => return error.AfdCreationFailed,
        }
    }

    if (@divFloor(thread_poll_info_len -| @sizeOf(AFD_POLL.INFO), @sizeOf(AFD_POLL.HANDLE_INFO)) < nfds) {
        // TODO: heap.PageAllocator also offers realloc

        if (thread_poll_info_len != 0)
            heap.PageAllocator.unmap(@alignCast(thread_poll_info[0..thread_poll_info_len]));

        const allocation_len = std.mem.alignForward(
            usize,
            @sizeOf(AFD_POLL.INFO) + nfds * @sizeOf(AFD_POLL.HANDLE_INFO),
            heap.pageSize(),
        );

        const pages = heap.PageAllocator.map(allocation_len, .of(AFD_POLL.INFO)) orelse
            return error.SystemResources;

        thread_poll_info = pages;
        thread_poll_info_len = allocation_len;
    }

    const poll_info: *AFD_POLL.INFO = @ptrCast(@alignCast(thread_poll_info));

    poll_info.Timeout = if (timeout >= 0)
        -@as(i64, timeout) * 10_000
    else
        -0x7FFFFFFFFFFFFFFF;

    poll_info.NumberOfHandles = 0;
    poll_info.Exclusive = 0;

    const poll_handle_infos: [*]AFD_POLL.HANDLE_INFO = @ptrCast(@alignCast(
        thread_poll_info[@sizeOf(AFD_POLL.INFO)..],
    ));

    for (fds[0..nfds]) |*fd| {
        if (fd.fd == windows.INVALID_HANDLE_VALUE) {
            fd.revents = POLL.NVAL;
            continue;
        }

        poll_handle_infos[poll_info.NumberOfHandles] = .{
            .Handle = fd.fd,
            .Status = .SUCCESS,
            .Events = Events: {
                // https://gitlab.winehq.org/wine/wine/-/blob/e6180321fe7c6a766ce27603c52761bea0a98739/dlls/ws2_32/socket.c#L3158-3164

                var ev: windows.ULONG = AFD_POLL.HUP |
                    AFD_POLL.RESET |
                    AFD_POLL.CONNECT_ERR;

                if ((fd.events & POLL.RDNORM) != 0)
                    ev |= AFD_POLL.ACCEPT | AFD_POLL.READ;

                if ((fd.events & POLL.RDBAND) != 0)
                    ev |= AFD_POLL.OOB;

                if ((fd.events & POLL.WRNORM) != 0)
                    ev |= AFD_POLL.WRITE;

                break :Events ev;
            },
        };

        poll_info.NumberOfHandles += 1;
    }

    // https://gitlab.winehq.org/wine/wine/-/blob/e6180321fe7c6a766ce27603c52761bea0a98739/dlls/ws2_32/socket.c#L3113
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (ntdll.NtDeviceIoControlFile(
        thread_afd_handle,
        null, // Event
        null, // ApcRoutine
        null, // ApcContext
        &iosb,
        windows.IOCTL.AFD.POLL,
        poll_info,
        @sizeOf(AFD_POLL.INFO) + nfds * @sizeOf(AFD_POLL.HANDLE_INFO),
        poll_info,
        @sizeOf(AFD_POLL.INFO) + nfds * @sizeOf(AFD_POLL.HANDLE_INFO),
    )) {
        .SUCCESS => unreachable,
        .PENDING => {},
        else => return error.AfdIoctlFailed,
    }

    switch (ntdll.NtWaitForSingleObject(
        thread_afd_handle,
        .TRUE, // Alertable
        null, // Timeout
    )) {
        .SUCCESS => {},
        .TIMEOUT => unreachable,
        .ALERTED, .USER_APC => {
            _ = ntdll.NtCancelIoFile(thread_afd_handle, &iosb);
            return error.Interrupted;
        },
        else => unreachable,
    }

    switch (iosb.u.Status) {
        .SUCCESS => {},
        .TIMEOUT => return 0,
        else => return error.SystemResources,
    }

    var ret_count: u31 = 0;
    var infos_i: usize = 0;

    // Wine does O(n^2) here
    // https://gitlab.winehq.org/wine/wine/-/blob/e6180321fe7c6a766ce27603c52761bea0a98739/dlls/ws2_32/socket.c#L3190-3216
    for (fds[0..nfds]) |*fd| {
        if (fd.fd == windows.INVALID_HANDLE_VALUE)
            continue;

        const poll_handle_info = poll_handle_infos[infos_i];
        infos_i += 1;

        var revents: u16 = 0;

        if ((poll_handle_info.Events & (AFD_POLL.ACCEPT | AFD_POLL.READ)) != 0)
            revents |= POLL.RDNORM;

        if ((poll_handle_info.Events & AFD_POLL.OOB) != 0)
            revents |= POLL.RDBAND;

        if ((poll_handle_info.Events & AFD_POLL.WRITE) != 0)
            revents |= POLL.WRNORM;

        if ((poll_handle_info.Events & (AFD_POLL.RESET | AFD_POLL.HUP)) != 0)
            revents |= POLL.HUP;

        if ((poll_handle_info.Events & (AFD_POLL.RESET | AFD_POLL.CONNECT_ERR)) != 0)
            revents |= POLL.ERR;

        if ((poll_handle_info.Events & AFD_POLL.CLOSE) != 0)
            revents |= POLL.NVAL;

        fd.revents = revents;
        if (revents != 0) ret_count += 1;
    }

    return ret_count;
}

pub const FIONBIO = -2147195266;
pub const SOCKET_ERROR = -1;

pub const AF = struct {
    pub const UNSPEC = 0;
    pub const UNIX = 1;
    pub const INET = 2;
    pub const IMPLINK = 3;
    pub const PUP = 4;
    pub const CHAOS = 5;
    pub const NS = 6;
    pub const IPX = 6;
    pub const ISO = 7;
    pub const ECMA = 8;
    pub const DATAKIT = 9;
    pub const CCITT = 10;
    pub const SNA = 11;
    pub const DECnet = 12;
    pub const DLI = 13;
    pub const LAT = 14;
    pub const HYLINK = 15;
    pub const APPLETALK = 16;
    pub const NETBIOS = 17;
    pub const VOICEVIEW = 18;
    pub const FIREFOX = 19;
    pub const UNKNOWN1 = 20;
    pub const BAN = 21;
    pub const ATM = 22;
    pub const INET6 = 23;
    pub const CLUSTER = 24;
    pub const @"12844" = 25;
    pub const IRDA = 26;
    pub const NETDES = 28;
    pub const MAX = 29;
    pub const TCNPROCESS = 29;
    pub const TCNMESSAGE = 30;
    pub const ICLFXBM = 31;
    pub const LINK = 33;
    pub const HYPERV = 34;
};

pub const SOCK = struct {
    pub const STREAM = 1;
    pub const DGRAM = 2;
    pub const RAW = 3;
    pub const RDM = 4;
    pub const SEQPACKET = 5;
    pub const CLOEXEC = 0x10000;
    pub const NONBLOCK = 0x20000;
};

pub const SOL = struct {
    pub const IRLMP = 255;
    pub const SOCKET = 65535;
};

pub const SO = struct {
    pub const DEBUG = 1;
    pub const ACCEPTCONN = 2;
    pub const REUSEADDR = 4;
    pub const KEEPALIVE = 8;
    pub const DONTROUTE = 16;
    pub const BROADCAST = 32;
    pub const USELOOPBACK = 64;
    pub const LINGER = 128;
    pub const OOBINLINE = 256;
    pub const SNDBUF = 4097;
    pub const RCVBUF = 4098;
    pub const SNDLOWAT = 4099;
    pub const RCVLOWAT = 4100;
    pub const SNDTIMEO = 4101;
    pub const RCVTIMEO = 4102;
    pub const ERROR = 4103;
    pub const TYPE = 4104;
    pub const BSP_STATE = 4105;
    pub const GROUP_ID = 8193;
    pub const GROUP_PRIORITY = 8194;
    pub const MAX_MSG_SIZE = 8195;
    pub const CONDITIONAL_ACCEPT = 12290;
    pub const PAUSE_ACCEPT = 12291;
    pub const COMPARTMENT_ID = 12292;
    pub const RANDOMIZE_PORT = 12293;
    pub const PORT_SCALABILITY = 12294;
    pub const REUSE_UNICASTPORT = 12295;
    pub const REUSE_MULTICASTPORT = 12296;
    pub const ORIGINAL_DST = 12303;
    pub const PROTOCOL_INFOA = 8196;
    pub const PROTOCOL_INFOW = 8197;
    pub const CONNDATA = 28672;
    pub const CONNOPT = 28673;
    pub const DISCDATA = 28674;
    pub const DISCOPT = 28675;
    pub const CONNDATALEN = 28676;
    pub const CONNOPTLEN = 28677;
    pub const DISCDATALEN = 28678;
    pub const DISCOPTLEN = 28679;
    pub const OPENTYPE = 28680;
    pub const SYNCHRONOUS_ALERT = 16;
    pub const SYNCHRONOUS_NONALERT = 32;
    pub const MAXDG = 28681;
    pub const MAXPATHDG = 28682;
    pub const UPDATE_ACCEPT_CONTEXT = 28683;
    pub const CONNECT_TIME = 28684;
    pub const UPDATE_CONNECT_CONTEXT = 28688;
};

pub const IPPROTO = struct {
    pub const IP = 0;
    pub const ICMP = 1;
    pub const IGMP = 2;
    pub const GGP = 3;
    pub const TCP = 6;
    pub const PUP = 12;
    pub const UDP = 17;
    pub const IDP = 22;
    pub const ND = 77;
    pub const RM = 113;
    pub const RAW = 255;
    pub const MAX = 256;
};

pub const POLL = struct {
    pub const RDNORM = 256;
    pub const RDBAND = 512;
    pub const PRI = 1024;
    pub const WRNORM = 16;
    pub const WRBAND = 32;
    pub const ERR = 1;
    pub const HUP = 2;
    pub const NVAL = 4;
    pub const IN = RDNORM | RDBAND;
    pub const OUT = WRNORM;
};

// https://docs.microsoft.com/en-au/windows/win32/winsock/windows-sockets-error-codes-2
pub const WinsockError = enum(u16) {
    /// Specified event object handle is invalid.
    /// An application attempts to use an event object, but the specified handle is not valid.
    WSA_INVALID_HANDLE = 6,

    /// Insufficient memory available.
    /// An application used a Windows Sockets function that directly maps to a Windows function.
    /// The Windows function is indicating a lack of required memory resources.
    WSA_NOT_ENOUGH_MEMORY = 8,

    /// One or more parameters are invalid.
    /// An application used a Windows Sockets function which directly maps to a Windows function.
    /// The Windows function is indicating a problem with one or more parameters.
    WSA_INVALID_PARAMETER = 87,

    /// Overlapped operation aborted.
    /// An overlapped operation was canceled due to the closure of the socket, or the execution of the SIO_FLUSH command in WSAIoctl.
    WSA_OPERATION_ABORTED = 995,

    /// Overlapped I/O event object not in signaled state.
    /// The application has tried to determine the status of an overlapped operation which is not yet completed.
    /// Applications that use WSAGetOverlappedResult (with the fWait flag set to FALSE) in a polling mode to determine when an overlapped operation has completed, get this error code until the operation is complete.
    WSA_IO_INCOMPLETE = 996,

    /// The application has initiated an overlapped operation that cannot be completed immediately.
    /// A completion indication will be given later when the operation has been completed.
    WSA_IO_PENDING = 997,

    /// Interrupted function call.
    /// A blocking operation was interrupted by a call to WSACancelBlockingCall.
    WSAEINTR = 10004,

    /// File handle is not valid.
    /// The file handle supplied is not valid.
    WSAEBADF = 10009,

    /// Permission denied.
    /// An attempt was made to access a socket in a way forbidden by its access permissions.
    /// An example is using a broadcast address for sendto without broadcast permission being set using setsockopt(SO.BROADCAST).
    /// Another possible reason for the WSAEACCES error is that when the bind function is called (on Windows NT 4.0 with SP4 and later), another application, service, or kernel mode driver is bound to the same address with exclusive access.
    /// Such exclusive access is a new feature of Windows NT 4.0 with SP4 and later, and is implemented by using the SO.EXCLUSIVEADDRUSE option.
    WSAEACCES = 10013,

    /// Bad address.
    /// The system detected an invalid pointer address in attempting to use a pointer argument of a call.
    /// This error occurs if an application passes an invalid pointer value, or if the length of the buffer is too small.
    /// For instance, if the length of an argument, which is a sockaddr structure, is smaller than the sizeof(sockaddr).
    WSAEFAULT = 10014,

    /// Invalid argument.
    /// Some invalid argument was supplied (for example, specifying an invalid level to the setsockopt function).
    /// In some instances, it also refers to the current state of the socket—for instance, calling accept on a socket that is not listening.
    WSAEINVAL = 10022,

    /// Too many open files.
    /// Too many open sockets. Each implementation may have a maximum number of socket handles available, either globally, per process, or per thread.
    WSAEMFILE = 10024,

    /// Resource temporarily unavailable.
    /// This error is returned from operations on nonblocking sockets that cannot be completed immediately, for example recv when no data is queued to be read from the socket.
    /// It is a nonfatal error, and the operation should be retried later.
    /// It is normal for WSAEWOULDBLOCK to be reported as the result from calling connect on a nonblocking SOCK.STREAM socket, since some time must elapse for the connection to be established.
    WSAEWOULDBLOCK = 10035,

    /// Operation now in progress.
    /// A blocking operation is currently executing.
    /// Windows Sockets only allows a single blocking operation—per- task or thread—to be outstanding, and if any other function call is made (whether or not it references that or any other socket) the function fails with the WSAEINPROGRESS error.
    WSAEINPROGRESS = 10036,

    /// Operation already in progress.
    /// An operation was attempted on a nonblocking socket with an operation already in progress—that is, calling connect a second time on a nonblocking socket that is already connecting, or canceling an asynchronous request (WSAAsyncGetXbyY) that has already been canceled or completed.
    WSAEALREADY = 10037,

    /// Socket operation on nonsocket.
    /// An operation was attempted on something that is not a socket.
    /// Either the socket handle parameter did not reference a valid socket, or for select, a member of an fd_set was not valid.
    WSAENOTSOCK = 10038,

    /// Destination address required.
    /// A required address was omitted from an operation on a socket.
    /// For example, this error is returned if sendto is called with the remote address of ADDR_ANY.
    WSAEDESTADDRREQ = 10039,

    /// Message too long.
    /// A message sent on a datagram socket was larger than the internal message buffer or some other network limit, or the buffer used to receive a datagram was smaller than the datagram itself.
    WSAEMSGSIZE = 10040,

    /// Protocol wrong type for socket.
    /// A protocol was specified in the socket function call that does not support the semantics of the socket type requested.
    /// For example, the ARPA Internet UDP protocol cannot be specified with a socket type of SOCK.STREAM.
    WSAEPROTOTYPE = 10041,

    /// Bad protocol option.
    /// An unknown, invalid or unsupported option or level was specified in a getsockopt or setsockopt call.
    WSAENOPROTOOPT = 10042,

    /// Protocol not supported.
    /// The requested protocol has not been configured into the system, or no implementation for it exists.
    /// For example, a socket call requests a SOCK.DGRAM socket, but specifies a stream protocol.
    WSAEPROTONOSUPPORT = 10043,

    /// Socket type not supported.
    /// The support for the specified socket type does not exist in this address family.
    /// For example, the optional type SOCK.RAW might be selected in a socket call, and the implementation does not support SOCK.RAW sockets at all.
    WSAESOCKTNOSUPPORT = 10044,

    /// Operation not supported.
    /// The attempted operation is not supported for the type of object referenced.
    /// Usually this occurs when a socket descriptor to a socket that cannot support this operation is trying to accept a connection on a datagram socket.
    WSAEOPNOTSUPP = 10045,

    /// Protocol family not supported.
    /// The protocol family has not been configured into the system or no implementation for it exists.
    /// This message has a slightly different meaning from WSAEAFNOSUPPORT.
    /// However, it is interchangeable in most cases, and all Windows Sockets functions that return one of these messages also specify WSAEAFNOSUPPORT.
    WSAEPFNOSUPPORT = 10046,

    /// Address family not supported by protocol family.
    /// An address incompatible with the requested protocol was used.
    /// All sockets are created with an associated address family (that is, AF.INET for Internet Protocols) and a generic protocol type (that is, SOCK.STREAM).
    /// This error is returned if an incorrect protocol is explicitly requested in the socket call, or if an address of the wrong family is used for a socket, for example, in sendto.
    WSAEAFNOSUPPORT = 10047,

    /// Address already in use.
    /// Typically, only one usage of each socket address (protocol/IP address/port) is permitted.
    /// This error occurs if an application attempts to bind a socket to an IP address/port that has already been used for an existing socket, or a socket that was not closed properly, or one that is still in the process of closing.
    /// For server applications that need to bind multiple sockets to the same port number, consider using setsockopt (SO.REUSEADDR).
    /// Client applications usually need not call bind at all—connect chooses an unused port automatically.
    /// When bind is called with a wildcard address (involving ADDR_ANY), a WSAEADDRINUSE error could be delayed until the specific address is committed.
    /// This could happen with a call to another function later, including connect, listen, WSAConnect, or WSAJoinLeaf.
    WSAEADDRINUSE = 10048,

    /// Cannot assign requested address.
    /// The requested address is not valid in its context.
    /// This normally results from an attempt to bind to an address that is not valid for the local computer.
    /// This can also result from connect, sendto, WSAConnect, WSAJoinLeaf, or WSASendTo when the remote address or port is not valid for a remote computer (for example, address or port 0).
    WSAEADDRNOTAVAIL = 10049,

    /// Network is down.
    /// A socket operation encountered a dead network.
    /// This could indicate a serious failure of the network system (that is, the protocol stack that the Windows Sockets DLL runs over), the network interface, or the local network itself.
    WSAENETDOWN = 10050,

    /// Network is unreachable.
    /// A socket operation was attempted to an unreachable network.
    /// This usually means the local software knows no route to reach the remote host.
    WSAENETUNREACH = 10051,

    /// Network dropped connection on reset.
    /// The connection has been broken due to keep-alive activity detecting a failure while the operation was in progress.
    /// It can also be returned by setsockopt if an attempt is made to set SO.KEEPALIVE on a connection that has already failed.
    WSAENETRESET = 10052,

    /// Software caused connection abort.
    /// An established connection was aborted by the software in your host computer, possibly due to a data transmission time-out or protocol error.
    WSAECONNABORTED = 10053,

    /// Connection reset by peer.
    /// An existing connection was forcibly closed by the remote host.
    /// This normally results if the peer application on the remote host is suddenly stopped, the host is rebooted, the host or remote network interface is disabled, or the remote host uses a hard close (see setsockopt for more information on the SO.LINGER option on the remote socket).
    /// This error may also result if a connection was broken due to keep-alive activity detecting a failure while one or more operations are in progress.
    /// Operations that were in progress fail with WSAENETRESET. Subsequent operations fail with WSAECONNRESET.
    WSAECONNRESET = 10054,

    /// No buffer space available.
    /// An operation on a socket could not be performed because the system lacked sufficient buffer space or because a queue was full.
    WSAENOBUFS = 10055,

    /// Socket is already connected.
    /// A connect request was made on an already-connected socket.
    /// Some implementations also return this error if sendto is called on a connected SOCK.DGRAM socket (for SOCK.STREAM sockets, the to parameter in sendto is ignored) although other implementations treat this as a legal occurrence.
    WSAEISCONN = 10056,

    /// Socket is not connected.
    /// A request to send or receive data was disallowed because the socket is not connected and (when sending on a datagram socket using sendto) no address was supplied.
    /// Any other type of operation might also return this error—for example, setsockopt setting SO.KEEPALIVE if the connection has been reset.
    WSAENOTCONN = 10057,

    /// Cannot send after socket shutdown.
    /// A request to send or receive data was disallowed because the socket had already been shut down in that direction with a previous shutdown call.
    /// By calling shutdown a partial close of a socket is requested, which is a signal that sending or receiving, or both have been discontinued.
    WSAESHUTDOWN = 10058,

    /// Too many references.
    /// Too many references to some kernel object.
    WSAETOOMANYREFS = 10059,

    /// Connection timed out.
    /// A connection attempt failed because the connected party did not properly respond after a period of time, or the established connection failed because the connected host has failed to respond.
    WSAETIMEDOUT = 10060,

    /// Connection refused.
    /// No connection could be made because the target computer actively refused it.
    /// This usually results from trying to connect to a service that is inactive on the foreign host—that is, one with no server application running.
    WSAECONNREFUSED = 10061,

    /// Cannot translate name.
    /// Cannot translate a name.
    WSAELOOP = 10062,

    /// Name too long.
    /// A name component or a name was too long.
    WSAENAMETOOLONG = 10063,

    /// Host is down.
    /// A socket operation failed because the destination host is down. A socket operation encountered a dead host.
    /// Networking activity on the local host has not been initiated.
    /// These conditions are more likely to be indicated by the error WSAETIMEDOUT.
    WSAEHOSTDOWN = 10064,

    /// No route to host.
    /// A socket operation was attempted to an unreachable host. See WSAENETUNREACH.
    WSAEHOSTUNREACH = 10065,

    /// Directory not empty.
    /// Cannot remove a directory that is not empty.
    WSAENOTEMPTY = 10066,

    /// Too many processes.
    /// A Windows Sockets implementation may have a limit on the number of applications that can use it simultaneously.
    /// WSAStartup may fail with this error if the limit has been reached.
    WSAEPROCLIM = 10067,

    /// User quota exceeded.
    /// Ran out of user quota.
    WSAEUSERS = 10068,

    /// Disk quota exceeded.
    /// Ran out of disk quota.
    WSAEDQUOT = 10069,

    /// Stale file handle reference.
    /// The file handle reference is no longer available.
    WSAESTALE = 10070,

    /// Item is remote.
    /// The item is not available locally.
    WSAEREMOTE = 10071,

    /// Network subsystem is unavailable.
    /// This error is returned by WSAStartup if the Windows Sockets implementation cannot function at this time because the underlying system it uses to provide network services is currently unavailable.
    /// Users should check:
    ///   - That the appropriate Windows Sockets DLL file is in the current path.
    ///   - That they are not trying to use more than one Windows Sockets implementation simultaneously.
    ///   - If there is more than one Winsock DLL on your system, be sure the first one in the path is appropriate for the network subsystem currently loaded.
    ///   - The Windows Sockets implementation documentation to be sure all necessary components are currently installed and configured correctly.
    WSASYSNOTREADY = 10091,

    /// Winsock.dll version out of range.
    /// The current Windows Sockets implementation does not support the Windows Sockets specification version requested by the application.
    /// Check that no old Windows Sockets DLL files are being accessed.
    WSAVERNOTSUPPORTED = 10092,

    /// Successful WSAStartup not yet performed.
    /// Either the application has not called WSAStartup or WSAStartup failed.
    /// The application may be accessing a socket that the current active task does not own (that is, trying to share a socket between tasks), or WSACleanup has been called too many times.
    WSANOTINITIALISED = 10093,

    /// Graceful shutdown in progress.
    /// Returned by WSARecv and WSARecvFrom to indicate that the remote party has initiated a graceful shutdown sequence.
    WSAEDISCON = 10101,

    /// No more results.
    /// No more results can be returned by the WSALookupServiceNext function.
    WSAENOMORE = 10102,

    /// Call has been canceled.
    /// A call to the WSALookupServiceEnd function was made while this call was still processing. The call has been canceled.
    WSAECANCELLED = 10103,

    /// Procedure call table is invalid.
    /// The service provider procedure call table is invalid.
    /// A service provider returned a bogus procedure table to Ws2_32.dll.
    /// This is usually caused by one or more of the function pointers being NULL.
    WSAEINVALIDPROCTABLE = 10104,

    /// Service provider is invalid.
    /// The requested service provider is invalid.
    /// This error is returned by the WSCGetProviderInfo and WSCGetProviderInfo32 functions if the protocol entry specified could not be found.
    /// This error is also returned if the service provider returned a version number other than 2.0.
    WSAEINVALIDPROVIDER = 10105,

    /// Service provider failed to initialize.
    /// The requested service provider could not be loaded or initialized.
    /// This error is returned if either a service provider's DLL could not be loaded (LoadLibrary failed) or the provider's WSPStartup or NSPStartup function failed.
    WSAEPROVIDERFAILEDINIT = 10106,

    /// System call failure.
    /// A system call that should never fail has failed.
    /// This is a generic error code, returned under various conditions.
    /// Returned when a system call that should never fail does fail.
    /// For example, if a call to WaitForMultipleEvents fails or one of the registry functions fails trying to manipulate the protocol/namespace catalogs.
    /// Returned when a provider does not return SUCCESS and does not provide an extended error code.
    /// Can indicate a service provider implementation error.
    WSASYSCALLFAILURE = 10107,

    /// Service not found.
    /// No such service is known. The service cannot be found in the specified name space.
    WSASERVICE_NOT_FOUND = 10108,

    /// Class type not found.
    /// The specified class was not found.
    WSATYPE_NOT_FOUND = 10109,

    /// No more results.
    /// No more results can be returned by the WSALookupServiceNext function.
    WSA_E_NO_MORE = 10110,

    /// Call was canceled.
    /// A call to the WSALookupServiceEnd function was made while this call was still processing. The call has been canceled.
    WSA_E_CANCELLED = 10111,

    /// Database query was refused.
    /// A database query failed because it was actively refused.
    WSAEREFUSED = 10112,

    /// Host not found.
    /// No such host is known. The name is not an official host name or alias, or it cannot be found in the database(s) being queried.
    /// This error may also be returned for protocol and service queries, and means that the specified name could not be found in the relevant database.
    WSAHOST_NOT_FOUND = 11001,

    /// Nonauthoritative host not found.
    /// This is usually a temporary error during host name resolution and means that the local server did not receive a response from an authoritative server. A retry at some time later may be successful.
    WSATRY_AGAIN = 11002,

    /// This is a nonrecoverable error.
    /// This indicates that some sort of nonrecoverable error occurred during a database lookup.
    /// This may be because the database files (for example, BSD-compatible HOSTS, SERVICES, or PROTOCOLS files) could not be found, or a DNS request was returned by the server with a severe error.
    WSANO_RECOVERY = 11003,

    /// Valid name, no data record of requested type.
    /// The requested name is valid and was found in the database, but it does not have the correct associated data being resolved for.
    /// The usual example for this is a host name-to-address translation attempt (using gethostbyname or WSAAsyncGetHostByName) which uses the DNS (Domain Name Server).
    /// An MX record is returned but no A record—indicating the host itself exists, but is not directly reachable.
    WSANO_DATA = 11004,

    /// QoS receivers.
    /// At least one QoS reserve has arrived.
    WSA_QOS_RECEIVERS = 11005,

    /// QoS senders.
    /// At least one QoS send path has arrived.
    WSA_QOS_SENDERS = 11006,

    /// No QoS senders.
    /// There are no QoS senders.
    WSA_QOS_NO_SENDERS = 11007,

    /// QoS no receivers.
    /// There are no QoS receivers.
    WSA_QOS_NO_RECEIVERS = 11008,

    /// QoS request confirmed.
    /// The QoS reserve request has been confirmed.
    WSA_QOS_REQUEST_CONFIRMED = 11009,

    /// QoS admission error.
    /// A QoS error occurred due to lack of resources.
    WSA_QOS_ADMISSION_FAILURE = 11010,

    /// QoS policy failure.
    /// The QoS request was rejected because the policy system couldn't allocate the requested resource within the existing policy.
    WSA_QOS_POLICY_FAILURE = 11011,

    /// QoS bad style.
    /// An unknown or conflicting QoS style was encountered.
    WSA_QOS_BAD_STYLE = 11012,

    /// QoS bad object.
    /// A problem was encountered with some part of the filterspec or the provider-specific buffer in general.
    WSA_QOS_BAD_OBJECT = 11013,

    /// QoS traffic control error.
    /// An error with the underlying traffic control (TC) API as the generic QoS request was converted for local enforcement by the TC API.
    /// This could be due to an out of memory error or to an internal QoS provider error.
    WSA_QOS_TRAFFIC_CTRL_ERROR = 11014,

    /// QoS generic error.
    /// A general QoS error.
    WSA_QOS_GENERIC_ERROR = 11015,

    /// QoS service type error.
    /// An invalid or unrecognized service type was found in the QoS flowspec.
    WSA_QOS_ESERVICETYPE = 11016,

    /// QoS flowspec error.
    /// An invalid or inconsistent flowspec was found in the QOS structure.
    WSA_QOS_EFLOWSPEC = 11017,

    /// Invalid QoS provider buffer.
    /// An invalid QoS provider-specific buffer.
    WSA_QOS_EPROVSPECBUF = 11018,

    /// Invalid QoS filter style.
    /// An invalid QoS filter style was used.
    WSA_QOS_EFILTERSTYLE = 11019,

    /// Invalid QoS filter type.
    /// An invalid QoS filter type was used.
    WSA_QOS_EFILTERTYPE = 11020,

    /// Incorrect QoS filter count.
    /// An incorrect number of QoS FILTERSPECs were specified in the FLOWDESCRIPTOR.
    WSA_QOS_EFILTERCOUNT = 11021,

    /// Invalid QoS object length.
    /// An object with an invalid ObjectLength field was specified in the QoS provider-specific buffer.
    WSA_QOS_EOBJLENGTH = 11022,

    /// Incorrect QoS flow count.
    /// An incorrect number of flow descriptors was specified in the QoS structure.
    WSA_QOS_EFLOWCOUNT = 11023,

    /// Unrecognized QoS object.
    /// An unrecognized object was found in the QoS provider-specific buffer.
    WSA_QOS_EUNKOWNPSOBJ = 11024,

    /// Invalid QoS policy object.
    /// An invalid policy object was found in the QoS provider-specific buffer.
    WSA_QOS_EPOLICYOBJ = 11025,

    /// Invalid QoS flow descriptor.
    /// An invalid QoS flow descriptor was found in the flow descriptor list.
    WSA_QOS_EFLOWDESC = 11026,

    /// Invalid QoS provider-specific flowspec.
    /// An invalid or inconsistent flowspec was found in the QoS provider-specific buffer.
    WSA_QOS_EPSFLOWSPEC = 11027,

    /// Invalid QoS provider-specific filterspec.
    /// An invalid FILTERSPEC was found in the QoS provider-specific buffer.
    WSA_QOS_EPSFILTERSPEC = 11028,

    /// Invalid QoS shape discard mode object.
    /// An invalid shape discard mode object was found in the QoS provider-specific buffer.
    WSA_QOS_ESDMODEOBJ = 11029,

    /// Invalid QoS shaping rate object.
    /// An invalid shaping rate object was found in the QoS provider-specific buffer.
    WSA_QOS_ESHAPERATEOBJ = 11030,

    /// Reserved policy QoS element type.
    /// A reserved policy element was found in the QoS provider-specific buffer.
    WSA_QOS_RESERVED_PETYPE = 11031,

    _,
};

const BOOL = windows.BOOL;
const WORD = windows.WORD;
const DWORD = windows.DWORD;
const ULONG = windows.ULONG;
const USHORT = windows.USHORT;
const ULONG_PTR = windows.ULONG_PTR;
const HANDLE = windows.HANDLE;

pub const WSADATA = if (@sizeOf(usize) == @sizeOf(u64))
    extern struct {
        wVersion: WORD,
        wHighVersion: WORD,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    }
else
    extern struct {
        wVersion: WORD,
        wHighVersion: WORD,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
    };

const heap = std.heap;
const ntdll = windows.ntdll;
const windows = std.os.windows;
const assert = std.debug.assert;

const std = @import("std");
