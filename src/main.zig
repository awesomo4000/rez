const std = @import("std");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("rez regex engine\n", .{});
    try stdout.flush();
}
