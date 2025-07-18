# `aside`

> [!NOTE]
> This is my first project that makes use of GitHub Copilot (or any similar) as
> I experiment with it (I am very, very late). I primarily use it for 
> boilerplate that I can later fix up and add to. It's not very good with Zig 
> but it's good enough to write the structure of the code for this sort of 
> program very quickly, which I enjoy.

## Ideas

- [ ] Calculating upper and lower bound memory allocations for zig functions.
- [ ] A preprocessor for zig, i.e. comptime++, via `build.zig`.
- [ ] A natural-language esque REPL.
- [ ] External LSP-like websocket dashboard.
- [ ] And more stuff I have yet to think of, mostly just small tools.

## Implemented Features

### Link Finder (`link-finder` / `lf`)

Extracts links from HTML URLs in the simplest possible way (pure scanning for 
`<a>` tags); supports link following (BFS).

- [x] From URL (Remote)
- [x] Follows links to a set depth
- [x] Link filters
- [ ] Reporting status code along with link
- [ ] Multi-threading
- [ ] GraphViz output

**Usage:**
```bash
# Basic link extraction from URL
aside lf https://example.com

# Recursive link following with custom depth
aside link-finder --recursive --limit 3 https://example.com

# Debug mode for verbose output
aside lf --debug --recursive https://example.com

# Show help
aside lf --help
```