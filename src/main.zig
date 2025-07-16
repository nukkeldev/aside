const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // More advance cases will use a custom "Handler" instead of "void".
    // The last parameter is our handler instance, since we have a "void"
    // handler, we passed a void ({}) value.
    var server = try httpz.Server(void).init(allocator, .{ .port = 5882 }, {});
    defer {
        // clean shutdown, finishes serving any live request
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/api/user/:id", getUser, .{});

    // blocks
    try server.listen();
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    try res.json(.{ .id = req.param("id").?, .name = "Teg" }, .{});
}

// -- Link Finder -- //

pub const LinkFinder = struct {
    settings: Settings,

    pub const Link = struct {
        /// The URL found in the HTML content.
        url: []const u8,
        /// The URL being parsed.
        is_relative_to: ?[]const u8 = null,
    };
    pub const Settings = struct {
        /// Whether to "recursively" find links (though it's done iteratively).
        recurse: bool = false,
        /// Debug mode, which enables additional logging.
        debug: bool = false,
    };

    /// Initializes a new LinkFinder instance with the given settings.
    pub fn init(settings: Settings) LinkFinder {
        if (settings.debug) std.log.debug("Initializing LinkFinder with: {}", .{settings});

        return LinkFinder{
            .settings = settings,
        };
    }

    /// Finds links in the provided HTML content.
    /// Totally super accurate and reliable, not at all a placeholder.
    pub fn findLinks(link_finder: LinkFinder, allocator: std.mem.Allocator, html: []const u8) !std.ArrayList(Link) {
        var links = std.ArrayList(Link).init(allocator);

        var steps: usize = 0;
        var offset: usize = 0;
        while (offset < html.len and steps < html.len) : (steps += 1) {
            if (std.mem.indexOf(u8, html[offset..], "<a ")) |tag_start| {
                offset += tag_start;
                if (link_finder.settings.debug) std.log.debug("Found <a> tag at offset {}.", .{offset});

                if (std.mem.indexOf(u8, html[offset..], "href=\"")) |link_start| {
                    offset += link_start + "href=\"".len;
                    if (link_finder.settings.debug) std.log.debug("Found href attribute at offset {}.", .{offset});

                    if (std.mem.indexOf(u8, html[offset..], "\"")) |link_end| {
                        const link = html[offset .. offset + link_end];
                        offset += link_end;

                        if (link_finder.settings.debug) {
                            std.log.debug("Found closing quote for href at offset {}.", .{offset});
                            std.log.debug("Found link from {} to {}: \"{s}\".", .{ offset - link_end, offset, link });
                        }

                        try links.append(link);
                        if (link_finder.settings.recurse) {
                            std.log.warn("TODO: Recursion not yet implemented.", .{});
                        }
                    } else {
                        std.log.err("No closing quote found for href attribute.", .{});
                        continue;
                    }
                } else {
                    std.log.err("No href attribute found in <a> tag.", .{});
                    continue;
                }

                if (std.mem.indexOf(u8, html[offset..], "</a>")) |tag_end| {
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

        if (link_finder.settings.debug) std.log.debug("Found {} links!", .{links.items.len});

        return links;
    }

    test "find links" {
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

        const link_finder = LinkFinder.init(.{ .debug = true });
        const links = try link_finder.findLinks(allocator, html);
        defer links.deinit();

        try std.testing.expectEqual(expected_links.len, links.items.len);
        for (links.items, expected_links) |found, expected| {
            try std.testing.expectEqualStrings(expected, found);
        }
    }
};

// -- Test References -- //

test {
    std.testing.log_level = .debug;
    std.testing.refAllDecls(LinkFinder);
}
