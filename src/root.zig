const std = @import("std");
const elfy = @import("elfy");
const ucl = @import("ucl");
const arch = @import("arch");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SymbolMap = std.StringHashMapUnmanaged(u64);
const Endian = std.builtin.Endian;

pub const Packer = struct {
    const Self = @This();
    pub const Error =
        Allocator.Error ||
        elfy.Elf.ElfError ||
        ucl.Error ||
        std.io.Writer.Error ||
        error{PackerError};

    pub const ErrorContext = union(enum) {
        pub const WrongBitSize = struct {
            machine: std.elf.EM,
            expected: u8,
            actual: u8,
        };
        pub const WrongEndian = struct {
            machine: std.elf.EM,
            expected: Endian,
            actual: Endian,
        };
        pub const Uncompressible = struct {
            original_size: u64,
            compressed_size: u64,
        };
        pub const NoSpaceForDecompressor = struct {
            load_start: u64,
            packed_size: u64,
            page_size: u64,
        };
        unsupported_architecture: std.elf.EM,
        unsupported_program_header_count: u16,
        wrong_bit_size: WrongBitSize,
        wrong_endian: WrongEndian,
        unsupported_elf_type: std.elf.ET,
        unsupported_program_type: elfy.ProgType,
        unsupported_program_flags: elfy.ProgFlag,
        uncompressible: Uncompressible,
        no_space_for_decompressor: NoSpaceForDecompressor,
        pad_text_length: usize,

        pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
            switch (self) {
                .unsupported_architecture => |machine| {
                    if (std.enums.tagName(std.elf.EM, machine)) |m| {
                        try writer.print("Unsupported architecture: {s}", .{m});
                    } else {
                        try writer.print("Unknown architecture: {d}", .{machine});
                    }
                },
                .unsupported_program_header_count => |program_header_count| {
                    try writer.print(
                        "Only one RWX LOAD program header is supported, found {d} LOAD program headers.",
                        .{program_header_count},
                    );
                },
                .wrong_bit_size => |wrong_bit_size| {
                    try writer.print(
                        "The {s} architecture has {d} bits but the ELF file got {d} bits.",
                        .{ @tagName(wrong_bit_size.machine), wrong_bit_size.expected, wrong_bit_size.actual },
                    );
                },
                .wrong_endian => |wrong_endian| {
                    try writer.print(
                        "The {s} architecture is {s} endian, but the ELF file is {s} endian.",
                        .{
                            @tagName(wrong_endian.machine),
                            @tagName(wrong_endian.expected),
                            @tagName(wrong_endian.actual),
                        },
                    );
                },
                .unsupported_elf_type => |elf_type| {
                    if (std.enums.tagName(std.elf.ET, elf_type)) |et| {
                        try writer.print("Unsupported ELF type: {s}, only EXEC is supported.", .{et});
                    } else {
                        try writer.print("Unsupported ELF type: {d}, only EXEC is supported.", .{elf_type});
                    }
                },
                .unsupported_program_type => |program_type| {
                    try writer.print(
                        "Unsupported program type: {s}. Only one RWX LAOD program header allowed.",
                        .{@tagName(program_type)},
                    );
                },
                .unsupported_program_flags => |program_flags| {
                    try writer.print(
                        "Unsupported program flags: {}. Only one RWX LAOD program header allowed.",
                        .{program_flags},
                    );
                },
                .uncompressible => |uncompressible| {
                    try writer.print(
                        "Uncompressible: original size: {d} bytes, compressed size: {d} bytes.",
                        .{ uncompressible.original_size, uncompressible.compressed_size },
                    );
                },
                .no_space_for_decompressor => |no_space_for_decompressor| {
                    try writer.print(
                        "No space for decompressor: load address is at {d} bytes, we need {d} bytes for decompressor and compressed data and {d} bytes for the null page.\nMove your program to higher a higher load address.",
                        no_space_for_decompressor,
                    );
                },
                .pad_text_length => |length| {
                    try writer.print("No space for {d} bytes text in 8 byte padding.", .{length});
                },
            }
        }
    };

    elf: elfy.Elf,
    error_context: ?*ErrorContext,
    pad_text: []const u8 = "",

    pub fn init(allocator: Allocator, elf_file: []const u8, error_context: ?*ErrorContext, pad_text: []const u8) !Self {
        const elf = try elfy.Elf.init(elf_file, .ReadOnly, allocator);
        errdefer elf.deinit();
        return .{
            .elf = elf,
            .error_context = error_context,
            .pad_text = pad_text,
        };
    }
    pub fn deinit(self: *Self) void {
        self.elf.deinit();
    }
    fn alloc(self: Self) Allocator {
        return self.elf.allocator;
    }
    pub fn pack(self: *Self, writer: *std.io.Writer) Error!void {
        const header = self.elf.getHeader();
        try self.verify_elf_header(header);

        const elf_type = header.getType();
        if (elf_type != .EXEC) return self.err(.{ .unsupported_elf_type = elf_type });

        var program_iter = try self.elf.getIterator(elfy.ElfProgram);
        var first_load: ?elfy.ElfProgram = null;
        var load_phdr_counter: u16 = 0;
        while (try program_iter.next()) |phdr| {
            if (phdr.getType() == .PT_LOAD) {
                load_phdr_counter += 1;
                if (first_load == null) {
                    first_load = phdr;
                }
            }
        }
        const load = if (first_load) |x| x else {
            return self.err(.{ .unsupported_program_header_count = load_phdr_counter });
        };

        const load_type = load.getType();
        if (load_type != .PT_LOAD) return self.err(.{ .unsupported_program_type = load_type });
        const load_flags = load.getFlags();
        if (!std.meta.eql(load_flags, .{
            .execute = true,
            .write = true,
            .read = true,
        })) return self.err(.{ .unsupported_program_flags = load_flags });

        const data = self.elf.getProgramData(load);

        switch (header.getMachine()) {
            // .@"386" => try self.pack_x86(writer, load, data),
            .@"386" => try self.generic_pack(writer, load, data, .@"386", false, .little, arch.x86),
            .AARCH64 => try self.generic_pack(writer, load, data, .AARCH64, true, .little, arch.aarch64),
            else => |machine| return self.err(.{ .unsupported_architecture = machine }),
        }
    }
    fn generic_pack(
        self: *Self,
        writer: *std.io.Writer,
        load: elfy.ElfProgram,
        data: []const u8,
        machine: std.elf.EM,
        comptime is_64: bool,
        endian: Endian,
        arch_struct: arch.Arch,
    ) Error!void {
        const Ehdr = if (is_64) std.elf.Elf64_Ehdr else std.elf.Elf32_Ehdr;
        const Phdr = if (is_64) std.elf.Elf64_Phdr else std.elf.Elf32_Phdr;
        const uintptr = if (is_64) u64 else u32;
        const bytes_from_ehdr = if (is_64) bytes_from_elf64_ehdr else bytes_from_elf32_ehdr;
        const bytes_from_phdr = if (is_64) bytes_from_elf64_phdr else bytes_from_elf32_phdr;
        const alignment: uintptr = @max(4096, @as(uintptr, @intCast(load.getAlignment())));
        const load_start: uintptr = @intCast(load.getVirtualAddress());
        const load_mem_end: uintptr = load_start + @as(uintptr, @intCast(load.getMemorySize()));
        const page_size = 0x1000;

        const compressed_buf = try self.alloc().alloc(u8, data.len * 2); // Over estimating memory needed
        defer self.alloc().free(compressed_buf);
        const compressed = try ucl.compress(self.alloc(), .Nrv2e, data, compressed_buf, null, 1, null, null);

        const original_size = self.elf.reader.buffer.len;
        const compressed_size = compressed.len + @sizeOf(Ehdr) + @sizeOf(Phdr) + arch_struct.text.len;
        if (compressed_size >= original_size) {
            return self.err(.{ .uncompressible = .{
                .original_size = original_size,
                .compressed_size = compressed_size,
            } });
        }

        const decompress: []u8 = try self.alloc().alloc(u8, arch_struct.text.len);
        defer self.alloc().free(decompress);
        @memcpy(decompress, arch_struct.text);

        const headers_size: uintptr =
            @as(uintptr, @intCast(@sizeOf(Phdr))) +
            @as(uintptr, @intCast(@sizeOf(Ehdr)));

        const packed_size = @as(uintptr, @intCast(compressed.len)) + @as(uintptr, @intCast(decompress.len)) + headers_size;
        if (load_start < packed_size + page_size) {
            return self.err(.{ .no_space_for_decompressor = .{
                .load_start = load_start,
                .packed_size = packed_size,
                .page_size = page_size,
            } });
        }
        const elf_start = std.mem.alignBackward(
            uintptr,
            load_start - packed_size,
            alignment,
        );
        const text_start = elf_start + headers_size;

        try self.patch_decompressor(arch_struct, decompress, text_start, load_start);

        const compressed_start: uintptr = text_start + @as(uintptr, @intCast(decompress.len));
        const compressed_end: uintptr = compressed_start + @as(uintptr, @intCast(compressed.len));
        const file_size = compressed_end - elf_start;

        var ident: [std.elf.EI_NIDENT]u8 = @splat(0);
        @memcpy(ident[0..4], std.elf.MAGIC);
        ident[std.elf.EI_CLASS] = if (is_64) std.elf.ELFCLASS64 else std.elf.ELFCLASS32;
        ident[std.elf.EI_DATA] = switch (endian) {
            .little => std.elf.ELFDATA2LSB,
            .big => std.elf.ELFDATA2MSB,
        };
        ident[std.elf.EI_VERSION] = 1;
        ident[std.elf.EI_OSABI] = @intFromEnum(std.elf.OSABI.NONE);
        if (self.pad_text.len > 8) {
            return self.err(.{ .pad_text_length = self.pad_text.len });
        } else if (self.pad_text.len == 8) {
            @memcpy(ident[std.elf.EI_ABIVERSION..std.elf.EI_NIDENT], self.pad_text);
        } else {
            @memcpy(ident[std.elf.EI_PAD..][0..self.pad_text.len], self.pad_text);
        }

        try writer.writeAll(&bytes_from_ehdr(.{
            .e_ident = ident,
            .e_type = .EXEC,
            .e_machine = machine,
            .e_version = 1,
            .e_entry = text_start,
            .e_phoff = if (is_64) 0x40 else 0x34,
            .e_shoff = 0,
            .e_flags = 0,
            .e_ehsize = if (is_64) 0x40 else 0x34,
            .e_phentsize = if (is_64) 0x38 else 0x20,
            .e_phnum = 1,
            .e_shentsize = if (is_64) 0x40 else 0x28,
            .e_shnum = 0,
            .e_shstrndx = 0,
        }, .little));
        try writer.writeAll(&bytes_from_phdr(.{
            .p_type = std.elf.PT_LOAD,
            .p_offset = 0x00,
            .p_vaddr = elf_start,
            .p_paddr = elf_start,
            .p_filesz = file_size,
            .p_memsz = std.mem.alignForward(uintptr, load_mem_end - elf_start, alignment),
            .p_flags = std.elf.PF_R | std.elf.PF_W | std.elf.PF_X,
            .p_align = alignment,
        }, .little));
        try writer.writeAll(decompress);
        try writer.writeAll(compressed);
    }
    fn patch_decompressor(self: *Self, arch_struct: arch.Arch, decompress: []u8, text_start: u64, decompress_dest: u64) !void {
        const entry = self.elf.getHeader().getEntryPoint();
        var symbol_map: SymbolMap = .empty;
        defer symbol_map.deinit(self.alloc());
        try symbol_map.put(self.alloc(), "decompress_dest", decompress_dest);
        try symbol_map.put(self.alloc(), "entry", entry);
        for (arch_struct.relocations) |relocation| {
            process_relocation(relocation, decompress, text_start, symbol_map);
        }
    }
    fn process_relocation(relocation: arch.Relocation, text_section: []u8, text_start: u64, symbol_map: SymbolMap) void {
        const value = if (relocation.value) |v| v + text_start else if (symbol_map.get(relocation.symbol_name)) |v| v else {
            std.debug.panic("Symbol {s} is undefined", .{relocation.symbol_name});
        };
        const offset = relocation.offset;
        switch (relocation.type) {
            .@"386" => |t| switch (t) {
                .R_386_32 => {
                    const current_value = std.mem.readInt(u32, text_section[offset..][0..4], .little);
                    std.mem.writeInt(u32, text_section[offset..][0..4], @intCast(current_value + value), .little);
                },
                else => std.debug.panic("Unsupported relocation {s}", .{@tagName(t)}),
            },
            else => std.debug.panic("Unsupported relocation architecture {s}", .{@tagName(relocation.type)}),
        }
    }
    fn verify_elf_header(self: *Self, header: elfy.ElfHeader) Error!void {
        const ExpectedMachineSpec = struct {
            machine: std.elf.EM,
            is_64: bool,
            endian: Endian,
        };
        const specs: []const ExpectedMachineSpec = &.{
            .{ .machine = .@"386", .is_64 = false, .endian = .little },
            .{ .machine = .AARCH64, .is_64 = true, .endian = .little },
        };
        const machine = header.getMachine();
        inline for (specs) |spec| {
            if (machine == spec.machine) {
                if (spec.is_64 and header == .elf32) {
                    return self.err(.{ .wrong_bit_size = .{ .machine = machine, .expected = 64, .actual = 32 } });
                }
                if (!spec.is_64 and header == .elf64) {
                    return self.err(.{ .wrong_bit_size = .{ .machine = machine, .expected = 32, .actual = 64 } });
                }
                const endian: Endian = switch (header.getData()) {
                    std.elf.ELFDATA2LSB => .little,
                    std.elf.ELFDATA2MSB => .big,
                    else => unreachable,
                };
                if (spec.endian != endian) {
                    return self.err(.{ .wrong_endian = .{ .machine = machine, .expected = spec.endian, .actual = endian } });
                }

                break;
            }
        } else return self.err(.{ .unsupported_architecture = machine });
    }
    fn err(self: *Self, error_context: ErrorContext) Error {
        if (self.error_context) |ctx| {
            ctx.* = error_context;
        }
        return Error.PackerError;
    }
};

fn bytes_from_elf32_ehdr(h: std.elf.Elf32_Ehdr, endian: Endian) [@sizeOf(std.elf.Elf32_Ehdr)]u8 {
    std.debug.assert(h.e_ident[std.elf.EI_DATA] == switch (endian) {
        .little => @as(u8, std.elf.ELFDATA2LSB),
        .big => @as(u8, std.elf.ELFDATA2MSB),
    });
    var buf: [@sizeOf(std.elf.Elf32_Ehdr)]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    writer.writeAll(&h.e_ident) catch unreachable;
    writeInt(&writer, @intFromEnum(h.e_type), endian);
    writeInt(&writer, @intFromEnum(h.e_machine), endian);
    writeInt(&writer, h.e_version, endian);
    writeInt(&writer, h.e_entry, endian);
    writeInt(&writer, h.e_phoff, endian);
    writeInt(&writer, h.e_shoff, endian);
    writeInt(&writer, h.e_flags, endian);
    writeInt(&writer, h.e_ehsize, endian);
    writeInt(&writer, h.e_phentsize, endian);
    writeInt(&writer, h.e_phnum, endian);
    writeInt(&writer, h.e_shentsize, endian);
    writeInt(&writer, h.e_shnum, endian);
    writeInt(&writer, h.e_shstrndx, endian);
    writer.flush() catch unreachable;
    return buf;
}
fn bytes_from_elf64_ehdr(h: std.elf.Elf64_Ehdr, endian: Endian) [@sizeOf(std.elf.Elf64_Ehdr)]u8 {
    std.debug.assert(h.e_ident[std.elf.EI_DATA] == switch (endian) {
        .little => @as(u8, std.elf.ELFDATA2LSB),
        .big => @as(u8, std.elf.ELFDATA2MSB),
    });
    var buf: [@sizeOf(std.elf.Elf64_Ehdr)]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    writer.writeAll(&h.e_ident) catch unreachable;
    writeInt(&writer, @intFromEnum(h.e_type), endian);
    writeInt(&writer, @intFromEnum(h.e_machine), endian);
    writeInt(&writer, h.e_version, endian);
    writeInt(&writer, h.e_entry, endian);
    writeInt(&writer, h.e_phoff, endian);
    writeInt(&writer, h.e_shoff, endian);
    writeInt(&writer, h.e_flags, endian);
    writeInt(&writer, h.e_ehsize, endian);
    writeInt(&writer, h.e_phentsize, endian);
    writeInt(&writer, h.e_phnum, endian);
    writeInt(&writer, h.e_shentsize, endian);
    writeInt(&writer, h.e_shnum, endian);
    writeInt(&writer, h.e_shstrndx, endian);
    writer.flush() catch unreachable;
    return buf;
}

fn bytes_from_elf32_phdr(h: std.elf.Elf32_Phdr, endian: Endian) [@sizeOf(std.elf.Elf32_Phdr)]u8 {
    var buf: [@sizeOf(std.elf.Elf32_Phdr)]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    writeInt(&writer, h.p_type, endian);
    writeInt(&writer, h.p_offset, endian);
    writeInt(&writer, h.p_vaddr, endian);
    writeInt(&writer, h.p_paddr, endian);
    writeInt(&writer, h.p_filesz, endian);
    writeInt(&writer, h.p_memsz, endian);
    writeInt(&writer, h.p_flags, endian);
    writeInt(&writer, h.p_align, endian);
    writer.flush() catch unreachable;
    return buf;
}
fn bytes_from_elf64_phdr(h: std.elf.Elf64_Phdr, endian: Endian) [@sizeOf(std.elf.Elf64_Phdr)]u8 {
    var buf: [@sizeOf(std.elf.Elf64_Phdr)]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    writeInt(&writer, h.p_type, endian);
    writeInt(&writer, h.p_flags, endian);
    writeInt(&writer, h.p_offset, endian);
    writeInt(&writer, h.p_vaddr, endian);
    writeInt(&writer, h.p_paddr, endian);
    writeInt(&writer, h.p_filesz, endian);
    writeInt(&writer, h.p_memsz, endian);
    writeInt(&writer, h.p_align, endian);
    writer.flush() catch unreachable;
    return buf;
}

fn writeInt(writer: *std.io.Writer, x: anytype, endian: Endian) void {
    writer.writeInt(@TypeOf(x), x, endian) catch unreachable;
}
