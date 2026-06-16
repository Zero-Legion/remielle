pub fn mutateBasicInfo(
    inputs: Inputs(.{
        logic.Changes.ControlAvatar,
        logic.Changes.ControlGuiseAvatar,
    }),
) !void {
    const basic_info = &inputs.frame.cvars.properties.basic_info[inputs.frame.target_index];

    if (inputs.changes.control_avatar) |control_avatar|
        basic_info.control_avatar = control_avatar;

    if (inputs.changes.control_guise_avatar) |control_guise_avatar|
        basic_info.control_guise_avatar = control_guise_avatar;
}

const Inputs = mutators.Inputs;

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");

const std = @import("std");
