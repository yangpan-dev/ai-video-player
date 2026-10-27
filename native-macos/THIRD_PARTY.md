# Native playback dependencies

The Swift application and the small CMPV dynamic bridge are original code.
CMPV declares only the ABI subset it uses from libmpv's stable public API v2:

- https://github.com/mpv-player/mpv/blob/v0.40.0/libmpv/client.h
- https://github.com/mpv-player/mpv/blob/v0.40.0/libmpv/render.h
- https://github.com/mpv-player/mpv/blob/v0.40.0/libmpv/render_gl.h

No mpv, FFmpeg or IINA binaries or source code are tracked in this repository.
Debug builds can load the user's installed IINA playback libraries for local
development. Local standalone packages can copy only the reachable libmpv
runtime and its dependencies from an installed mpv or IINA build. The IINA
application is never modified, and its application code, interface, icons,
updater and unrelated frameworks are not included.

Each standalone package includes `Resources/PlaybackRuntime/manifest.json`
with the provider version, source paths, architecture and library checksums.
When the provider is IINA, its original dependency credits are preserved.
These provenance records are not a substitute for complete license notices
or corresponding source when publishing a public release.

mpv is GPL by default; an LGPL build is possible under the conditions described
at https://github.com/mpv-player/mpv/blob/master/Copyright. Its dependency build
options (including FFmpeg) also affect licensing. The existing Electron
project's MIT declaration does not override these dependencies' terms.

For distribution, provide a compatible libmpv build, audit its complete
dependency chain, and include the notices and corresponding-source material
required by that build's licenses. Ad-hoc signing is for local use; public
distribution also needs the appropriate Apple signing and notarization.
