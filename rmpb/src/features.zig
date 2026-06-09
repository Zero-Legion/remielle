pub const Feature = enum {
    player_kick,
};

const desc_set: rmpb.Descriptors = .main;

/// Indicates whether a protocol `feature` is available.
pub inline fn isAvailable(comptime feature: Feature) bool {
    return switch (feature) {
        .player_kick => if (desc_set.getDescriptorByName("PlayerKickScNotify")) |message|
            message.hasField("reason")
        else
            false,
    };
}

const rmpb = @import("root.zig");
