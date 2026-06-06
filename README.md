# Hollowell

#### Note: this project is a work-in-progress, it's not intended to be used in production yet.

Yet another attempt on implementing a server emulator for the game Zenless Zone Zero.

This server has started as a "happy I/O utopia": a custom `std.Io` implementation that is tailored specifically for the needs of this server. However, the more I worked on it "the std.Io way," the more disappointed I felt with this approach. Right now, the project is undergoing an overhaul. You can follow the [issue tracker](https://git.xeondev.com/hollowell/hollowell/issues) to stay up-to-date with the implementation.

Notably, the following things are already implemented:
- a highly efficient implementation of a KCP server
- a minimal RSA encrypt/decrypt/sign functionality on top of `std.crypto.ff`
- a protobuf encoder/decoder and compiler
- a POSIX API layer

This repository was made public in the hopes that it will be useful. However, it comes with no warranty whatsoever (expressed or implied).
I apologize for the horrible, unstructured code you may see in `gamesv`; it is (mostly) a draft that was made for testing `nrmio.posix` and `kcp` implementation.
