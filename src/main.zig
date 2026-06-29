const std = @import("std");
const packer = @import("packer");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch @panic("Cannot flush stdout");

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch @panic("Cannot flush stderr");

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        try stdout.writeAll("Usage: packer INPUT OUTPUT\n");
        return;
    }

    const file = try std.fs.cwd().createFileZ(args[2], .{ .mode = 0o777 });
    defer file.close();
    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var error_context: packer.Packer.ErrorContext = undefined;
    var pack: packer.Packer = try .init(allocator, args[1], &error_context);
    defer pack.deinit();

    pack.pack(&file_writer.interface) catch {
        try stderr.print("{f}\n", .{error_context});
        return;
    };

    try file_writer.interface.flush();
}
