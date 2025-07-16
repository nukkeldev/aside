const std = @import("std");
const httpz = @import("httpz");

// -- Main -- //

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (!std.mem.eql(u8, command, "link-finder") and !std.mem.eql(u8, command, "lf")) {
        std.log.err("Unknown command: {s}", .{command});
        printUsage();
        return;
    }

    var settings: LinkFinder.Settings = .{};
    var url: ?[]const u8 = null;
    var local_file: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            settings.recurse = true;
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            settings.debug = true;
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                settings.recursion_limit = try std.fmt.parseInt(usize, args[i], 10);
            } else {
                std.log.err("--limit requires a value", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                local_file = args[i];
            } else {
                std.log.err("--file requires a file path", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Assume it's a URL if it doesn't start with -
            url = arg;
        } else {
            std.log.err("Unknown option: {s}", .{arg});
            printUsage();
            return;
        }
    }

    // Validate input
    if (url == null and local_file == null) {
        std.log.err("Either URL or --file must be provided", .{});
        printUsage();
        return;
    }

    if (url != null and local_file != null) {
        std.log.err("Cannot specify both URL and --file", .{});
        printUsage();
        return;
    }

    // Create LinkFinder and process
    const link_finder = LinkFinder.init(settings);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const links = if (url) |u| blk: {
        std.log.info("Fetching links from: {s}", .{u});
        break :blk try link_finder.findLinksRemoteLeaky(arena_allocator, u);
    } else if (local_file) |file_path| blk: {
        std.log.info("Reading links from file: {s}", .{file_path});
        const file_content = try std.fs.cwd().readFileAlloc(arena_allocator, file_path, std.math.maxInt(usize));
        break :blk try link_finder.findLinksLocalLeaky(arena_allocator, file_content, null);
    } else unreachable;

    // Output results
    std.log.info("Found {} links:", .{links.items.len});
    for (links.items, 0..) |link, idx| {
        std.log.info("  {}: {s}", .{ idx + 1, link });
    }
}

// -- Link Finder -- //

pub const LinkFinder = struct {
    settings: Settings,

    // -- Types -- //

    pub const Link = []const u8;
    pub const Settings = struct {
        /// Whether to "recursively" find links (though it's done iteratively).
        recurse: bool = false,
        /// Maximum number of links to follow.
        recursion_limit: usize = 4,
        /// Debug mode, which enables additional logging.
        debug: bool = false,
    };

    // -- Initialization -- //

    /// Initializes a new LinkFinder instance with the given settings.
    pub fn init(settings: Settings) LinkFinder {
        if (settings.debug) std.log.debug("Initializing LinkFinder with: {}", .{settings});

        return LinkFinder{
            .settings = settings,
        };
    }

    // -- Link Finding -- //
    // TODO: Need a `findLinksInFile` or something similar that can traverse sibling files.

    pub fn findLinksRemoteLeaky(
        link_finder: *const LinkFinder,
        hopefully_arena_allocator: std.mem.Allocator,
        url: []const u8,
    ) !std.ArrayList(Link) {
        // NOTE: Explicitly not deinit'd as findLinksLocal doesn't dupe the links.
        const html = try fetchHTML(link_finder, hopefully_arena_allocator, url);

        if (link_finder.settings.debug) std.log.debug("HTML fetched successfully, length: {}", .{html.items.len});

        return link_finder.findLinksLocalLeaky(hopefully_arena_allocator, html.items, url);
    }

    /// Finds links in the provided HTML content.
    /// If `settings.recurse` is true, it _will_ make network requests.
    /// Furthermore, the `url` parameter is required for relative links.
    pub fn findLinksLocalLeaky(
        link_finder: *const LinkFinder,
        allocator: std.mem.Allocator,
        html: []const u8,
        url: ?[]const u8,
    ) !std.ArrayList(Link) {
        const Source = struct {
            depth: usize,
            inner: union(enum) {
                Local: []const u8,
                Remote: []const u8,
            },
        };

        // TODO: Links are currently added without regard for their origin.
        var links = std.ArrayList(Link).init(allocator);

        var sources_queue = std.ArrayList(Source).init(allocator);
        defer sources_queue.deinit();

        try sources_queue.append(.{ .depth = 0, .inner = .{ .Local = html } });

        while (sources_queue.items.len > 0) {
            const source = sources_queue.orderedRemove(0);

            if (source.depth >= link_finder.settings.recursion_limit) {
                if (link_finder.settings.debug) std.log.debug("Reached recursion limit at depth {}.", .{source.depth});
                continue;
            }

            const src, const base_url_opt = switch (source.inner) {
                .Local => |local| .{ local, url },
                .Remote => |remote| .{ (fetchHTML(link_finder, allocator, remote) catch |e| {
                    std.log.err("Failed to retrieve HTML contents due to {}", .{e});
                    continue;
                }).items, remote },
            };

            var steps: usize = 0;
            var offset: usize = 0;
            while (offset < src.len and steps < src.len) : (steps += 1) {
                if (std.mem.indexOf(u8, src[offset..], "<a ")) |tag_start| {
                    offset += tag_start;
                    if (link_finder.settings.debug) std.log.debug("Found <a> tag at offset {}.", .{offset});

                    if (std.mem.indexOf(u8, src[offset..], "href=\"")) |link_start| {
                        offset += link_start + "href=\"".len;
                        if (link_finder.settings.debug) std.log.debug("Found href attribute at offset {}.", .{offset});

                        if (std.mem.indexOf(u8, src[offset..], "\"")) |link_end| {
                            const link = src[offset .. offset + link_end];
                            offset += link_end;

                            if (link_finder.settings.debug) {
                                std.log.debug("Found closing quote for href at offset {}.", .{offset});
                                std.log.debug("Found link from {} to {}: \"{s}\".", .{ offset - link_end, offset, link });
                            }

                            try links.append(link);
                            if (link_finder.settings.recurse) {
                                const is_absolute = std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
                                const is_root_relative = std.mem.startsWith(u8, link, "/");

                                if (is_absolute) {
                                    if (link_finder.settings.debug) std.log.debug("Adding absolute link: {s}", .{link});
                                    try sources_queue.append(.{ .depth = source.depth + 1, .inner = .{ .Remote = link } });
                                } else if (base_url_opt) |base_url| {
                                    if (is_root_relative) {
                                        // Root-relative URL: combine with domain root
                                        const domain_root = extractDomainRoot(base_url);
                                        const full_link = std.fmt.allocPrint(allocator, "{s}{s}", .{ domain_root, link }) catch {
                                            std.log.err("Failed to format root-relative link: {s}", .{link});
                                            return error.OutOfMemory;
                                        };

                                        if (link_finder.settings.debug) std.log.debug("Adding root-relative link: {s}", .{full_link});
                                        try sources_queue.append(.{ .depth = source.depth + 1, .inner = .{ .Remote = full_link } });
                                    } else {
                                        // Path-relative URL: combine with current directory
                                        const last_slash = std.mem.lastIndexOf(u8, base_url, "/") orelse base_url.len;
                                        const base_dir = base_url[0 .. last_slash + 1];
                                        const full_link = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_dir, link }) catch {
                                            std.log.err("Failed to format path-relative link: {s}", .{link});
                                            return error.OutOfMemory;
                                        };

                                        if (link_finder.settings.debug) std.log.debug("Adding path-relative link: {s}", .{full_link});
                                        try sources_queue.append(.{ .depth = source.depth + 1, .inner = .{ .Remote = full_link } });
                                    }
                                } else {
                                    std.log.err("Found link ({s}) but no base URL provided. Skipping recursion.", .{link});
                                }
                            }
                        } else {
                            std.log.err("No closing quote found for href attribute.", .{});
                            continue;
                        }
                    } else {
                        std.log.err("No href attribute found in <a> tag.", .{});
                        continue;
                    }

                    if (std.mem.indexOf(u8, src[offset..], "</a>")) |tag_end| {
                        offset += tag_end + "</a>".len;
                        if (link_finder.settings.debug) {
                            std.log.debug("Found closing </a> tag at offset {}.", .{offset});
                        }
                    } else {
                        std.log.err("No closing tag found for opening <a>.", .{});
                        break;
                    }
                } else {
                    break;
                }
            } else {
                std.log.err("Hit step limit!", .{});
            }
        }

        if (link_finder.settings.debug) std.log.debug("Found {} links!", .{links.items.len});

        return links;
    }

    // -- Helpers -- //

    fn fetchHTML(link_finder: *const LinkFinder, allocator: std.mem.Allocator, url: []const u8) !std.ArrayList(u8) {
        if (link_finder.settings.debug) std.log.debug("Fetching HTML from: {s}", .{url});

        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &response },
        });

        if (result.status != .ok) {
            std.log.err("Failed to fetch \"{s}\". Status: {}", .{ url, result.status });
            return error.BadStatus;
        }

        return response;
    }

    fn extractDomainRoot(url: []const u8) []const u8 {
        // Find the scheme (http:// or https://)
        const scheme_end = if (std.mem.indexOf(u8, url, "://")) |idx| idx + 3 else return url;

        // Find the end of the domain (first '/' after scheme, or end of string)
        const domain_end = if (std.mem.indexOf(u8, url[scheme_end..], "/")) |idx|
            scheme_end + idx
        else
            url.len;

        return url[0..domain_end];
    }

    // -- Tests -- //

    test "fetchHTML" {
        const allocator = std.testing.allocator;
        const url = "https://example.com/";

        const link_finder = LinkFinder.init(.{ .debug = false });
        const response = try link_finder.fetchHTML(allocator, url);
        defer response.deinit();
    }

    test "findLinksLocal" {
        const allocator = std.testing.allocator;
        const html = @embedFile("test/google.html");
        const expected_links: []const []const u8 = &.{
            "https://www.google.com/imghp?hl=en&tab=wi",
            "https://play.google.com/?hl=en&tab=w8",
            "https://www.youtube.com/?tab=w1",
            "https://news.google.com/?tab=wn",
            "https://mail.google.com/mail/?tab=wm",
            "https://drive.google.com/?tab=wo",
            "https://www.google.com/intl/en/about/products?tab=wh",
            "https://accounts.google.com/ServiceLogin?hl=en&passive=true&continue=https://www.google.com/&ec=GAZAAQ",
            "/intl/en/ads/",
            "/intl/en/about.html",
            "/intl/en/policies/privacy/",
        };

        const link_finder = LinkFinder.init(.{ .debug = false });
        const links = try link_finder.findLinksLocalLeaky(allocator, html, "https://google.com/");
        defer links.deinit();

        try std.testing.expectEqual(expected_links.len, links.items.len);
        for (links.items, expected_links) |found, expected| {
            try std.testing.expectEqualStrings(expected, found);
        }
    }

    test "findLinksRemoteLeaky" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        const expected_links: []const []const u8 = &.{"https://www.iana.org/domains/example"};

        const link_finder = LinkFinder.init(.{ .debug = false });
        const links = try link_finder.findLinksRemoteLeaky(allocator, "https://example.com/");
        defer links.deinit();

        try std.testing.expectEqual(expected_links.len, links.items.len);
        for (links.items, expected_links) |found, expected| {
            try std.testing.expectEqualStrings(expected, found);
        }
    }

    test "findLinksRemoteLeaky[recursive]" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        const expected_links: usize = 1 + 28;

        const link_finder = LinkFinder.init(.{ .debug = true, .recurse = true, .recursion_limit = 2 });
        const links = try link_finder.findLinksRemoteLeaky(allocator, "https://example.com/");
        defer links.deinit();

        try std.testing.expectEqual(expected_links, links.items.len);
    }
};

// -- Test References -- //

test {
    std.testing.log_level = .debug;
    std.testing.refAllDecls(LinkFinder);
}

// -- Usage -- //

fn printUsage() void {
    const usage =
        \\Usage: aside {{link-finder|lf}} [OPTIONS] [URL]
        \\
        \\Find links in HTML content from URLs or local files.
        \\
        \\Options:
        \\  -r, --recursive          Follow links recursively
        \\  -l, --limit <NUM>        Maximum recursion depth (default: 4)
        \\  -f, --file <PATH>        Read from local HTML file instead of URL
        \\  -d, --debug              Enable debug output
        \\  -h, --help               Show this help message
        \\
        \\Examples:
        \\  aside lf https://example.com
        \\  aside link-finder --recursive --limit 2 https://example.com
        \\  aside lf --file index.html
        \\  aside lf --debug --recursive https://example.com
        \\  aside lf --help
        \\
    ;
    std.debug.print(usage, .{});
}
