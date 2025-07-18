const std = @import("std");
const httpz = @import("httpz");

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

    const link_finder = LinkFinder.init(debug);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const entrypoint = LinkFinder.Source{
        .link = url,
        .depth = 0,
    };

    std.log.info("Fetching links from: {s}", .{url});
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

// -- Link Finder -- //

pub const LinkFinder = struct {
    debug: bool,

    // -- Types -- //

    pub const Source = struct {
        parent: ?[]const u8 = null,
        // children: ?[]*const Source = null,

        depth: usize = 0,
        link: []const u8,

        pub fn format(source: *const Source, writer: *std.io.Writer) std.io.Writer.Error!void {
            try writer.print("Source(url: {s}, depth: {})", .{ source.link, source.depth });
        }

        pub fn dupe(self: *const Source, allocator: std.mem.Allocator) !Source {
            return Source{
                .parent = if (self.parent) |p| try allocator.dupe(u8, p) else null,
                .depth = self.depth,
                .link = try allocator.dupe(u8, self.link),
            };
        }
    };

    pub const Sources = struct {
        sources: std.StringHashMap(Source),

        // ---

        pub fn init(allocator: std.mem.Allocator) Sources {
            return Sources{
                .sources = std.StringHashMap(Source).init(allocator),
            };
        }

        pub fn deinit(self: *Sources) void {
            self.sources.deinit();
        }
    };

    // -- Initialization -- //

    pub fn init(debug: bool) LinkFinder {
        return LinkFinder{ .debug = debug };
    }

    // -- Link Finding -- //

    pub fn findLinksLeakyRecurse(
        lf: *const LinkFinder,
        allocator: std.mem.Allocator,
        entrypoint: Source,
        limit: usize,
    ) !Sources {
        var sources_queue = std.ArrayList([]const u8).init(allocator);
        defer sources_queue.deinit();

        var sources = Sources.init(allocator);
        var first = true;

        while (first or sources_queue.items.len > 0) {
            if (lf.debug) {
                std.log.debug("Queue:", .{});
                for (sources_queue.items) |item| {
                    std.log.debug("  - {s}", .{item});
                }
            }

            const source = if (first) entrypoint else sources.sources.get(sources_queue.orderedRemove(0)) orelse unreachable;
            first = false;

            if (lf.debug) std.log.debug("Processing source: {f}", .{source});

            var found_links = try lf.findLinksLeaky(allocator, &source);
            if (lf.debug) std.log.debug("Found {} links in source: {f}", .{ found_links.sources.count(), source });

            var iter = found_links.sources.iterator();
            while (iter.next()) |entry| {
                if (!sources.sources.contains(entry.key_ptr.*)) {
                    try sources.sources.put(try sources.sources.allocator.dupe(u8, entry.key_ptr.*), try entry.value_ptr.dupe(sources.sources.allocator));
                    if (entry.value_ptr.depth >= limit) {
                        if (lf.debug) std.log.debug("Skipping source {s} due to depth limit.", .{entry.key_ptr.*});
                        continue;
                    }
                    if (lf.debug) std.log.debug("Adding new source to queue: {s}", .{entry.key_ptr.*});
                    try sources_queue.append(try sources.sources.allocator.dupe(u8, entry.key_ptr.*));
                } else {
                    std.log.warn("TODO: Merge children", .{});
                }
            }
            found_links.deinit();

            if (lf.debug) std.log.debug("Merged into sources for a total of {} links.", .{sources.sources.count()});
        }

        return sources;
    }

    /// Finds links in the provided HTML source.
    /// TODO: Move recursion into a seperate function, make this one only return the sources on the supplied entrypoint.
    pub fn findLinksLeaky(
        lf: *const LinkFinder,
        allocator: std.mem.Allocator,
        source: *const Source,
    ) !Sources {
        var sources = Sources.init(allocator);
        if (lf.debug) std.log.debug("Finding links for entrypoint: {f}", .{source});

        const src = (fetchHTML(lf, allocator, source.link) catch |e| {
            std.log.err("Failed to retrieve HTML contents due to {}, skipping.", .{e});
            return sources;
        }).items;

        var steps: usize = 0;
        var offset: usize = 0;
        while (offset < src.len and steps < src.len) : (steps += 1) {
            if (std.mem.indexOf(u8, src[offset..], "<a ")) |tag_start| {
                offset += tag_start;
                if (lf.debug) std.log.debug("Found <a> tag at offset {}.", .{offset});

                if (std.mem.indexOf(u8, src[offset..], "href=\"")) |link_start| {
                    offset += link_start + "href=\"".len;
                    if (lf.debug) std.log.debug("Found href attribute at offset {}.", .{offset});

                    if (std.mem.indexOf(u8, src[offset..], "\"")) |link_end| {
                        const link = src[offset .. offset + link_end];
                        offset += link_end;

                        if (lf.debug) {
                            std.log.debug("Found closing quote for href at offset {}.", .{offset});
                            std.log.debug("Found link from {} to {}: \"{s}\".", .{ offset - link_end, offset, link });
                        }

                        try sources.sources.put(link, .{
                            .depth = source.depth + 1,
                            .link = outer: {
                                const is_absolute = std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
                                const is_root_relative = std.mem.startsWith(u8, link, "/");

                                if (is_absolute) {
                                    if (lf.debug) std.log.debug("Adding absolute link: {s}", .{link});
                                    break :outer link;
                                } else {
                                    if (is_root_relative) {
                                        // Root-relative URL: combine with domain root
                                        const domain_root = extractDomainRoot(source.link);
                                        const full_link = try std.fmt.allocPrint(allocator, "{s}{s}", .{ domain_root, link });

                                        if (lf.debug) std.log.debug("Adding root-relative link: {s}", .{full_link});
                                        break :outer full_link;
                                    } else {
                                        // Path-relative URL: combine with current directory
                                        const last_slash = std.mem.lastIndexOf(u8, source.link, "/") orelse source.link.len;
                                        const base_dir = source.link[0 .. last_slash + 1];
                                        const full_link = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_dir, link });

                                        if (lf.debug) std.log.debug("Adding path-relative link: {s}", .{full_link});
                                        break :outer full_link;
                                    }
                                }
                            },
                            .parent = source.link,
                        });
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
                    if (lf.debug) {
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

        if (lf.debug) {
            std.log.debug("Found {} links:", .{sources.sources.count()});
            var iter = sources.sources.valueIterator();
            var idx: usize = 1;
            while (iter.next()) |entry| : (idx += 1) {
                std.log.debug("  {}: {f}", .{ idx, entry });
            }
        }

        return sources;
    }

    // -- Helpers -- //

    fn fetchHTML(link_finder: *const LinkFinder, allocator: std.mem.Allocator, url: []const u8) !std.ArrayList(u8) {
        if (link_finder.debug) std.log.debug("Fetching HTML from: {s}", .{url});

        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const start_time = std.time.milliTimestamp();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &response },
        });
        if (link_finder.debug) std.log.debug("Fetched {s} in {} ms", .{ url, std.time.milliTimestamp() - start_time });

        if (result.status != .ok) {
            std.log.err("Failed to fetch \"{s}\". Status: {}", .{ url, result.status });
            return error.BadStatus;
        }

        return response;
    }

    test "fetchHTML" {
        const allocator = std.testing.allocator;
        const url = "https://example.com/";

        const link_finder = LinkFinder.init(false);
        const response = try link_finder.fetchHTML(allocator, url);
        defer response.deinit();
    }

    fn cleanLink(allocator: std.mem.Allocator, link: []const u8) ![]const u8 {
        var cleaned = std.mem.trim(u8, link, &std.ascii.whitespace);

        cleaned = std.mem.trimRight(u8, cleaned, &.{ '/', '\\' });

        if (!std.mem.startsWith(u8, cleaned, "http://") and !std.mem.startsWith(u8, cleaned, "https://")) {
            cleaned = try std.fmt.allocPrint(allocator, "https://{s}", .{cleaned});
        }

        return cleaned;
    }

    test "cleanLink" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "example.com"));
        try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, " https://example.com "));
        try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "https://example.com/"));
    }

    fn extractDomainRoot(url: []const u8) []const u8 {
        const scheme_end = if (std.mem.indexOf(u8, url, "://")) |idx| idx + 3 else return url;
        const domain_end = if (std.mem.indexOf(u8, url[scheme_end..], "/")) |idx|
            scheme_end + idx
        else
            url.len;

        return url[0..domain_end];
    }

    test "extractDomainRoot" {
        try std.testing.expectEqualStrings(
            "https://example.com",
            extractDomainRoot("https://example.com/path/to/resource"),
        );
    }

    // -- Tests -- //
    // TODO: Update tests

    // test "findLinksLocal" {
    //     const allocator = std.testing.allocator;
    //     const html = @embedFile("test/google.html");
    //     const expected_links: []const []const u8 = &.{
    //         "https://www.google.com/imghp?hl=en&tab=wi",
    //         "https://play.google.com/?hl=en&tab=w8",
    //         "https://www.youtube.com/?tab=w1",
    //         "https://news.google.com/?tab=wn",
    //         "https://mail.google.com/mail/?tab=wm",
    //         "https://drive.google.com/?tab=wo",
    //         "https://www.google.com/intl/en/about/products?tab=wh",
    //         "https://accounts.google.com/ServiceLogin?hl=en&passive=true&continue=https://www.google.com/&ec=GAZAAQ",
    //         "/intl/en/ads/",
    //         "/intl/en/about.html",
    //         "/intl/en/policies/privacy/",
    //     };

    //     const link_finder = LinkFinder.init(false);
    //     const links = try link_finder.findLinksLeaky(allocator, html, "https://google.com/");
    //     defer links.deinit();

    //     try std.testing.expectEqual(expected_links.len, links.items.len);
    //     for (links.items, expected_links) |found, expected| {
    //         try std.testing.expectEqualStrings(expected, found);
    //     }
    // }

    // test "findLinksRemoteLeaky" {
    //     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    //     defer arena.deinit();

    //     const allocator = arena.allocator();
    //     const expected_links: []const []const u8 = &.{"https://www.iana.org/domains/example"};

    //     const link_finder = LinkFinder.init(false);
    //     const links = try link_finder.findLinksRemoteLeaky(allocator, "https://example.com/");
    //     defer links.deinit();

    //     try std.testing.expectEqual(expected_links.len, links.items.len);
    //     for (links.items, expected_links) |found, expected| {
    //         try std.testing.expectEqualStrings(expected, found);
    //     }
    // }

    // test "findLinksRemoteLeaky[recursive]" {
    //     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    //     defer arena.deinit();

    //     const allocator = arena.allocator();
    //     const expected_links: usize = 1 + 28;

    //     const link_finder = LinkFinder.init(true);
    //     const links = try link_finder.findLinksLeakyRecurse(allocator, "https://example.com/", 2);
    //     defer links.deinit();

    //     try std.testing.expectEqual(expected_links, links.items.len);
    // }
};

// -- Test References -- //

test {
    std.testing.log_level = .debug;
    std.testing.refAllDecls(LinkFinder);
}

// -- Usage -- //

fn printUsage() void {
    const usage =
        \\Usage: aside <COMMAND> [OPTIONS] [ARGS]
        \\
        \\Available Commands:
        \\  link-finder, lf          Find links in HTML content from remote URLs
        \\
        \\Global Options:
        \\  -h, --help               Show this help message
        \\
        \\Use 'aside <COMMAND> --help' for more information on a command.
        \\
        \\Examples:
        \\  aside lf https://example.com
        \\  aside link-finder --recursive --limit 3 https://example.com
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
        \\  -d, --debug              Enable debug output
        \\  -h, --help               Show this help message
        \\
        \\Arguments:
        \\  <URL>                    URL to fetch and analyze (must start with http:// or https://)
        \\
        \\Examples:
        \\  aside lf https://example.com
        \\  aside link-finder --recursive --limit 3 https://example.com
        \\  aside lf --debug --recursive https://example.com
        \\  aside lf --help
        \\
    ;
    std.debug.print(usage, .{});
}
