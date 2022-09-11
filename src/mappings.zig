const std = @import("std");

const TINY_CLASS_TYPE = 'c';

pub const Mappings = struct {
    spigotToMojMap: std.StringHashMapUnmanaged([]const u8),
    mojMapToSpigot: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *Mappings, allocator: std.mem.Allocator) void {
        self.spigotToMojMap.deinit(allocator);
        self.mojMapToSpigot.deinit(allocator);
    }

    pub fn parseMappings(text: []const u8, allocator: std.mem.Allocator) !Mappings {
        var mappings = Mappings{ .spigotToMojMap = std.StringHashMapUnmanaged([]const u8){}, .mojMapToSpigot = std.StringHashMapUnmanaged([]const u8){} };
        errdefer mappings.deinit(allocator);

        var stream = std.io.fixedBufferStream(text);
        const reader = stream.reader();

        // skip first line header
        try readTo(reader, '\n');

        while (true) {
            const mapType = reader.readByte() catch break; // don't error, just end of mappings
            if (mapType == TINY_CLASS_TYPE) {
                try expect(reader, '\t');
                const mojClassStart = stream.getPos() catch return error.ParseError;
                try readTo(reader, '\t');
                const spigotSliceStart = stream.getPos() catch return error.ParseError;
                const mojSlice = text[mojClassStart .. spigotSliceStart - 1];
                try readTo(reader, '\n');
                const spigotSlice = text[spigotSliceStart .. (stream.getPos() catch return error.ParseError) - 1];

                try mappings.spigotToMojMap.put(allocator, spigotSlice, mojSlice);
                try mappings.mojMapToSpigot.put(allocator, mojSlice, spigotSlice);
            } else {
                try readTo(reader, '\n');
            }
        }

        return mappings;
    }
};

fn expect(reader: anytype, expected: u8) !void {
    var byte: u8 = reader.readByte() catch return error.ParseError;
    if (byte != expected) {
        return error.ParseError;
    }
}

fn readTo(reader: anytype, readToChar: u8) !void {
    var byte: u8 = undefined;
    while (true) {
        byte = reader.readByte() catch return error.ParseError;
        if (byte == readToChar) {
            break;
        }
    }
}
