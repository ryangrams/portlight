# Third-party components

Portlight is a fresh implementation of the server and viewers. It does not link to or copy the previous GPL macVNC/LibVNCServer implementation.

- **nlohmann/json 3.12.0**, MIT license. Vendored header and license under `third_party/nlohmann/`. Used for JSON parsing by the Windows viewer and native ZeroTier helper. A copy of the license is included in `licenses/nlohmann-json.txt` for binary distributions.
- **Apple system frameworks** supply macOS capture, user interface, audio, networking, image codecs and security. They are not redistributed in this repository.
- **Windows system APIs** supply the Windows user interface, WinHTTP secure WebSocket transport, WIC image decoding, cryptography, and audio output. They are not redistributed in this repository.
- **ZeroTier One**, installed separately by the user, is controlled through its authenticated local service API. Portlight does not embed or redistribute its networking engine. ZeroTier is a trademark of its respective owner.
- The macOS server uses the operating system's OpenSSL-compatible command-line utility when generating its local TLS identity; that executable is not bundled. No private TLS keys are distributed.
- **LLVM-MinGW 20260908** cross-compiles the Windows artifacts. It is not a required installation for users, but the executables statically link compiler/C++ and MinGW runtime code. Upstream notices are included in `licenses/LLVM.txt` (Apache 2.0 with LLVM exceptions), `licenses/MinGW-w64-runtime.txt`, and `licenses/winpthreads.txt`. These files accompany the binary packages.

Protocol key symbols are interoperable numeric constants; no upstream VNC implementation source is included. Platform and third-party names identify compatibility and do not imply endorsement.
