# Remielle

#### Note: this project is unfinished (and likely never will be finished)

Yet another attempt on implementing a server emulator for the game Zenless Zone Zero.

I probably won't be updating this repository. It started as a "happy I/O utopia": a custom `std.Io` implementation that is tailored specifically for the needs of this server. However, the more I worked on it "the std.Io way," the more disappointed I felt with this approach. Some people may like this implementation, while others may not. I personally hate it. I think that `std.Io` forces too much unnecessary complexity for what I'd use just a simple `poll` syscall in a single thread, without any coroutines or other bullshit like that.

Nevertheless, this repository includes some good things that I will most likely reuse in the future:
- a highly efficient implementation of a KCP server
- a minimal RSA encrypt/decrypt/sign functionality on top of `std.crypto.ff`
- a protobuf encoder/decoder and compiler

This repository was made public in the hopes that it will be useful. However, it comes with no warranty whatsoever (expressed or implied).
I apologize for the horrible, unstructured code you may see in `gamesv`; it is (mostly) a draft that was made for testing `std.Io` and `kcp` implementations.
