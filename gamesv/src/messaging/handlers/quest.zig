pub fn getQuestData(
    message: Message(pb.GetQuestDataCsReq),
    response: Response(pb.GetQuestDataScRsp),
) !void {
    response.set(.{
        .quest_type = message.data.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(
    message: Message(pb.GetHollowDataCsReq),
    response: Response(pb.GetHollowDataScRsp),
) !void {
    _ = message;
    response.set(.{ .hollow_data = .init });
}

pub fn getArchiveData(
    message: Message(pb.GetArchiveDataCsReq),
    response: Response(pb.GetArchiveDataScRsp),
) !void {
    _ = message;
    response.set(.{ .archive_data = .init });
}

pub fn startTrainingQuest(
    message: Message(pb.StartTrainingQuestCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.StartTrainingQuestScRsp),
) !void {
    const Training = Changes.GameMode.Training;

    const quest: templates.training_quest.Id = @enumFromInt(message.data.quest_id);
    if (quest != .free_training) // Not implemented yet
        return response.fail(1);

    switch (message.data.avatar_id_list.items.len) {
        1...Training.AvatarSlot.count => {},
        else => return response.fail(1),
    }

    var avatars: Training.AvatarSlot.List = undefined;

    for (&avatars, 0..) |*slot, index| {
        if (index >= message.data.avatar_id_list.items.len) {
            slot.* = .none;
            continue;
        }

        const id = std.enums.fromInt(
            templates.avatar_base.Id,
            message.data.avatar_id_list.items[index],
        ) orelse
            return response.fail(1); // invalid avatar id

        if (!properties.avatar.indexes.contains(id))
            return response.fail(1); // avatar not unlocked

        slot.* = .fromId(id);
    }

    const mode_switch: Changes.GameMode = .{ .training = .{
        .quest = quest,
        .avatars = avatars,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn endBattle(
    message: Message(pb.EndBattleCsReq),
    response: Response(pb.EndBattleScRsp),
) !void {
    _ = message;
    response.set(.{ .fight_settle = .init });
}

const templates = Assets.templates;

const Changes = logic.Changes;
const Message = handlers.Message;
const Response = handlers.Response;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
