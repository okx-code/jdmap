const std = @import("std");
const Mappings = @import("mappings.zig").Mappings;
const Options = @import("options.zig").Options;

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
    mappings: *Mappings,
    options: *Options,
    commands: *std.AutoHashMapUnmanaged(u32, Command),
    classesObf: *std.AutoHashMapUnmanaged([MAX_SIZE]u8, []const u8), // class IDs to obfsucated class names
    fieldRequests: *std.AutoHashMapUnmanaged(u32, [MAX_SIZE]u8), // packet ID to reference type ID
    methodRequests: *std.AutoHashMapUnmanaged(u32, [MAX_SIZE]u8), // packet ID to reference type ID
    fieldIDSize: u8 = 0,
    methodIDSize: u8 = 0,
    objectIDSize: u8 = 0,
    referenceTypeIDSize: u8 = 0,
    frameIDSize: u8 = 0,
    terminate: bool = false,
};

pub fn proxy(jvmStream: std.os.socket_t, proxyStream: std.os.socket_t, proxyReader: anytype, proxyWriter: anytype, jvmReader: anytype, jvmWriter: anytype, mappings: *Mappings, options: *Options, closeables: anytype, allocator: std.mem.Allocator) !void {
    _ = closeables;

    var map = std.AutoHashMapUnmanaged(u32, Command){};
    defer map.deinit(allocator);
    var classesObf = std.AutoHashMapUnmanaged([MAX_SIZE]u8, []const u8){};
    defer classesObf.deinit(allocator);
    var fieldRequests = std.AutoHashMapUnmanaged(u32, [MAX_SIZE]u8){};
    defer fieldRequests.deinit(allocator);
    var methodRequests = std.AutoHashMapUnmanaged(u32, [MAX_SIZE]u8){};
    defer methodRequests.deinit(allocator);
    var ctx: Proxy = .{
        .allocator = allocator,
        .commands = &map,
        .mappings = mappings,
        .options = options,
        .fieldRequests = &fieldRequests,
        .methodRequests = &methodRequests,
        .classesObf = &classesObf,
    };

    if (options.verbose) {
        std.debug.print("verbose: attempting handshake\n", .{});
    }

    try handshake(proxyReader, proxyWriter, jvmReader, jvmWriter);

    std.debug.print("connection established\n", .{});

    const epfd = try std.os.epoll_create1(0);
    var jvmIn: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = jvmStream } };
    try std.os.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, jvmStream, &jvmIn);
    var proxyIn: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = proxyStream } };
    try std.os.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, proxyStream, &proxyIn);

    var events: [10]std.os.linux.epoll_event = undefined;
    var writeBuffer = try std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 4096);
    defer writeBuffer.deinit(ctx.allocator);
    while (true) {
        var eventCount = std.os.epoll_wait(epfd, &events, -1);

        var i: u32 = 0;
        while (i < eventCount) : (i += 1) {
            if (events[i].data.fd == jvmStream) {
                receiveCommandOrReply(&ctx, &writeBuffer, proxyWriter, jvmReader) catch |e| {
                    switch (e) {
                        error.EndOfStream => {
                            std.debug.print("connection to jvm lost\n", .{});
                            return;
                        },
                        else => return e,
                    }
                };
                if (writeBuffer.capacity > 4096) {
                    writeBuffer.clearAndFree(ctx.allocator);
                } else {
                    writeBuffer.clearRetainingCapacity();
                }
            } else if (events[i].data.fd == proxyStream) {
                forwardCommand(&ctx, &writeBuffer, proxyReader, jvmWriter) catch |e| {
                    switch (e) {
                        error.EndOfStream => {
                            std.debug.print("connection to proxy lost\n", .{});
                            return;
                        },
                        else => return e,
                    }
                };
                if (writeBuffer.capacity > 4096) {
                    writeBuffer.clearAndFree(ctx.allocator);
                } else {
                    writeBuffer.clearRetainingCapacity();
                }
            }
        }
    }
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

    if (ctx.options.verbose) {
        //std.debug.print("verbose: recv <- jvm {d} {d} {d}\n", .{ length, id, flags });
    }

    var dataSize: usize = length - 11;
    var buf: [1024]u8 = undefined;

    if (flags & REPLY_FLAG > 0) {
        // reply
        if (ctx.options.verbose) {
            //std.debug.print("verbose: reply {d}\n", .{dataSize});
        }
        const errorCode = try jvmReader.readIntBig(u16);
        try bufferWriter.writeIntBig(u16, errorCode);

        var commandRepliedTo: ?Command = undefined;
        {
            commandRepliedTo = ctx.commands.get(id);
            if (commandRepliedTo == null) {
                // not replying to anything? what is going on
                return ProxyError.InvalidProxy;
            }
            _ = ctx.commands.remove(id);
        }

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
                    .AllClassesWithGeneric, .AllClasses => inner: {
                        const classCount = try jvmReader.readIntBig(u32);
                        try bufferWriter.writeIntBig(u32, classCount);
                        var class: u32 = 0;
                        var string = std.ArrayListUnmanaged(u8){};
                        defer string.deinit(ctx.allocator);
                        while (class < classCount) : (class += 1) {
                            const classKind = try jvmReader.readIntBig(u8);
                            try bufferWriter.writeIntBig(u8, classKind);

                            var refBuf: [MAX_SIZE]u8 = [_]u8{0} ** MAX_SIZE;
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

                            try remapAndWriteClass(ctx.allocator, bufferWriter, signature, &ctx.mappings.spigotToMojMap, ctx.options, refBuf, ctx.classesObf);

                            if (commandType == VirtualMachineCommands.AllClassesWithGeneric) {
                                const genericStringLen: u32 = try jvmReader.readIntBig(u32);
                                try string.ensureTotalCapacity(ctx.allocator, genericStringLen);
                                string.expandToCapacity();
                                try jvmReader.readNoEof(string.items[0..genericStringLen]);
                                try bufferWriter.writeIntBig(u32, genericStringLen);
                                try bufferWriter.writeAll(string.items[0..genericStringLen]);
                            }

                            const status: u32 = try jvmReader.readIntBig(u32);
                            try bufferWriter.writeIntBig(u32, status);
                        }
                        break :inner true;
                    },
                    else => false,
                };
            },
            Command.ReferenceType => |commandType| outer: {
                break :outer switch (commandType) {
                    .FieldsWithGeneric => inner: {
                        const classRef = ctx.fieldRequests.get(id);
                        if (classRef == null) {
                            return ProxyError.InvalidProxy;
                        }
                        _ = ctx.fieldRequests.remove(id);

                        var maxFieldBuf: [MAX_SIZE]u8 = undefined;
                        var fieldBuf = maxFieldBuf[0..ctx.fieldIDSize];

                        try remapFields(ctx, jvmReader, bufferWriter, fieldBuf, classRef.?);

                        break :inner true;
                    },
                    .MethodsWithGeneric => inner: {
                        const classRef = ctx.methodRequests.get(id);
                        if (classRef == null) {
                            return ProxyError.InvalidProxy;
                        }
                        _ = ctx.methodRequests.remove(id);

                        var maxMethodBuf: [MAX_SIZE]u8 = undefined;
                        var methodBuf = maxMethodBuf[0..ctx.methodIDSize];

                        try remapMethods(ctx, jvmReader, bufferWriter, methodBuf, classRef.?);

                        break :inner true;
                    },
                    else => false,
                };
            },
            else => false,
        }) {
            while (dataSize > 0) {
                const read = try jvmReader.read(buf[0..@min(dataSize, buf.len)]);
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

        if (ctx.options.verbose) {
            std.debug.print("verbose: cmd in {d} {d}\n", .{ commandSet, command });
        }

        while (dataSize > 0) {
            const read = try jvmReader.read(buf[0..@min(dataSize, buf.len)]);
            try bufferWriter.writeAll(buf[0..read]);
            dataSize -= read;
        }
    }

    try proxyWriter.writeIntBig(u32, @intCast(u32, writeBuffer.items.len) + 4); // plus four for the length itself
    try proxyWriter.writeAll(writeBuffer.items);
}

fn forwardCommand(ctx: *Proxy, writeBuffer: *std.ArrayListUnmanaged(u8), proxyReader: anytype, jvmWriter: anytype) !void {
    const bufferWriter = writeBuffer.writer(ctx.allocator);

    const length = try proxyReader.readIntBig(u32);

    const id = try proxyReader.readIntBig(u32);
    try bufferWriter.writeIntBig(u32, id);
    const flags = try proxyReader.readIntBig(u8);
    try bufferWriter.writeIntBig(u8, flags);

    if (ctx.options.verbose) {
        //std.debug.print("verbose: send -> jvm {d} {d} {d}\n", .{ length, id, flags });
    }

    var dataSize: usize = length - 11;
    // three 512 byte buffers
    var buf: [1536]u8 = undefined;

    if ((flags & REPLY_FLAG) > 0) {
        return ProxyError.InvalidProxy; // we don't know how to forward replies to the jvm, this is an invalid operation
    } else {
        // command
        const commandSet = try proxyReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, commandSet);
        const command = try proxyReader.readIntBig(u8);
        try bufferWriter.writeIntBig(u8, command);

        var enumType: [:0]const u8 = undefined;
        const commandUnion: ?Command = toCommand(commandSet, command, &enumType);
        if (commandUnion == null) {
            if (ctx.options.verbose) {
                std.debug.print("verbose: invalid command {d} {d}\n", .{ commandSet, command });
            }
            return ProxyError.InvalidProxy;
        }

        if (ctx.options.verbose) {
            std.debug.print("verbose: cmd {d} {d} ({s}.{s})\n", .{ commandSet, command, @tagName(commandUnion.?), enumType });
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
                            if (ctx.options.verbose) {
                                std.debug.print("verbose: mod {d}\n", .{modKind});
                            }
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
                                if (remapped == null) {
                                    for (ctx.options.remapKeys, 0..) |remapKey, rIndex| {
                                        if (std.mem.startsWith(u8, replacedString, remapKey)) {
                                            const value = ctx.options.remapValues[rIndex];
                                            if (replacedString.len + value.len > 512) {
                                                return ProxyError.InvalidProxy;
                                            }
                                            std.mem.copy(u8, buf[1024..1536], value);
                                            std.mem.copy(u8, buf[1024 + value.len .. 1536], replacedString[remapKey.len..]);
                                            remapped = buf[1024 .. 1024 + len - remapKey.len + value.len];
                                            break;
                                        }
                                    }
                                }

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
                                    if (ctx.options.verbose) {
                                        std.debug.print("verbose: out remap {s} -> {s}\n", .{ buf[0..len], remappedReplacedString });
                                    }
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
                                try bufferWriter.writeIntBig(u32, len);
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
                                try bufferWriter.writeIntBig(u32, len);
                                try bufferWriter.writeAll(buf[0..len]);
                            }
                        }

                        break :inner true;
                    },
                    else => false,
                };
            },
            Command.ReferenceType => |commandType| outer: {
                break :outer switch (commandType) {
                    .FieldsWithGeneric => inner: {
                        var maxRefBuf: [MAX_SIZE]u8 = [_]u8{0} ** MAX_SIZE;
                        var refBuf = maxRefBuf[0..ctx.referenceTypeIDSize];
                        try proxyReader.readNoEof(refBuf);
                        try bufferWriter.writeAll(refBuf);

                        try ctx.fieldRequests.put(ctx.allocator, id, maxRefBuf);
                        break :inner true;
                    },
                    .MethodsWithGeneric => inner: {
                        var maxRefBuf: [MAX_SIZE]u8 = [_]u8{0} ** MAX_SIZE;
                        var refBuf = maxRefBuf[0..ctx.referenceTypeIDSize];
                        try proxyReader.readNoEof(refBuf);
                        try bufferWriter.writeAll(refBuf);

                        try ctx.methodRequests.put(ctx.allocator, id, maxRefBuf);
                        break :inner true;
                    },
                    else => false,
                };
            },
            else => false,
        }) {
            while (dataSize > 0) {
                const read = try proxyReader.read(buf[0..@min(dataSize, buf.len)]);
                try bufferWriter.writeAll(buf[0..read]);
                dataSize -= read;
            }
        }
    }

    try jvmWriter.writeIntBig(u32, @intCast(u32, writeBuffer.items.len) + 4); // plus four for the length itself
    try jvmWriter.writeAll(writeBuffer.items);
}

fn remapAndWriteClass(allocator: std.mem.Allocator, proxyWriter: anytype, class: []const u8, spigotToMojMap: *std.StringHashMapUnmanaged([]const u8), options: *Options, refBuf: [MAX_SIZE]u8, classesObf: *std.AutoHashMapUnmanaged([MAX_SIZE]u8, []const u8)) !void {
    var classPtr: ?[]const u8 = null;
    var newSignature = try remapSignature(allocator, options.remapKeys, options.remapValues, spigotToMojMap, class, &classPtr, null);
    defer allocator.free(newSignature);
    if (classPtr) |classValue| {
        try classesObf.put(allocator, refBuf, classValue);
    }

    try proxyWriter.writeIntBig(u32, @intCast(u32, newSignature.len));
    try proxyWriter.writeAll(newSignature);
}

fn remapAndWriteMethodSignature(allocator: std.mem.Allocator, signature: []const u8, spigotToMojMap: *std.StringHashMapUnmanaged([]const u8), options: *Options) ![]u8 {
    if (signature[0] != '(') {
        return ProxyError.InvalidProxy;
    }

    var newMethodSignature = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 64);
    errdefer newMethodSignature.deinit(allocator);

    var writer = newMethodSignature.writer(allocator);
    try writer.writeByte('(');

    const closingBrace = std.mem.indexOfScalarPos(u8, signature, 1, ')') orelse return ProxyError.InvalidProxy;

    if (closingBrace > 1) {
        var pos: u64 = 1;
        while (pos < closingBrace) {
            var posAdd: u64 = 0;
            const newSignature = try remapSignature(allocator, options.remapKeys, options.remapValues, spigotToMojMap, signature[pos..closingBrace], null, &posAdd);
            pos += posAdd;
            defer allocator.free(newSignature);
            try writer.writeAll(newSignature);
        }
    }

    try writer.writeByte(')');

    if (signature[closingBrace + 1] == 'V') {
        try writer.writeByte('V');
    } else {
        const newSignature = try remapSignature(allocator, options.remapKeys, options.remapValues, spigotToMojMap, signature[closingBrace + 1 .. signature.len], null, null);
        defer allocator.free(newSignature);
        try writer.writeAll(newSignature);
    }

    return try newMethodSignature.toOwnedSlice(allocator);
}

fn remapSignature(allocator: std.mem.Allocator, remapKeys: [][]u8, remapValues: [][]u8, spigotToMojMap: *std.StringHashMapUnmanaged([]const u8), signature: []const u8, class: ?*?[]const u8, endPos: ?*u64) ![]u8 {
    var newSignature = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 64);
    errdefer newSignature.deinit(allocator);

    const writer = newSignature.writer(allocator);

    var stream = std.io.fixedBufferStream(signature);
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
            var className = signature[start..end];

            // Warning: Shenanigans to save on memory allocation by reusing the key
            var remappedEntry = spigotToMojMap.getEntry(className);
            var remapped: ?[]const u8 = undefined;
            if (remappedEntry == null) {
                remapped = null;
            } else {
                remapped = remappedEntry.?.value_ptr.*;
            }
            var free = false;
            defer {
                if (free) {
                    allocator.free(remapped.?);
                }
            }
            if (remapped == null) {
                for (remapValues, 0..) |remapKey, rIndex| {
                    if (std.mem.startsWith(u8, className, remapKey)) {
                        const value = remapKeys[rIndex];
                        if (className.len + value.len > 512) {
                            return ProxyError.InvalidProxy;
                        }

                        remapped = try std.mem.replaceOwned(u8, allocator, className, remapKey, value);
                        free = true;
                        break;
                    }
                }
            } else if (class) |classPtr| {
                classPtr.* = remappedEntry.?.key_ptr.*;
            }
            if (remapped != null) {
                try writer.writeAll(remapped.?);
            } else {
                try writer.writeAll(className);
            }

            try writer.writeByte(classByte); // write semicolon
        },
        else => return ProxyError.InvalidProxy,
    }

    if (endPos) |endPtr| {
        endPtr.* = stream.getPos() catch unreachable;
    }
    return try newSignature.toOwnedSlice(allocator);
}

fn remapFields(ctx: *Proxy, jvmReader: anytype, bufferWriter: anytype, buf: []u8, classRef: [MAX_SIZE]u8) !void {
    const declaredFields: u32 = try jvmReader.readIntBig(u32);
    try bufferWriter.writeIntBig(u32, declaredFields);

    var string = std.ArrayListUnmanaged(u8){};
    defer string.deinit(ctx.allocator);

    var index: u32 = 0;

    while (index < declaredFields) : (index += 1) {
        try jvmReader.readNoEof(buf);
        try bufferWriter.writeAll(buf);

        const nameStringLen: u32 = try jvmReader.readIntBig(u32);
        try string.ensureTotalCapacity(ctx.allocator, nameStringLen);
        string.expandToCapacity();
        try jvmReader.readNoEof(string.items[0..nameStringLen]);

        var name: []const u8 = string.items[0..nameStringLen];

        const classNameOpt = ctx.classesObf.get(classRef);
        if (classNameOpt) |className| {
            const fieldsOpt = ctx.mappings.spigotToSpigotFieldsToMojMapFields.get(className);
            if (fieldsOpt) |fields| {
                if (fields.get(name)) |fieldName| {
                    if (ctx.options.verbose) {
                        std.debug.print("verbose: Remap field {s} {s} -> {s}\n", .{ className, name, fieldName });
                    }
                    name = fieldName;
                }
            }
        }

        try bufferWriter.writeIntBig(u32, @intCast(u32, name.len));
        try bufferWriter.writeAll(name);

        // TODO remap signature
        const signatureLen: u32 = try jvmReader.readIntBig(u32);
        try string.ensureTotalCapacity(ctx.allocator, signatureLen);
        string.expandToCapacity();
        try jvmReader.readNoEof(string.items[0..signatureLen]);
        if (ctx.options.verbose) {
            std.debug.print("signature: {s}\n", .{string.items[0..signatureLen]});
        }
        try bufferWriter.writeIntBig(u32, signatureLen);
        try bufferWriter.writeAll(string.items[0..signatureLen]);

        const genericSignatureLen: u32 = try jvmReader.readIntBig(u32);
        try string.ensureTotalCapacity(ctx.allocator, genericSignatureLen);
        string.expandToCapacity();
        try jvmReader.readNoEof(string.items[0..genericSignatureLen]);
        try bufferWriter.writeIntBig(u32, genericSignatureLen);
        try bufferWriter.writeAll(string.items[0..genericSignatureLen]);

        const modBits: u32 = try jvmReader.readIntBig(u32);
        try bufferWriter.writeIntBig(u32, modBits);
    }
}

fn remapMethods(ctx: *Proxy, jvmReader: anytype, bufferWriter: anytype, buf: []u8, classRef: [MAX_SIZE]u8) !void {
    const declaredFields: u32 = try jvmReader.readIntBig(u32);
    try bufferWriter.writeIntBig(u32, declaredFields);

    var string = std.ArrayListUnmanaged(u8){};
    defer string.deinit(ctx.allocator);

    var index: u32 = 0;

    while (index < declaredFields) : (index += 1) {
        try jvmReader.readNoEof(buf);
        try bufferWriter.writeAll(buf);

        const nameStringLen: u32 = try jvmReader.readIntBig(u32);
        try string.ensureTotalCapacity(ctx.allocator, nameStringLen);
        string.expandToCapacity();
        try jvmReader.readNoEof(string.items[0..nameStringLen]);

        const signatureLen: u32 = try jvmReader.readIntBig(u32);
        var signatureStr = try std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, signatureLen);
        defer signatureStr.deinit(ctx.allocator);
        try jvmReader.readNoEof(signatureStr.unusedCapacitySlice()[0..signatureLen]);
        signatureStr.items.len = signatureLen;

        var name: []const u8 = string.items[0..nameStringLen];

        if (ctx.classesObf.get(classRef)) |className| {
            if (ctx.mappings.spigotToSpigotMethodsToMojMapMethods.get(className)) |methods| {
                const signatureRemapped: []u8 = try remapAndWriteMethodSignature(ctx.allocator, signatureStr.items, &ctx.mappings.spigotToMojMap, ctx.options);
                defer ctx.allocator.free(signatureRemapped);
                if (methods.get(.{ .signature = signatureRemapped, .name = name })) |fieldName| {
                    if (ctx.options.verbose) {
                        std.debug.print("verbose: Remap method {s} {s} -> {s} {s}\n", .{ className, name, signatureStr.items, fieldName });
                    }
                    name = fieldName;
                    signatureStr.clearRetainingCapacity();
                    try signatureStr.appendSlice(ctx.allocator, signatureRemapped);
                }
            }
        }

        try bufferWriter.writeIntBig(u32, @intCast(u32, name.len));
        try bufferWriter.writeAll(name);

        try bufferWriter.writeIntBig(u32, @intCast(u32, signatureStr.items.len));
        try bufferWriter.writeAll(signatureStr.items);

        const genericSignatureLen: u32 = try jvmReader.readIntBig(u32);
        try string.ensureTotalCapacity(ctx.allocator, genericSignatureLen);
        string.expandToCapacity();
        try jvmReader.readNoEof(string.items[0..genericSignatureLen]);
        try bufferWriter.writeIntBig(u32, genericSignatureLen);
        try bufferWriter.writeAll(string.items[0..genericSignatureLen]);

        const modBits: u32 = try jvmReader.readIntBig(u32);
        try bufferWriter.writeIntBig(u32, modBits);
    }
}

fn toCommand(commandSet: u8, command: u8, enumType: *[:0]const u8) ?Command {
    return switch (commandSet) {
        @enumToInt(CommandSet.VirtualMachine) => createUnion("VirtualMachine", VirtualMachineCommands, command, enumType),
        @enumToInt(CommandSet.ReferenceType) => createUnion("ReferenceType", ReferenceTypeCommands, command, enumType),
        @enumToInt(CommandSet.ClassType) => createUnion("ClassType", ClassTypeCommands, command, enumType),
        @enumToInt(CommandSet.ArrayType) => createUnion("ArrayType", ArrayTypeCommands, command, enumType),
        @enumToInt(CommandSet.InterfaceType) => createUnion("InterfaceType", InterfaceTypeCommands, command, enumType),
        @enumToInt(CommandSet.Method) => createUnion("Method", MethodCommands, command, enumType),
        @enumToInt(CommandSet.ObjectReference) => createUnion("ObjectReference", ObjectReferenceCommands, command, enumType),
        @enumToInt(CommandSet.StringReference) => createUnion("StringReference", StringReferenceCommands, command, enumType),
        @enumToInt(CommandSet.ThreadReference) => createUnion("ThreadReference", ThreadReferenceCommands, command, enumType),
        @enumToInt(CommandSet.ThreadGroupReference) => createUnion("ThreadGroupReference", ThreadGroupReferenceCommands, command, enumType),
        @enumToInt(CommandSet.ArrayReference) => createUnion("ArrayReference", ArrayReferenceCommands, command, enumType),
        @enumToInt(CommandSet.ClassLoaderReference) => createUnion("ClassLoaderReference", ClassLoaderReferenceCommands, command, enumType),
        @enumToInt(CommandSet.EventRequest) => createUnion("EventRequest", EventRequestCommands, command, enumType),
        @enumToInt(CommandSet.StackFrame) => createUnion("StackFrame", StackFrameCommands, command, enumType),
        @enumToInt(CommandSet.ClassObjectReference) => createUnion("ClassObjectReference", ClassObjectReferenceCommands, command, enumType),
        @enumToInt(CommandSet.ModuleReference) => createUnion("ModuleReference", ModuleReferenceCommands, command, enumType),
        @enumToInt(CommandSet.Event) => createUnion("Event", EventCommands, command, enumType),
        else => null,
    };
}

fn createUnion(comptime name: []const u8, comptime enumType: type, commandValue: anytype, returnEnumType: *[:0]const u8) ?Command {
    inline for (@typeInfo(enumType).Enum.fields) |field| {
        if (field.value == commandValue) {
            returnEnumType.* = @tagName(@intToEnum(enumType, commandValue));
            return @unionInit(Command, name, @intToEnum(enumType, commandValue));
        }
    }
    return null;
}
