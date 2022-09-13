const std = @import("std");
const proxy = @import("proxy.zig").proxy;
const Mappings = @import("mappings.zig").Mappings;
const options = @import("options.zig");

const stderr = std.io.getStdErr().writer();

var globalStop: ?std.Thread.ResetEvent = null;

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

    // open read only
    const mappingsFile = try std.fs.cwd().openFile(programArgs[2], .{});
    defer mappingsFile.close();

    const mappingsText = try mappingsFile.readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(mappingsText);

    const jvmAddress = std.net.Address.resolveIp("127.0.0.1", jvmPort) catch unreachable;
    const proxyAddress = std.net.Address.resolveIp("127.0.0.1", proxyPort) catch unreachable;

    // this does not copy strings and just points to the mappings text, so the lifetime needs to be managed carefully.
    var mappings = try Mappings.parseMappings(mappingsText, gpa);
    defer mappings.deinit(gpa);

    // we don't need to handle multiple connections because JDWP doesn't work with multiple connections
    stderr.print("waiting for connection on port {d}\n", .{proxyPort}) catch {};

    var proxyServer = std.net.StreamServer.init(.{});
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

    var reset: std.Thread.ResetEvent = undefined;
    try reset.init();
    defer reset.deinit();

    globalStop = reset;

    if (@import("builtin").os.tag == .linux) {
        const handler: std.os.Sigaction = .{
            .handler = .{ .handler = stopEventLoop },
            .mask = std.os.empty_sigset,
            .flags = 0,
        };
        std.os.sigaction(std.os.SIG.INT, &handler, null);
        std.os.sigaction(std.os.SIG.TERM, &handler, null);
    }

    try proxy(proxyReader, proxyWriter, jvmReader, jvmWriter, &mappings, &opts.?, .{ &jvmStream, &proxyStream }, &globalStop.?, gpa);
}

export fn stopEventLoop(_: c_int) void {
    if (globalStop != null) {
        globalStop.?.set();
    }
}
