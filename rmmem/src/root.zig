fn SoaBucket(comptime capacity: usize, comptime Struct: type) type {
    const struct_info = @typeInfo(Struct).@"struct";

    var field_names: [struct_info.fields.len][]const u8 = undefined;
    var field_types: [struct_info.fields.len]type = undefined;

    inline for (struct_info.fields, &field_names, &field_types) |struct_field, *field_name, *field_type| {
        field_name.* = struct_field.name;

        field_type.* = switch (struct_field.type) {
            bool => std.StaticBitSet(capacity),
            else => |Field| switch (@typeInfo(Field)) {
                .bool => unreachable,
                .int, .float, .array, .@"struct", .@"enum", .@"union", .pointer => [capacity]Field,
                else => @compileError("you're holding it wrong"),
            },
        };
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn suggestBucketSize(comptime desired_size: usize, comptime Struct: type) usize {
    const desired_bytes = @sizeOf(SoaBucket(desired_size, Struct));
    if (desired_bytes % heap.page_size_min == 0)
        return desired_size;

    const desired_pages = std.math.divCeil(usize, desired_bytes, heap.page_size_min) catch unreachable;
    var suggested_size = desired_size;

    while (std.math.divCeil(
        usize,
        @sizeOf(SoaBucket(suggested_size + 1, Struct)),
        heap.page_size_min,
    ) catch unreachable == desired_pages) : (suggested_size += 1) {}

    return suggested_size;
}

pub fn RemielleArrayList(
    comptime bucket_size: usize,
    comptime Struct: type,
    comptime Index: type,
) type {
    const enum_indexing: bool = comptime switch (@typeInfo(Index)) {
        .int => |int| int: {
            std.debug.assert(int.signedness == .unsigned);
            break :int false;
        },
        .@"enum" => |enumeration| enumeration: {
            std.debug.assert(!enumeration.is_exhaustive);
            break :enumeration true;
        },
        else => @compileError("invalid index type: " ++ @typeName(Index)),
    };

    return struct {
        const List = @This();

        pub const Bucket = SoaBucket(bucket_size, Struct);

        pub const bucket_capacity = bucket_size;

        // We're using ArrayList instead of linked lists to achieve O(1) indexing.
        // A new bucket insertion is a rare operation, so nobody cares about it being not O(1).
        // Keep in mind that we're storing pointers here, so even the worst case appending to it
        // won't result in copying/relocating all bucket data.
        buckets: std.ArrayList(*Bucket),

        pub const empty: List = .{ .buckets = .empty };

        pub inline fn capacity(list: *const List) usize {
            return list.buckets.items.len * bucket_size;
        }

        pub inline fn get(
            list: *const List,
            comptime field_name: @EnumLiteral(),
            index: Index,
        ) @FieldType(Struct, @tagName(field_name)) {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            return switch (@FieldType(Struct, @tagName(field_name))) {
                bool => @field(bucket, @tagName(field_name)).isSet(i % bucket_size),
                else => @field(bucket, @tagName(field_name))[i % bucket_size],
            };
        }

        pub inline fn getPtr(
            list: *List,
            comptime field_name: @EnumLiteral(),
            index: Index,
        ) *@FieldType(Struct, @tagName(field_name)) {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            return switch (@FieldType(Struct, @tagName(field_name))) {
                bool => @compileError("if you need mutable access, use `swapBit` instead, otherwise `get`"),
                else => &(@field(bucket, @tagName(field_name))[i % bucket_size]),
            };
        }

        pub fn swapBit(
            list: *List,
            comptime field_name: @EnumLiteral(),
            index: Index,
            value: bool,
        ) bool {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            const bit_set = &@field(bucket, @tagName(field_name));
            const old_value = bit_set.isSet(i % bucket_size);
            bit_set.setValue(i % bucket_size, value);

            return old_value;
        }

        pub const MapError = error{
            MappingFailed,
        };

        /// Maps one bucket.
        /// Returns index into `buckets`.
        pub fn mapOne(list: *List) MapError!usize {
            const page = heap.PageAllocator.map(@sizeOf(Bucket), .of(Bucket)) orelse
                return error.MappingFailed;

            const bucket: *Bucket = @ptrCast(@alignCast(page));

            if (list.buckets.capacity == 0) list.buckets.ensureTotalCapacity(
                heap.page_allocator,
                @divFloor(heap.page_size_min, @sizeOf(usize)),
            ) catch
                return error.MappingFailed;

            list.buckets.append(heap.page_allocator, bucket) catch
                return error.MappingFailed;

            return list.buckets.items.len - 1;
        }

        inline fn intFromIndex(index: Index) usize {
            return if (enum_indexing) @intFromEnum(index) else index;
        }
    };
}

const heap = std.heap;
const std = @import("std");
