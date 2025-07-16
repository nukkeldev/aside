# `aside`

> [!NOTE] Disclaimer
> This is my first project that makes use of GitHub Copilot (or any similar) as
> I experiment with it (I am very, very late). I primarily use it for 
> boilerplate that I can later fix up and add to as it's not very good with Zig 
> to be honest but it's good enough to write the code for this sort of program 
> very quickly, which I hadn't been able to do before.

A dumb CLI assistant that does quite a few random things. These (could) include, 
but are not limited to:
- [x] (Recusively) scanning remote or local html for links.
    - [x] Local
    - [x] Remote
    - [x] Recursive-ness
- [ ] Calculating upper and lower bound memory allocations for zig functions.
- [ ] A preprocessor for zig, i.e. comptime++, via `build.zig`.
- [ ] A natural-language esque REPL.
- [ ] External LSP-like websocket dashboard.
- [ ] And more stuff I have yet to think of, mostly just small tools.