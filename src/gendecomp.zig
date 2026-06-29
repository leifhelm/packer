const std = @import("std");
const elfy = @import("elfy");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.io.Writer;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const out_filename = args[1];
    const out_file = try std.fs.cwd().createFileZ(out_filename, .{});
    defer out_file.close();

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    const writer = &out_writer.interface;

    try writer.writeAll(
        \\const elfy = @import("elfy");
        \\pub const Relocation = struct {
        \\    offset: u64,
        \\    @"type": elfy.RelocationType,
        \\    symbol_name: []const u8,
        \\    value: ?u64,
        \\    addend: ?i64,
        \\};
        \\pub const Arch = struct {
        \\    text: []const u8,
        \\    relocations: []const Relocation,
        \\};
        \\
    );

    const x86_object = args[2];
    try generic(allocator, writer, "x86", x86_object);
    const aarch64_object = args[3];
    try generic(allocator, writer, "aarch64", aarch64_object);

    try writer.flush();
}

fn generic(allocator: Allocator, writer: *Writer, name: []const u8, object: [:0]const u8) !void {
    var elf = try elfy.Elf.init(object, .ReadOnly, allocator);
    defer elf.deinit();
    const text_section = try elf.getSectionByName(".text");
    const text_start = text_section.getAddress();
    std.debug.assert(text_start == 0);
    const text = try elf.getSectionData(text_section);

    try writer.print(
        \\pub const {s}: Arch = .{{
        \\    .text = &.{any},
        \\    .relocations = &.{{
    , .{ name, text });

    var relocations = try elf.getIterator(elfy.ElfRelocation);
    var relocation_list: ArrayList(elfy.ElfRelocation) = .empty;
    defer relocation_list.deinit(allocator);
    while (try relocations.next()) |relocation| {
        const @"type" = try relocation.getType(elf.getHeader().getMachine());
        const symbol = try elf.getRelocationLinkedSymbol(relocation, relocations.index);
        const symbol_name = try elf.getSymbolName(symbol);
        std.debug.print("{}, {}, {s}, {}, {}\n", .{ @"type", symbol, symbol_name, symbol.getType(), symbol.getBind() });
        try serializeValue(writer, .{
            .offset = relocation.getOffset(),
            .type = @"type",
            .symbol_name = symbol_name,
            .value = if (symbol.getSectionIndex() == 0) null else symbol.getValue(),
            .addend = relocation.getAddend(),
        });
        try writer.writeAll(",");
    }
    try writer.writeAll(
        \\},
        \\};
        \\
    );
}

pub fn serializeValue(writer: *Writer, value: anytype) !void {
    const type_info = @typeInfo(@TypeOf(value));
    switch (type_info) {
        .@"struct" => |s| {
            std.debug.assert(s.layout == .auto);
            std.debug.assert(s.is_tuple == false);
            try writer.writeAll(".{");
            inline for (s.fields) |field| {
                try writer.print(".{f}=", .{std.zig.fmtId(field.name)});
                try serializeValue(writer, @field(value, field.name));
                try writer.writeAll(",");
            }
            try writer.writeAll("}");
        },
        .int => |_| {
            try writer.print("{d}", .{value});
        },
        .@"union" => |u| {
            std.debug.assert(u.layout == .auto);
            try writer.print(".{{.{f}=", .{std.zig.fmtId(@tagName(value))});
            inline for (u.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(value))) {
                    try serializeValue(writer, @field(value, field.name));
                }
            }
            try writer.writeAll("}");
        },
        .@"enum" => |_| {
            try writer.print(".{f}", .{std.zig.fmtId(@tagName(value))});
        },
        .pointer => |p| {
            std.debug.assert(p.size == .slice);
            try writer.writeAll("&.{");
            for (value) |item| {
                try serializeValue(writer, item);
                try writer.writeAll(",");
            }
            try writer.writeAll("}");
        },
        .optional => {
            if (value) |v| {
                try serializeValue(writer, v);
            } else {
                try writer.writeAll("null");
            }
        },
        else => std.debug.panic("Serialization of {s} not implemented", .{@tagName(type_info)}),
    }
}
