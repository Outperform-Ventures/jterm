# jTerm

A native terminal emulator based on [Ghostty](https://github.com/ghostty-org/ghostty), with jTerm-specific remote-control commands and compose editing features.

jTerm retains Ghostty's Zig terminal core and native application architecture. The macOS application uses Swift and Metal; the source also includes the inherited GTK implementation. jTerm is an independent project and is not an official Ghostty release.

## Features

- Native macOS windows, tabs, and split panes
- GPU-accelerated terminal rendering
- Shell integration and configurable key bindings
- Command-line remote control for windows, panes, text, and layout
- Compose editing support for terminal workflows

The project is under active development. Compatibility with other terminal remote-control protocols is a work in progress. Prebuilt jTerm releases are not currently published from this repository.

## Build from source

### Requirements

- Zig **0.15.2**, matching `build.zig.zon`
- macOS with Xcode and the macOS SDK for the native application
- Git

Build dependencies are fetched by Zig. See [the development guide](HACKING.md) for platform-specific dependencies and build options.

```sh
git clone https://github.com/Outperform-Ventures/jterm.git
cd jterm
zig build
```

The macOS application is generated under `zig-out/`. Development builds are not notarized distribution packages.

To build and launch the application:

```sh
zig build run
```

Use a separate configuration and remote-control socket when testing alongside another jTerm instance. The [development launcher](scripts/dev-jterm.sh) supports explicit binary, configuration, socket, and log paths.

## Usage and documentation

- [Remote-control user guide](docs/JTERM_REMOTE_CONTROL_USER_GUIDE.md)
- [Remote-control command reference](docs/JTERM_REMOTE_CONTROL_COMMAND_REFERENCE.md)
- [Remote-control CLI reference](docs/JTERM_REMOTE_CONTROL_CLI_MANPAGE.md)
- [Development guide](HACKING.md)
- [Contributing](CONTRIBUTING.md)

```sh
jterm +help
jterm +show-config --default --docs
jterm @ --help
```

Remote control can read terminal contents, launch processes, and send input. Enable it only for trusted clients and protect its socket and authentication material. Avoid including terminal contents, credentials, or private file paths in public bug reports.

## Testing

```sh
zig build test
```

On macOS, the full test command also runs native Xcode tests and may require test-runner authorization. On macOS, a test-name filter runs matching Zig tests without launching the native test runner. For example, to run stream-parser tests:

```sh
zig build test -Dtest-filter=stream
```

The repository CI checks the terminal core on Linux. This does not validate the native macOS interface or every remote-control integration.

## Contributing

Bug reports and pull requests are welcome in [this repository](https://github.com/Outperform-Ventures/jterm). Include reproduction steps and relevant platform/toolchain versions. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

## License and acknowledgments

jTerm is distributed under the [MIT License](LICENSE). Copyright and license notices for Ghostty, its contributors, bundled fonts, and other dependencies are retained. Ghostty provides the foundation of this project; jTerm-specific changes are maintained here.
