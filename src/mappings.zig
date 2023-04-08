const std = @import("std");

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

        var startPos: ?usize = null;
        var methods: u32 = 0;
        var fields: u32 = 0;
        while (true) {
            var mapType = reader.readByte() catch break; // don't error, just end of mappings
            if (mapType == 'c') {
                if (startPos != null) {
                    if (fields > 0) {
                        var map = std.StringHashMapUnmanaged([]const u8){};
                        try map.ensureTotalCapacity(allocator, fields);
                        try mappings.spigotToSpigotFieldsToMojMapFields.put(allocator, lastSpigotSlice.?, map);
                    }
                    if (methods > 0) {
                        var map = Mappings.MethodHashMap{};
                        try map.ensureTotalCapacity(allocator, methods);
                        try mappings.spigotToSpigotMethodsToMojMapMethods.put(allocator, lastSpigotSlice.?, map);
                    }
                    stream.pos = startPos.?;
                    startPos = null;
                    continue;
                }

                try expect(reader, '\t');
                const mojClassStart = stream.pos;
                try readTo(reader, '\t');
                const spigotSliceStart = stream.pos;
                const mojSlice = text[mojClassStart .. spigotSliceStart - 1];
                try readTo(reader, '\n');
                const spigotSlice = text[spigotSliceStart .. (stream.pos) - 1];

                try mappings.spigotToMojMap.put(allocator, spigotSlice, mojSlice);
                try mappings.mojMapToSpigot.put(allocator, mojSlice, spigotSlice);

                lastSpigotSlice = spigotSlice;
                lastMojMapSlice = mojSlice;

                startPos = stream.pos;
                methods = 0;
                fields = 0;
            } else if (mapType == '\t' and lastSpigotSlice != null and lastMojMapSlice != null) {
                const classType = reader.readByte() catch break;
                if (startPos != null) {
                    if (classType == 'f') {
                        fields += 1;
                        try readTo(reader, '\n');
                    } else if (classType == 'm') {
                        methods += 1;
                        try readTo(reader, '\n');
                    }
                } else {
                    if (classType == 'f') {
                        try expect(reader, '\t');
                        // skip type
                        try readTo(reader, '\t');

                        const mojClassStart = stream.pos;
                        try readTo(reader, '\t');
                        const spigotSliceStart = stream.pos;
                        const mojSlice = text[mojClassStart .. spigotSliceStart - 1];
                        try readTo(reader, '\n');
                        const spigotSlice = text[spigotSliceStart .. (stream.pos) - 1];

                        var spigotResult = mappings.spigotToSpigotFieldsToMojMapFields.getPtr(lastSpigotSlice.?).?;
                        spigotResult.putAssumeCapacity(spigotSlice, mojSlice);
                    } else if (classType == 'm') {
                        try expect(reader, '\t');
                        const typeStart = stream.pos;

                        try readTo(reader, '\t');
                        const mojClassStart = stream.pos;
                        const typeSlice = text[typeStart .. mojClassStart - 1];

                        try readTo(reader, '\t');
                        const spigotSliceStart = stream.pos;
                        const mojSlice = text[mojClassStart .. spigotSliceStart - 1];

                        try readTo(reader, '\n');
                        const spigotSlice = text[spigotSliceStart .. (stream.pos) - 1];

                        var spigotResult = mappings.spigotToSpigotMethodsToMojMapMethods.getPtr(lastSpigotSlice.?).?;
                        spigotResult.putAssumeCapacity(.{ .signature = typeSlice, .name = spigotSlice }, mojSlice);
                    } else {
                        return error.ParseError;
                    }
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
