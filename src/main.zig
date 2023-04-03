const std = @import("std");
const proxy = @import("proxy.zig").proxy;
const Mappings = @import("mappings.zig").Mappings;
const options = @import("options.zig");

const stderr = std.io.getStdErr().writer();

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer gpa.free(args);

    if (args.len < 1) {
        stderr.print("expected program directory in argument list\n", .{}) catch {};
        std.process.exit(1);
    }

    var opts = options.Options.parse(args[1..], gpa);
    if (opts == null) {
        // error message was already printed
        std.process.exit(1);
    }
    defer opts.?.deinit(gpa);
    const programArgs = opts.?.arguments;
    if (programArgs.len < 3) {
        stderr.print(options.USAGE, .{args[0]}) catch {};
        std.process.exit(1);
    }

    const jvmPort = std.fmt.parseUnsigned(u16, programArgs[0], 10) catch {
        stderr.print("unable to parse jvm port: {s}\n", .{programArgs[0]}) catch {};
        std.process.exit(1);
    };
    const proxyPort = std.fmt.parseUnsigned(u16, programArgs[1], 10) catch {
        stderr.print("unable to parse proxy port: {s}\n", .{programArgs[1]}) catch {};
        std.process.exit(1);
    };

    stderr.print("loading mappings\n", .{}) catch {};

    const start: i64 = std.time.milliTimestamp();

    var mappingsText: []align(4096) const u8 = undefined;

    const mappingsFile = try std.fs.cwd().openFile(programArgs[2], .{});
    defer mappingsFile.close();

    const stat = try std.os.fstat(mappingsFile.handle);
    mappingsText = try std.os.mmap(null, @intCast(usize, stat.size), std.os.linux.PROT.READ, std.os.linux.MAP.PRIVATE, mappingsFile.handle, 0);

    defer std.os.munmap(mappingsText);

    // this does not copy strings and just points to the mappings text, so the lifetime needs to be managed carefully.
    var mappings = try Mappings.parseMappings(mappingsText, gpa);
    defer mappings.deinit(gpa);

    const end: i64 = std.time.milliTimestamp();

    if (opts.?.verbose) {
        stderr.print("verbose: loading mappings took {d} ms\n", .{end - start}) catch {};
    }

    stderr.print("waiting for connection on port {d}\n", .{proxyPort}) catch {};

    const jvmAddress = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, jvmPort);
    const proxyAddress = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, proxyPort);

    var proxyServer = std.net.StreamServer.init(.{ .reuse_address = true });
    defer proxyServer.deinit();

    try proxyServer.listen(proxyAddress);

    const connection = try proxyServer.accept();
    const proxyStream = connection.stream;
    errdefer proxyStream.close();
    const proxyReader = proxyStream.reader();
    const proxyWriter = proxyStream.writer();

    stderr.print("connecting to jvm\n", .{}) catch {};

    const jvmStream = try std.net.tcpConnectToAddress(jvmAddress);
    errdefer jvmStream.close();
    const jvmReader = jvmStream.reader();
    const jvmWriter = jvmStream.writer();

    var val: i32 = 1;
    _ = std.os.linux.setsockopt(jvmStream.handle, std.os.linux.IPPROTO.TCP, std.os.linux.TCP.NODELAY, @ptrCast([*]u8, &val), @sizeOf(i32));
    _ = std.os.linux.setsockopt(proxyStream.handle, std.os.linux.IPPROTO.TCP, std.os.linux.TCP.NODELAY, @ptrCast([*]u8, &val), @sizeOf(i32));

    try proxy(jvmStream.handle, proxyStream.handle, proxyReader, proxyWriter, jvmReader, jvmWriter, &mappings, &opts.?, .{ &jvmStream, &proxyStream }, gpa);
}
