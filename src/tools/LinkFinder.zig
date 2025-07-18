const std = @import("std");
const mvzr = @import("mvzr");

// ---

const LinkFinder = @This();

// -- Fields -- //

debug: bool,
filters: []mvzr.Regex,
allocator: std.mem.Allocator,

// -- Types -- //

pub const Source = struct {
    parent: ?[]const u8 = null,
    // children: ?[]*const Source = null,

    depth: usize = 0,
    link: []const u8,

    // ---

    pub fn format(value: *const Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Source(url: {s}, depth: {})", .{ value.link, value.depth });
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

pub fn init(allocator: std.mem.Allocator, debug: bool, filter_patterns: []const []const u8) !LinkFinder {
    var filters = try allocator.alloc(mvzr.Regex, filter_patterns.len);

    var i: usize = 0;
    for (filter_patterns) |pattern| {
        filters[i] = mvzr.Regex.compile(pattern) orelse {
            std.log.err("Failed to compiled regex pattern '{s}'! Skipping.", .{pattern});
            continue;
        };
        i += 1;
    }

    return LinkFinder{
        .debug = debug,
        .filters = filters[0..i],
        .allocator = allocator,
    };
}

pub fn deinit(self: *const LinkFinder) void {
    self.allocator.free(self.filters);
}

// -- Link Finding -- //

fn matchesFilter(self: *const LinkFinder, link: []const u8) bool {
    if (self.filters.len == 0) return true;

    for (self.filters) |*regex| {
        if (regex.match(link)) |match| {
            if (self.debug) std.log.debug("Link '{s}' matches filter at {}.", .{ link, match });
            return true;
        }
    }

    if (self.debug) std.log.debug("Link '{s}' does not match any filter", .{link});
    return false;
}

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

                    const final_link = outer: {
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
                    };

                    // Only add the link if it matches our filters
                    if (lf.matchesFilter(final_link)) {
                        try sources.sources.put(final_link, .{
                            .depth = source.depth + 1,
                            .link = final_link,
                            .parent = source.link,
                        });
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

fn cleanLink(allocator: std.mem.Allocator, link: []const u8) ![]const u8 {
    var cleaned = std.mem.trim(u8, link, &std.ascii.whitespace);

    cleaned = std.mem.trimRight(u8, cleaned, &.{ '/', '\\' });

    if (!std.mem.startsWith(u8, cleaned, "http://") and !std.mem.startsWith(u8, cleaned, "https://")) {
        cleaned = try std.fmt.allocPrint(allocator, "https://{s}", .{cleaned});
    }

    return cleaned;
}

fn extractDomainRoot(url: []const u8) []const u8 {
    const scheme_end = if (std.mem.indexOf(u8, url, "://")) |idx| idx + 3 else return url;
    const domain_end = if (std.mem.indexOf(u8, url[scheme_end..], "/")) |idx|
        scheme_end + idx
    else
        url.len;

    return url[0..domain_end];
}

// -- Tests -- //

test "cleanLink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "example.com"));
    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, " https://example.com "));
    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "https://example.com/"));
}

test "extractDomainRoot" {
    try std.testing.expectEqualStrings(
        "https://example.com",
        extractDomainRoot("https://example.com/path/to/resource"),
    );
}

test "fetchHTML" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/";

    const link_finder = try LinkFinder.init(allocator, false, &.{});
    defer link_finder.deinit();
    const response = try link_finder.fetchHTML(allocator, url);
    defer response.deinit();
}

test "findLinksLeaky" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a LinkFinder with no filters
    const link_finder = try LinkFinder.init(allocator, false, &.{});
    defer link_finder.deinit();

    // Create a test source
    const source = Source{
        .link = "https://example.com/",
        .depth = 0,
    };

    const sources = try link_finder.findLinksLeaky(allocator, &source);

    const expected_links = [_][]const u8{
        "https://www.iana.org/domains/example",
    };

    try std.testing.expectEqual(expected_links.len, sources.sources.count());

    for (expected_links) |expected_link| {
        try std.testing.expect(sources.sources.contains(expected_link));
    }
}

test "findLinksLeakyWithFilter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a LinkFinder with a filter for IANA links
    const filters = [_][]const u8{".*iana\\.org.*"};
    const link_finder = try LinkFinder.init(allocator, false, &filters);
    defer link_finder.deinit();

    // Create a test source
    const source = Source{
        .link = "https://example.com/",
        .depth = 0,
    };

    const sources = try link_finder.findLinksLeaky(allocator, &source);

    const expected_filtered_links = [_][]const u8{
        "https://www.iana.org/domains/example",
    };

    try std.testing.expectEqual(expected_filtered_links.len, sources.sources.count());

    for (expected_filtered_links) |expected_link| {
        try std.testing.expect(sources.sources.contains(expected_link));
        try std.testing.expect(link_finder.matchesFilter(expected_link));
    }
}

test "matchesFilter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with no filters (should match everything)
    {
        const link_finder = try LinkFinder.init(allocator, false, &.{});
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://example.com"));
        try std.testing.expect(link_finder.matchesFilter("https://github.com/test.zip"));
    }

    // Test with PDF filter
    {
        const filters = [_][]const u8{".*\\.pdf$"};
        const link_finder = try LinkFinder.init(allocator, false, &filters);
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://example.com/document.pdf"));
        try std.testing.expect(!link_finder.matchesFilter("https://example.com/page.html"));
    }

    // Test with multiple filters
    {
        const filters = [_][]const u8{ ".*github\\.com.*", ".*\\.zip$" };
        const link_finder = try LinkFinder.init(allocator, false, &filters);
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://github.com/user/repo"));
        try std.testing.expect(link_finder.matchesFilter("https://example.com/file.zip"));
        try std.testing.expect(!link_finder.matchesFilter("https://example.com/page.html"));
    }
}
