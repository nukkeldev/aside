const std = @import("std");
const LinkFinder = @import("LinkFinder.zig");

// -- Main -- //

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    // ---

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    // ---

    const command = args[1];

    if (std.mem.eql(u8, command, "link-finder") or std.mem.eql(u8, command, "lf")) {
        try linkFinderMain(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.log.err("Unknown command: {s}", .{command});
        printUsage();
        return;
    }
}

fn linkFinderMain(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var recursive: bool = false;
    var recursion_limit: usize = 2;
    var debug: bool = false;
    var url_opt: ?[]const u8 = null;
    var filters = std.ArrayList([]const u8).init(allocator);
    defer filters.deinit();

    // ---

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            debug = true;
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                recursion_limit = try std.fmt.parseInt(usize, args[i], 10);
            } else {
                std.log.err("--limit requires a value", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "-F")) {
            if (i + 1 < args.len) {
                i += 1;
                try filters.append(args[i]);
            } else {
                std.log.err("--filter requires a regex pattern", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printLinkFinderUsage();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            url_opt = arg;
        } else {
            std.log.err("Unknown option for link-finder: {s}", .{arg});
            printLinkFinderUsage();
            return;
        }
    }

    // ---

    if (url_opt == null) {
        std.log.err("URL must be provided", .{});
        printLinkFinderUsage();
        return;
    }

    const url = url_opt.?;

    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        std.log.err("URL must start with http:// or https://", .{});
        return;
    }

    // ---

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_finder = try LinkFinder.init(arena_allocator, debug, filters.items);
    defer link_finder.deinit();

    const entrypoint = LinkFinder.Source{
        .link = url,
        .depth = 0,
    };

    std.log.info("Fetching links from: {s}", .{url});
    if (filters.items.len > 0) {
        std.log.info("Using {} filter(s):", .{filters.items.len});
        for (filters.items, 0..) |filter, idx| {
            std.log.info("  {}: {s}", .{ idx + 1, filter });
        }
    }

    const sources = if (recursive)
        try link_finder.findLinksLeakyRecurse(arena_allocator, entrypoint, recursion_limit)
    else
        try link_finder.findLinksLeaky(arena_allocator, &entrypoint);

    // ---

    if (sources.sources.count() == 0) {
        std.log.info("No links found.", .{});
        return;
    }

    std.log.info("Found {} links:", .{sources.sources.count()});
    var iter = sources.sources.valueIterator();
    var idx: usize = 1;

    while (iter.next()) |source| : (idx += 1) {
        std.log.info("  {}: {f}", .{ idx, source });
    }
}

// -- Test References -- //

test {
    std.testing.log_level = .debug;
    std.testing.refAllDeclsRecursive(LinkFinder);
}

// -- Usage -- //

fn printUsage() void {
    const usage =
        \\Usage: aside <COMMAND> [OPTIONS] [ARGS]
        \\
        \\Available Commands:
        \\  link-finder, lf          Find and filter links in HTML content from remote URLs
        \\
        \\Global Options:
        \\  -h, --help               Show this help message
        \\
        \\Use 'aside <COMMAND> --help' for more information on a command.
        \\
        \\Examples:
        \\  aside lf https://example.com
        \\  aside link-finder --recursive --filter ".*\\.pdf$" https://example.com
        \\  aside --help
        \\
    ;
    std.debug.print(usage, .{});
}

fn printLinkFinderUsage() void {
    const usage =
        \\Usage: aside {{link-finder|lf}} [OPTIONS] <URL>
        \\
        \\Find links in HTML content from remote URLs.
        \\
        \\Options:
        \\  -r, --recursive          Follow links recursively
        \\  -l, --limit <NUM>        Maximum recursion depth (default: 2)
        \\  -F, --filter <PATTERN>   Only follow/extract links matching regex pattern (can be used multiple times)
        \\  -d, --debug              Enable debug output
        \\  -h, --help               Show this help message
        \\
        \\Arguments:
        \\  <URL>                    URL to fetch and analyze (must start with http:// or https://)
        \\
        \\Examples:
        \\  aside lf https://example.com
        \\  aside link-finder --recursive --limit 3 https://example.com
        \\  aside lf --filter ".*\\.pdf$" https://example.com
        \\  aside lf --filter "github\\.com" --filter ".*\\.zip$" --recursive https://example.com
        \\  aside lf --debug --recursive https://example.com
        \\  aside lf --help
        \\
    ;
    std.debug.print(usage, .{});
}
