const std = @import("std");

const stderr = std.io.getStdErr().writer();

pub const USAGE =
    \\Usage: {s} [OPTION]... <source jvm port> <listen proxy port> <mappings file>
    \\Start a JDWP TCP proxy given the mappings file.
    \\Example: {0s} -v -r 'org/bukkit/craftbukkit:org/bukkit/craftbukkit/v1_19_R1' -x 'org.bukkit.craftbukkit.Main*' 5005 5006 reobf.tiny
    \\
    \\Options:
    \\  -r, --remap      Separated by a colon, remap the first package on the proxy to the second package on the JVM.
    //\\  -x, --exclude    Do not remap the given class(es), overrides other options. May use the * character.
    \\  -v, --verbose    Output details of packets sent and received.
    \\
;

pub const Options = struct {
    verbose: bool = false,
    remapKeys: [][]u8 = undefined,
    remapValues: [][]u8 = undefined,
    exclude: [][]u8 = undefined,
    arguments: [][:0]u8 = undefined,

    pub fn parse(args: [][:0]u8, allocator: std.mem.Allocator) ?Options {
        var remapKeysList = std.ArrayListUnmanaged([]u8){};
        defer remapKeysList.deinit(allocator);
        var remapValuesList = std.ArrayListUnmanaged([]u8){};
        defer remapValuesList.deinit(allocator);
        var excludeList = std.ArrayListUnmanaged([]u8){};
        defer excludeList.deinit(allocator);

        var options: Options = Options{};
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--")) {
                index += 1;
                break;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                options.verbose = true;
                //} else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exclude")) {
                //var exclude = next(args, &index);
                //if (exclude == null) {
                //stderr.print("expected string after flag {s}\n", .{arg}) catch {};
                //return null;
                //}
                //excludeList.append(allocator, exclude.?) catch {};
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--remap")) {
                var remap = next(args, &index);
                if (remap == null) {
                    stderr.print("expected string after flag {s}\n", .{arg}) catch {};
                    return null;
                }

                const colon = std.mem.indexOfScalar(u8, remap.?, ':');
                if (colon == null) {
                    stderr.print("colon not found in remap: {s}\n", .{remap.?}) catch {};
                    return null;
                } else if (colon.? == 0 or colon.? >= remap.?.len - 1) {
                    stderr.print("colon at index {d} at invalid position in: {s}\n", .{ colon, remap.? }) catch {};
                    return null;
                }

                const unmapped = remap.?[0..colon.?];
                const remapped = remap.?[colon.? + 1 ..];

                remapKeysList.append(allocator, unmapped) catch {};
                remapValuesList.append(allocator, remapped) catch {};
            } else {
                break;
            }
        }
        options.arguments = args[index..]; // won't be out of bounds if index + 1 == args.len
        options.remapKeys = remapKeysList.toOwnedSlice(allocator);
        options.remapValues = remapValuesList.toOwnedSlice(allocator);
        options.exclude = excludeList.toOwnedSlice(allocator);
        return options;
    }

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        allocator.free(self.remapKeys);
        allocator.free(self.remapValues);
        allocator.free(self.exclude);
    }

    fn next(args: [][:0]u8, i: *usize) ?[:0]u8 {
        if (i.* + 1 >= args.len) return null;
        if (std.mem.eql(u8, args[i.* + 1], "--")) return null;
        i.* += 1;
        return args[i.*];
    }
};
