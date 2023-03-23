const std = @import("std");

const TINY_CLASS_TYPE = 'c';

pub const Mappings = struct {
    pub const Method = struct {
        signature: []const u8,
        name: []const u8,
    };

    pub const MethodContext = struct {
        pub fn hash(self: @This(), s: Method) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, s, .Deep);
            return hasher.final();
        }
        pub fn eql(self: @This(), a: Method, b: Method) bool {
            _ = self;
            return std.mem.eql(u8, a.signature, b.signature) and std.mem.eql(u8, a.name, b.name);
        }
    };

    pub const MethodHashMap = std.HashMapUnmanaged(Method, []const u8, MethodContext, std.hash_map.default_max_load_percentage);

    spigotToMojMap: std.StringHashMapUnmanaged([]const u8),
    mojMapToSpigot: std.StringHashMapUnmanaged([]const u8),

    spigotToSpigotFieldsToMojMapFields: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),

    spigotToSpigotMethodsToMojMapMethods: std.StringHashMapUnmanaged(MethodHashMap),

    pub fn deinit(self: *Mappings, allocator: std.mem.Allocator) void {
        self.spigotToMojMap.deinit(allocator);
        self.mojMapToSpigot.deinit(allocator);
        var itSpigot = self.spigotToSpigotFieldsToMojMapFields.iterator();
        while (itSpigot.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.spigotToSpigotFieldsToMojMapFields.deinit(allocator);
        var itMojMap = self.spigotToSpigotMethodsToMojMapMethods.iterator();
        while (itMojMap.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.spigotToSpigotMethodsToMojMapMethods.deinit(allocator);
    }

    pub fn parseMappings(text: []const u8, allocator: std.mem.Allocator) !Mappings {
        var mappings = Mappings{
            .spigotToMojMap = std.StringHashMapUnmanaged([]const u8){},
            .mojMapToSpigot = std.StringHashMapUnmanaged([]const u8){},
            .spigotToSpigotFieldsToMojMapFields = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)){},
            .spigotToSpigotMethodsToMojMapMethods = std.StringHashMapUnmanaged(MethodHashMap){},
        };
        errdefer mappings.deinit(allocator);

        var stream = std.io.fixedBufferStream(text);
        const reader = stream.reader();

        // skip first line header
        try readTo(reader, '\n');

        var lastSpigotSlice: ?[]const u8 = null;
        var lastMojMapSlice: ?[]const u8 = null;

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

                lastSpigotSlice = spigotSlice;
                lastMojMapSlice = mojSlice;
            } else if (mapType == '\t' and lastSpigotSlice != null and lastMojMapSlice != null) {
                const classType = reader.readByte() catch break;
                if (classType == 'f') {
                    try expect(reader, '\t');
                    // skip type
                    try readTo(reader, '\t');

                    const mojClassStart = stream.getPos() catch return error.ParseError;
                    try readTo(reader, '\t');
                    const spigotSliceStart = stream.getPos() catch return error.ParseError;
                    const mojSlice = text[mojClassStart .. spigotSliceStart - 1];
                    try readTo(reader, '\n');
                    const spigotSlice = text[spigotSliceStart .. (stream.getPos() catch return error.ParseError) - 1];

                    const spigotResult = try mappings.spigotToSpigotFieldsToMojMapFields.getOrPut(allocator, lastSpigotSlice.?);
                    if (!spigotResult.found_existing) {
                        spigotResult.value_ptr.* = std.StringHashMapUnmanaged([]const u8){};
                    }
                    try spigotResult.value_ptr.put(allocator, spigotSlice, mojSlice);
                } else if (classType == 'm') {
                    try expect(reader, '\t');
                    const typeStart = stream.getPos() catch return error.ParseError;

                    try readTo(reader, '\t');
                    const mojClassStart = stream.getPos() catch return error.ParseError;
                    const typeSlice = text[typeStart .. mojClassStart - 1];

                    try readTo(reader, '\t');
                    const spigotSliceStart = stream.getPos() catch return error.ParseError;
                    const mojSlice = text[mojClassStart .. spigotSliceStart - 1];

                    try readTo(reader, '\n');
                    const spigotSlice = text[spigotSliceStart .. (stream.getPos() catch return error.ParseError) - 1];

                    const spigotResult = try mappings.spigotToSpigotMethodsToMojMapMethods.getOrPut(allocator, lastSpigotSlice.?);
                    if (!spigotResult.found_existing) {
                        spigotResult.value_ptr.* = MethodHashMap{};
                    }
                    try spigotResult.value_ptr.put(allocator, .{ .signature = typeSlice, .name = spigotSlice }, mojSlice);
                } else {
                    // skip methods
                    try readTo(reader, '\n');
                }
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
