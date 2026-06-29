const std = @import("std");
const packer = @import("packer");
const clap = @import("clap");

pub fn main() !void {
    std.process.exit(try mainWithExitCode());
}
fn mainWithExitCode() !u8 {
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

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\    --pad-text <STR>  Text placed in the ELF padding. Max 8 characters.
        \\<INPUT>               Input ELF binary
        \\<OUTPUT>              Output ELF binary
    );
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .INPUT = clap.parsers.string,
        .OUTPUT = clap.parsers.string,
    };
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        // Report useful error and exit.
        try diag.report(stderr, err);
        return 64;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try stderr.writeAll("Usage: packer ");
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeAll("\n");
        try clap.help(stderr, clap.Help, &params, .{
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
        return 0;
    }

    const input_file = res.positionals[0] orelse {
        try stderr.writeAll("Please specify a input file\n");
        return 64;
    };
    const output_file = res.positionals[1] orelse {
        try stderr.writeAll("Please specify a output file\n");
        return 64;
    };

    const file = try std.fs.cwd().createFile(output_file, .{ .mode = 0o777 });
    defer file.close();
    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var error_context: packer.Packer.ErrorContext = undefined;
    var pack: packer.Packer = try .init(allocator, input_file, &error_context, res.args.@"pad-text" orelse "");
    defer pack.deinit();

    pack.pack(&file_writer.interface) catch {
        try stderr.print("{f}\n", .{error_context});
        return 1;
    };

    try file_writer.interface.flush();
    return 0;
}
