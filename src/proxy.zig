const std = @import("std");
const Mappings = @import("mappings.zig").Mappings;

const HANDSHAKE_MAGIC = "JDWP-Handshake";
const REPLY_FLAG: u8 = 0x80;

const MAX_SIZE = 8;

const ProxyError = error{InvalidProxy};

const CommandSet = enum(u8) {
    VirtualMachine = 1,
    ReferenceType = 2,
    ClassType = 3,
    ArrayType = 4,
    InterfaceType = 5,
    Method = 6,
    // 7 not in protocol
    // Field = 8, // in the protocol but with no commands
    ObjectReference = 9,
    StringReference = 10,
    ThreadReference = 11,
    ThreadGroupReference = 12,
    ArrayReference = 13,
    ClassLoaderReference = 14,
    EventRequest = 15,
    StackFrame = 16,
    ClassObjectReference = 17,
    ModuleReference = 18,
    Event = 64,
};

const VirtualMachineCommands = enum(u8) {
    Version = 1,
    ClassesBySignature = 2,
    AllClasses = 3,
    AllThreads = 4,
    TopLevelThreadGroups = 5,
    Dispose = 6,
    IDSizes = 7,
    Suspend = 8,
    Resume = 9,
    Exit = 10,
    CreateString = 11,
    Capabilities = 12,
    ClassPaths = 13,
    DisposeObjects = 14,
    HoldEvents = 15,
    ReleaseEvents = 16,
    CapabilitiesNew = 17,
    RedefineClasses = 18,
    SetDefaultStratum = 19,
    AllClassesWithGeneric = 20,
    InstanceCounts = 21,
    AllModules = 22,
};

const ReferenceTypeCommands = enum(u8) {
    Signature = 1,
    ClassLoader = 2,
    Modifiers = 3,
    Fields = 4,
    Methods = 5,
    GetValues = 6,
    SourceFile = 7,
    NestedTypes = 8,
    Status = 9,
    Interfaces = 10,
    ClassObject = 11,
    SourceDebugExtension = 12,
    SignatureWithGeneric = 13,
    FieldsWithGeneric = 14,
    MethodsWithGeneric = 15,
    Instances = 16,
    ClassFileVersion = 17,
    ConstantPool = 18,
    Module = 19,
};

const ClassTypeCommands = enum(u8) {
    Superclass = 1,
    SetValues = 2,
    InvokeMethod = 3,
    NewInstance = 4,
};

const ArrayTypeCommands = enum(u8) {
    NewInstance = 1,
};

const InterfaceTypeCommands = enum(u8) {
    InvokeMethod = 1,
};

const MethodCommands = enum(u8) {
    LineTable = 1,
    VariableTable = 2,
    Bytecodes = 3,
    IsObsolete = 4,
    VariableTableWithGeneric = 5,
};

const ObjectReferenceCommands = enum(u8) {
    ReferenceType = 1,
    GetValues = 2,
    SetValues = 3,
    // gap!
    MonitorInfo = 5,
    InvokeMethod = 6,
    DisableCollection = 7,
    EnableCollection = 8,
    IsCollected = 9,
    ReferringObjects = 10,
};

const StringReferenceCommands = enum(u8) {
    Value = 1,
};

const ThreadReferenceCommands = enum(u8) {
    Name = 1,
    Suspend = 2,
    Resume = 3,
    Status = 4,
    ThreadGroup = 5,
    Frames = 6,
    FrameCount = 7,
    OwnedMonitors = 8,
    CurrentContendedMonitor = 9,
    Stop = 10,
    Interrupt = 11,
    SuspendCount = 12,
    OwnedMonitorsStackDepthInfo = 13,
    ForceEarlyReturn = 14,
};

const ThreadGroupReferenceCommands = enum(u8) {
    Name = 1,
    Parent = 2,
    Children = 3,
};

const ArrayReferenceCommands = enum(u8) {
    Length = 1,
    GetValues = 2,
    SetValues = 3,
};

const ClassLoaderReferenceCommands = enum(u8) {
    VisibleClasses = 1,
};

const EventRequestCommands = enum(u8) {
    Set = 1,
    Clear = 2,
    ClearAllBreakpoints = 3,
};

const StackFrameCommands = enum(u8) {
    GetValues = 1,
    SetValues = 2,
    ThisObject = 3,
    PopFrames = 4,
};

const ClassObjectReferenceCommands = enum(u8) {
    ReflectedType = 1,
};

const ModuleReferenceCommands = enum(u8) {
    Name = 1,
    ClassLoader = 2,
};

const EventCommands = enum(u8) {
    Composite = 100,
};

const Command = union(CommandSet) {
    VirtualMachine: VirtualMachineCommands,
    ReferenceType: ReferenceTypeCommands,
    ClassType: ClassTypeCommands,
    ArrayType: ArrayTypeCommands,
    InterfaceType: InterfaceTypeCommands,
    Method: MethodCommands,
    ObjectReference: ObjectReferenceCommands,
    StringReference: StringReferenceCommands,
    ThreadReference: ThreadReferenceCommands,
    ThreadGroupReference: ThreadGroupReferenceCommands,
    ArrayReference: ArrayReferenceCommands,
    ClassLoaderReference: ClassLoaderReferenceCommands,
    EventRequest: EventRequestCommands,
    StackFrame: StackFrameCommands,
    ClassObjectReference: ClassObjectReferenceCommands,
    ModuleReference: ModuleReferenceCommands,
    Event: EventCommands,
};

const Proxy = struct {
    allocator: std.mem.Allocator,
    commands: *std.AutoHashMapUnmanaged(u32, Command), // TODO CHECK FOR THREAD SAFETY HERE BECAUSE BOTH THREADS MODIFY THIS.
    mappings: *Mappings,
    fieldIDSize: u8 = 0,
    methodIDSize: u8 = 0,
    objectIDSize: u8 = 0,
    referenceTypeIDSize: u8 = 0,
    frameIDSize: u8 = 0,
    terminate: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
};

const stderr = std.io.getStdErr().writer();

pub fn proxy(proxyReader: anytype, proxyWriter: anytype, jvmReader: anytype, jvmWriter: anytype, mappings: *Mappings, closeables: anytype, allocator: std.mem.Allocator) !void {
    var map = std.AutoHashMapUnmanaged(u32, Command){};
    defer map.deinit(allocator);
    var ctx: Proxy = .{
        .allocator = allocator,
        .commands = &map,
        .mappings = mappings,
    };

    try handshake(proxyReader, proxyWriter, jvmReader, jvmWriter);

    try stderr.print("connection established\n", .{});

    var reset: std.Thread.ResetEvent = undefined;
    try reset.init();
    defer reset.deinit();

    // start two threads, one to receive from the jvm, one to receive from the proxy
    const jvmThread = try std.Thread.spawn(.{}, handleJvmLoop, .{ &reset, &ctx, proxyWriter, jvmReader });
    const proxyThread = try std.Thread.spawn(.{}, handleProxyLoop, .{ &reset, &ctx, proxyReader, jvmWriter });

    reset.wait();
    ctx.terminate.store(true, std.atomic.Ordering.SeqCst);

    // Terminate both threads by closing the connection and causing an error, which is ignored.
    // https://github.com/ziglang/zig/issues/280
    comptime var idx: usize = 0;
    inline while (idx < closeables.len) : (idx += 1) {
        try std.os.shutdown(closeables[idx].handle, std.os.ShutdownHow.both);
    }

    jvmThread.join();
    proxyThread.join();
}

fn handshake(proxyReader: anytype, proxyWriter: anytype, jvmReader: anytype, jvmWriter: anytype) !void {
    if (!(proxyReader.isBytes(HANDSHAKE_MAGIC) catch false)) {
        return ProxyError.InvalidProxy;
    }

    try jvmWriter.writeAll(HANDSHAKE_MAGIC);

    if (!(jvmReader.isBytes(HANDSHAKE_MAGIC) catch false)) {
        return ProxyError.InvalidProxy;
    }

    try proxyWriter.writeAll(HANDSHAKE_MAGIC);
}

fn handleJvmLoop(reset: *std.Thread.ResetEvent, ctx: *Proxy, proxyWriter: std.io.Writer(std.net.Stream, std.os.WriteError, std.net.Stream.write), jvmReader: std.io.Reader(std.net.Stream, std.os.ReadError, std.net.Stream.read)) !void {
    try handleJvmLoop0(reset, ctx, proxyWriter, jvmReader);
}

fn handleJvmLoop0(reset: *std.Thread.ResetEvent, ctx: *Proxy, proxyWriter: anytype, jvmReader: anytype) !void {
    defer reset.set();

    var writeBuffer = std.ArrayListUnmanaged(u8){};
    defer writeBuffer.deinit(ctx.allocator);
    while (true) {
        receiveCommandOrReply(ctx, &writeBuffer, proxyWriter, jvmReader) catch |e| {
            switch (e) {
                error.EndOfStream => {
                    if (ctx.terminate.load(std.atomic.Ordering.SeqCst)) {
                        // connection was closed safely
                        return;
                    } else {
                        try stderr.print("connection to jvm lost\n", .{});
                        return;
                    }
                },
                else => return e,
            }
        };
        writeBuffer.clearRetainingCapacity();
    }
}

fn handleProxyLoop(reset: *std.Thread.ResetEvent, ctx: *Proxy, proxyReader: std.io.Reader(std.net.Stream, std.os.ReadError, std.net.Stream.read), jvmWriter: std.io.Writer(std.net.Stream, std.os.WriteError, std.net.Stream.write)) !void {
    defer reset.set();

    var writeBuffer = std.ArrayListUnmanaged(u8){};
    defer writeBuffer.deinit(ctx.allocator);
    while (true) {
        forwardCommand(ctx, &writeBuffer, proxyReader, jvmWriter) catch |e| {
            switch (e) {
                error.EndOfStream => {
                    if (ctx.terminate.load(std.atomic.Ordering.SeqCst)) {
                        // connection was closed safely
                        return;
                    } else {
                        try stderr.print("connection to proxy lost\n", .{});
                        return;
                    }
                },
                else => return e,
            }
        };

        writeBuffer.clearRetainingCapacity();
    }
}

fn receiveCommandOrReply(ctx: *Proxy, writeBuffer: *std.ArrayListUnmanaged(u8), proxyWriter: anytype, jvmReader: anytype) !void {
    // Create a separate writer as a buffer, which will be flushed once we know the full length
    // We cannot write directly to the TCP stream `proxyWriter` until we know the remapped length.
    // The buffer can be several megabytes as it is used to show all the classes.
    const bufferWriter = writeBuffer.writer(ctx.allocator);
    const length = try jvmReader.readIntBig(u32);

    const id = try jvmReader.readIntBig(u32);
    try bufferWriter.writeIntBig(u32, id);
    const flags = try jvmReader.readIntBig(u8);
    try bufferWriter.writeIntBig(u8, flags);

    //std.log.info("recv <- jvm {d} {d} {d}", .{ length, id, flags });

    var dataSize: usize = length - 11;
    var buf: [1024]u8 = undefined;

    if (flags & REPLY_FLAG > 0) {
        // reply
        //std.log.info("reply {d}", .{dataSize});
        const errorCode = try jvmReader.readIntBig(u16);
        try bufferWriter.writeIntBig(u16, errorCode);

        const commandRepliedTo = ctx.commands.get(id);
        if (commandRepliedTo == null) {
            // not replying to anything? what is going on
            return ProxyError.InvalidProxy;
        }
        _ = ctx.commands.remove(id);

        if (!switch (commandRepliedTo.?) {
            Command.VirtualMachine => |commandType| outer: {
                break :outer switch (commandType) {
                    .IDSizes => inner: {
                        const fieldIDSize = try jvmReader.readIntBig(u32);
                        const methodIDSize = try jvmReader.readIntBig(u32);
                        const objectIDSize = try jvmReader.readIntBig(u32);
                        const referenceTypeIDSize = try jvmReader.readIntBig(u32);
                        const frameIDSize = try jvmReader.readIntBig(u32);

                        if (fieldIDSize > MAX_SIZE or methodIDSize > MAX_SIZE or objectIDSize > MAX_SIZE or referenceTypeIDSize > MAX_SIZE or frameIDSize > MAX_SIZE or fieldIDSize == 0 or methodIDSize == 0 or objectIDSize == 0 or referenceTypeIDSize == 0 or frameIDSize == 0) {
                            // the protocol specifies these can only be up to 8 bytes, and also we use 0 bytes to know that it hasn't been set yet
                            // TODO handle if it is still 0 in .AllClassesWithGeneric
                            return ProxyError.InvalidProxy;
                        }

                        try bufferWriter.writeIntBig(u32, fieldIDSize);
                        try bufferWriter.writeIntBig(u32, methodIDSize);
                        try bufferWriter.writeIntBig(u32, objectIDSize);
                        try bufferWriter.writeIntBig(u32, referenceTypeIDSize);
                        try bufferWriter.writeIntBig(u32, frameIDSize);

                        ctx.fieldIDSize = @intCast(u8, fieldIDSize);
                        ctx.methodIDSize = @intCast(u8, methodIDSize);
                        ctx.objectIDSize = @intCast(u8, objectIDSize);
                        ctx.referenceTypeIDSize = @intCast(u8, referenceTypeIDSize);
                        ctx.frameIDSize = @intCast(u8, frameIDSize);
                        break :inner true;
                    },
                    // TODO Handle .AllClasses as well, although this is not called by IntelliJ
                    .AllClassesWithGeneric => inner: {
                        const classCount = try jvmReader.readIntBig(u32);
                        try bufferWriter.writeIntBig(u32, classCount);
                        var class: u32 = 0;
                        var string = std.ArrayListUnmanaged(u8){};
                        defer string.deinit(ctx.allocator);
                        while (class < classCount) : (class += 1) {
                            const classKind = try jvmReader.readIntBig(u8);
                            try bufferWriter.writeIntBig(u8, classKind);

                            var refBuf: [MAX_SIZE]u8 = undefined;
                            var bufRefType = refBuf[0..ctx.referenceTypeIDSize];
                            try jvmReader.readNoEof(bufRefType);
                            try bufferWriter.writeAll(bufRefType);
                            //const typeID: u64 = std.mem.readVarInt(u64, bufRefType, std.builtin.Endian.Big);

                            const stringLen: u32 = try jvmReader.readIntBig(u32);
                            try string.ensureTotalCapacity(ctx.allocator, stringLen);
                            string.expandToCapacity();
                            try jvmReader.readNoEof(string.items[0..stringLen]);

                            var signature = string.items[0..stringLen];
                            if (signature.len < 2) {
                                return ProxyError.InvalidProxy;
                            }

                            //std.log.info("signature: {s}", .{signature});
                            try remapAndWriteClass(bufferWriter, signature, &ctx.mappings.spigotToMojMap);

                            const genericStringLen: u32 = try jvmReader.readIntBig(u32);
                            try string.ensureTotalCapacity(ctx.allocator, genericStringLen);
                            string.expandToCapacity();
                            try jvmReader.readNoEof(string.items[0..genericStringLen]);
                            //std.log.info("generic signature: {s}", .{string.items[0..genericStringLen]});
                            try bufferWriter.writeIntBig(u32, genericStringLen);
                            try bufferWriter.writeAll(string.items[0..genericStringLen]);

                            const status: u32 = try jvmReader.readIntBig(u32);
                            try bufferWriter.writeIntBig(u32, status);
                        }
                        break :inner true;
                    },
                    else => false,
                };
            },
            else => false,
        }) {
            while (dataSize > 0) {
                const read = try jvmReader.read(buf[0..@minimum(dataSize, buf.len)]);
                try bufferWriter.writeAll(buf[0..read]);
                dataSize -= read;
            }
        }
    } else {
        // command (no reply needed if from jvm)
        const commandSet = try jvmReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, commandSet);
        const command = try jvmReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, command);

        while (dataSize > 0) {
            const read = try jvmReader.read(buf[0..@minimum(dataSize, buf.len)]);
            try bufferWriter.writeAll(buf[0..read]);
            dataSize -= read;
        }
    }

    if (std.math.cast(u32, writeBuffer.items.len)) |len| {
        try proxyWriter.writeIntBig(u32, len + 4); // plus four for the length itself
        try proxyWriter.writeAll(writeBuffer.items);
    } else |_| {
        return ProxyError.InvalidProxy;
    }
}

fn forwardCommand(ctx: *Proxy, writeBuffer: *std.ArrayListUnmanaged(u8), proxyReader: anytype, jvmWriter: anytype) !void {
    const bufferWriter = writeBuffer.writer(ctx.allocator);

    const length = try proxyReader.readIntBig(u32);

    const id = try proxyReader.readIntBig(u32);
    try bufferWriter.writeIntBig(u32, id);
    const flags = try proxyReader.readIntBig(u8);
    try bufferWriter.writeIntBig(u8, flags);

    //std.log.info("send -> jvm {d} {d} {d}", .{ length, id, flags });

    var dataSize: usize = length - 11;
    var buf: [1024]u8 = undefined;

    if ((flags & REPLY_FLAG) > 0) {
        return ProxyError.InvalidProxy; // we don't know how to forward replies to the jvm, this is an invalid operation
    } else {
        // command
        const commandSet = try proxyReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, commandSet);
        const command = try proxyReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, command);

        //std.log.info("cmd {d} {d}", .{ commandSet, command });

        const commandUnion: ?Command = toCommand(commandSet, command);
        if (commandUnion == null) {
            return ProxyError.InvalidProxy;
        }
        try ctx.commands.put(ctx.allocator, id, commandUnion.?);

        if (!switch (commandUnion.?) {
            Command.EventRequest => |commandType| outer: {
                break :outer switch (commandType) {
                    .Set => inner: {
                        const eventKind = try proxyReader.readIntBig(u8);
                        try bufferWriter.writeIntBig(u8, eventKind);

                        const suspendPolicy = try proxyReader.readIntBig(u8);
                        try bufferWriter.writeIntBig(u8, suspendPolicy);

                        const modifiers = try proxyReader.readIntBig(u32);
                        try bufferWriter.writeIntBig(u32, modifiers);

                        var modifierIndex: u32 = 0;
                        while (modifierIndex < modifiers) : (modifierIndex += 1) {
                            const modKind = try proxyReader.readIntBig(u8);
                            try bufferWriter.writeIntBig(u8, modKind);
                            if (modKind == 1) {
                                const count = try proxyReader.readIntBig(u32);
                                try bufferWriter.writeIntBig(u32, count);
                            } else if (modKind == 2) {
                                const exprId = try proxyReader.readIntBig(u32);
                                try bufferWriter.writeIntBig(u32, exprId);
                            } else if (modKind == 3) {
                                var refBuf: [MAX_SIZE]u8 = undefined;
                                var bufRefType = refBuf[0..ctx.objectIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 4) {
                                var refBuf: [MAX_SIZE]u8 = undefined;
                                var bufRefType = refBuf[0..ctx.referenceTypeIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 5) {
                                // Class name
                                const len = try proxyReader.readIntBig(u32);
                                if (len > 512) return ProxyError.InvalidProxy;
                                try proxyReader.readNoEof(buf[0..len]);
                                std.mem.copy(u8, buf[512..1024], buf[0..512]);
                                var replacedString = buf[512 .. 512 + len];
                                var index: usize = 0;
                                while (index < len) : (index += 1) {
                                    if (replacedString[index] == '.') {
                                        replacedString[index] = '/';
                                    }
                                }

                                var remapped = ctx.mappings.mojMapToSpigot.get(replacedString);
                                if (remapped != null) {
                                    if (remapped.?.len > 512) return ProxyError.InvalidProxy;

                                    std.mem.copy(u8, buf[512..1024], remapped.?);
                                    var remappedReplacedString = buf[512 .. 512 + remapped.?.len];
                                    var remappedIndex: usize = 0;
                                    while (remappedIndex < remappedReplacedString.len) : (remappedIndex += 1) {
                                        if (remappedReplacedString[remappedIndex] == '/') {
                                            remappedReplacedString[remappedIndex] = '.';
                                        }
                                    }
                                    std.log.info("out remap {s} -> {s}", .{ replacedString, remappedReplacedString });
                                    try bufferWriter.writeIntBig(u32, @intCast(u32, remappedReplacedString.len));
                                    try bufferWriter.writeAll(remappedReplacedString);
                                } else {
                                    try bufferWriter.writeIntBig(u32, len);
                                    try bufferWriter.writeAll(buf[0..len]);
                                }
                            } else if (modKind == 6) {
                                const len = try proxyReader.readIntBig(u32);
                                if (len > 1024) return ProxyError.InvalidProxy;
                                try proxyReader.readNoEof(buf[0..len]);
                                try bufferWriter.writeAll(buf[0..len]);
                            } else if (modKind == 7) {
                                var refBuf: [9 + MAX_SIZE * 2]u8 = undefined;
                                var bufRefType = refBuf[0 .. 9 + ctx.referenceTypeIDSize + ctx.objectIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 8) {
                                var refBuf: [2 + MAX_SIZE]u8 = undefined;
                                var bufRefType = refBuf[0 .. 2 + ctx.referenceTypeIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 9) {
                                var refBuf: [MAX_SIZE * 2]u8 = undefined;
                                var bufRefType = refBuf[0 .. ctx.referenceTypeIDSize + ctx.fieldIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 10) {
                                var refBuf: [8 + MAX_SIZE]u8 = undefined;
                                var bufRefType = refBuf[0 .. 8 + ctx.referenceTypeIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 11) {
                                var refBuf: [MAX_SIZE]u8 = undefined;
                                var bufRefType = refBuf[0..ctx.objectIDSize];
                                try proxyReader.readNoEof(bufRefType);
                                try bufferWriter.writeAll(bufRefType);
                            } else if (modKind == 12) {
                                const len = try proxyReader.readIntBig(u32);
                                if (len > 1024) return ProxyError.InvalidProxy;
                                try proxyReader.readNoEof(buf[0..len]);
                                try bufferWriter.writeAll(buf[0..len]);
                            }
                        }

                        break :inner true;
                    },
                    else => false,
                };
            },
            else => false,
        }) {
            while (dataSize > 0) {
                const read = try proxyReader.read(buf[0..@minimum(dataSize, buf.len)]);
                if (commandSet == 15 and command == 1) {
                    std.debug.print("{s}\n{any}", .{ buf[0..read], buf[0..read] });
                }
                try bufferWriter.writeAll(buf[0..read]);
                dataSize -= read;
            }
        }
    }
    if (std.math.cast(u32, writeBuffer.items.len)) |len| {
        try jvmWriter.writeIntBig(u32, len + 4); // plus four for the length itself
        try jvmWriter.writeAll(writeBuffer.items);
    } else |_| {
        return ProxyError.InvalidProxy;
    }
}

fn remapAndWriteClass(proxyWriter: anytype, class: []const u8, spigotToMojMap: *std.StringHashMapUnmanaged([]const u8)) !void {
    var buf: [1024]u8 = undefined;
    var out = std.io.fixedBufferStream(&buf);
    const writer = out.writer();

    var stream = std.io.fixedBufferStream(class);
    const reader = stream.reader();
    var byte = try reader.readByte();
    while (byte == '[') { // pass through array
        try writer.writeByte('[');
        byte = try reader.readByte();
    }

    switch (byte) {
        'B', 'C', 'D', 'F', 'I', 'J', 'S', 'Z' => {
            try writer.writeByte(byte);
        },
        'L' => {
            try writer.writeByte(byte);

            const start = stream.getPos() catch unreachable;
            var classByte = try reader.readByte();
            while (classByte != ';') {
                classByte = try reader.readByte();
            }

            const end = (stream.getPos() catch unreachable) - 1;
            var className = class[start..end];

            var remapped = spigotToMojMap.get(className);

            if (remapped != null) {
                try writer.writeAll(remapped.?);
            } else {
                try writer.writeAll(className);
            }

            try writer.writeByte(classByte); // write semicolon
        },
        else => return ProxyError.InvalidProxy,
    }

    try proxyWriter.writeIntBig(u32, @intCast(u32, out.getPos() catch unreachable));
    try proxyWriter.writeAll(out.getWritten());
}

fn toCommand(commandSet: u8, command: u8) ?Command {
    return switch (commandSet) {
        @enumToInt(CommandSet.VirtualMachine) => createUnion("VirtualMachine", VirtualMachineCommands, command),
        @enumToInt(CommandSet.ReferenceType) => createUnion("ReferenceType", ReferenceTypeCommands, command),
        @enumToInt(CommandSet.ClassType) => createUnion("ClassType", ClassTypeCommands, command),
        @enumToInt(CommandSet.ArrayType) => createUnion("ArrayType", ArrayTypeCommands, command),
        @enumToInt(CommandSet.InterfaceType) => createUnion("InterfaceType", InterfaceTypeCommands, command),
        @enumToInt(CommandSet.Method) => createUnion("Method", MethodCommands, command),
        @enumToInt(CommandSet.ObjectReference) => createUnion("ObjectReference", ObjectReferenceCommands, command),
        @enumToInt(CommandSet.StringReference) => createUnion("StringReference", StringReferenceCommands, command),
        @enumToInt(CommandSet.ThreadReference) => createUnion("ThreadReference", ThreadReferenceCommands, command),
        @enumToInt(CommandSet.ThreadGroupReference) => createUnion("ThreadGroupReference", ThreadGroupReferenceCommands, command),
        @enumToInt(CommandSet.ArrayReference) => createUnion("ArrayReference", ArrayReferenceCommands, command),
        @enumToInt(CommandSet.ClassLoaderReference) => createUnion("ClassLoaderReference", ClassLoaderReferenceCommands, command),
        @enumToInt(CommandSet.EventRequest) => createUnion("EventRequest", EventRequestCommands, command),
        @enumToInt(CommandSet.StackFrame) => createUnion("StackFrame", StackFrameCommands, command),
        @enumToInt(CommandSet.ClassObjectReference) => createUnion("ClassObjectReference", ClassObjectReferenceCommands, command),
        @enumToInt(CommandSet.ModuleReference) => createUnion("ModuleReference", ModuleReferenceCommands, command),
        @enumToInt(CommandSet.Event) => createUnion("Event", EventCommands, command),
        else => null,
    };
}

fn createUnion(comptime name: []const u8, enumType: type, commandValue: anytype) ?Command {
    inline for (@typeInfo(enumType).Enum.fields) |field| {
        if (field.value == commandValue) {
            return @unionInit(Command, name, @intToEnum(enumType, commandValue));
        }
    }
    return null;
}
