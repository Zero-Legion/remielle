pub fn playerLogin(
    input: handlers.Input(pb.PlayerLoginCsReq),
    output: handlers.Output(pb.PlayerLoginScRsp),
) !void {
    _ = input;
    output.respond(.init);
}

pub fn getSelfBasicInfo(
    input: handlers.Input(pb.GetSelfBasicInfoCsReq),
    output: handlers.Output(pb.GetSelfBasicInfoScRsp),
) !void {
    const info = &input.frame.cvars.properties.basic_info[input.frame.target_index];

    output.respond(.{
        .self_basic_info = .{
            .level = info.level.toInt(),
            .nick_name = "xeondev", // TODO
            .name_change_times = 1, // TODO
            .avatar_id = info.avatar.toInt(),
            .control_avatar_id = info.control_avatar.toInt(),
            .control_guise_avatar_id = info.control_guise_avatar.toInt(),
        },
    });
}

pub fn modAvatar(
    input: handlers.Input(pb.ModAvatarCsReq),
    output: handlers.Output(pb.ModAvatarScRsp),
) !void {
    const basic_info = &input.frame.cvars.properties.basic_info[input.frame.target_index];

    const new_control_avatar = Properties.HallAvatar.fromInt(input.message.control_avatar_id) orelse
        return output.bail(.{ .retcode = 1 });

    const new_control_guise_avatar = Properties.HallAvatar.Guise.fromRawId(
        &input.frame.cvars.properties.avatar[input.frame.target_index],
        input.message.control_guise_avatar_id,
    ) catch |err| return switch (err) {
        error.InvalidAvatarId,
        error.AvatarNotUnlocked,
        => output.bail(.{ .retcode = 1 }),
    };

    if (basic_info.control_avatar != new_control_avatar)
        output.changes.control_avatar = new_control_avatar;

    if (basic_info.control_guise_avatar != new_control_guise_avatar)
        output.changes.control_guise_avatar = new_control_guise_avatar;

    output.respond(.init);
}

const BasicInfo = Properties.BasicInfo;
const Properties = logic.Properties;

const templates = Assets.templates;

const pb = @import("rmpb").main;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
