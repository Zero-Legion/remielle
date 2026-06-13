pub fn mutateBasicInfo(
    control_avatar: mutators.Input(logic.Changes.ControlAvatar),
    control_guise_avatar: mutators.Input(logic.Changes.ControlGuiseAvatar),
) !void {
    const basic_info = &control_avatar.frame.cvars.properties.basic_info[control_avatar.frame.target_index];

    if (control_avatar.changes.len != 0)
        basic_info.control_avatar = control_avatar.changes[0];

    if (control_guise_avatar.changes.len != 0)
        basic_info.control_guise_avatar = control_guise_avatar.changes[0];
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");

const std = @import("std");
