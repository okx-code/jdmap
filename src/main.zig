const std = @import("std");
const proxy = @import("proxy.zig").proxy;
const Mappings = @import("mappings.zig").Mappings;

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer gpa.free(args);

    const stderr = std.io.getStdErr().writer();

    if (args.len < 1) {
        try stderr.print("expected program directory in argument list\n", .{});
        std.process.exit(1);
    } else if (args.len < 4) {
        try stderr.print("usage: {s} <source jvm port> <listen proxy port> <mappings file>\n", .{args[0]});
        std.process.exit(1);
    }

    const programArgs = args[1..];

    const jvmPort = std.fmt.parseUnsigned(u16, programArgs[0], 10) catch {
        try stderr.print("unable to parse jvm port \"{s}\"\n", .{programArgs[0]});
        std.process.exit(1);
    };
    const proxyPort = std.fmt.parseUnsigned(u16, programArgs[1], 10) catch {
        try stderr.print("unable to parse proxy port \"{s}\"\n", .{programArgs[1]});
        std.process.exit(1);
    };

    try stderr.print("loading mappings\n", .{});

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
    try stderr.print("waiting for connection on port {d}\n", .{proxyPort});

    if (true) {
        var proxyServer = std.net.StreamServer.init(.{});
        defer proxyServer.deinit();

        try proxyServer.listen(proxyAddress);
        const connection = try proxyServer.accept();
        const proxyStream = connection.stream;
        defer proxyStream.close();
        const proxyReader = proxyStream.reader();
        const proxyWriter = proxyStream.writer();

        try stderr.print("connecting to jvm\n", .{});

        const jvmStream = try std.net.tcpConnectToAddress(jvmAddress);
        defer jvmStream.close();
        const jvmReader = jvmStream.reader();
        const jvmWriter = jvmStream.writer();

        if (true) {
            try proxy(proxyReader, proxyWriter, jvmReader, jvmWriter, &mappings, gpa);
        }
    }
}
