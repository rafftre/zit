<!--
SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
SPDX-License-Identifier: MPL-2.0
-->

# Zit, a Git implementation written in Zig

> **⚠️ This project is in an early, unstable development stage.**
> Features may change or break whitout notice.
> Use at your own risk.

This application consists of two parts:
1. A CLI (Command-Line Interface) - directly executable and designed to partially mimic the behavior of Git.
2. A library module - usable as a dependency in other projects that need to work on a Git repository.


## Purpose

The aim of this project is to implement only the lowest level “plumbing” Git commands,
along with everything strictly necessary for profitable use from the command line
or within an application (if used as a library).
There are no plans to implement a full Git clone.
The ideal use case would be to use it as a base kit for creating a higher-level SCM-based tool.


## Status and Roadmap

| Status | Step                                    |
|:------:|-----------------------------------------|
|   ✍️   | Bootstrap and history building          |
|   ✅   | Upgrade to Zig 0.15                     |
|   ❌   | Branching and naming                    |
|   ❌   | Remotes and transfer protocols          |
|   ❌   | Storage formats (pack files)            |
|   ❌   | Basic configuration                     |
|   ✅   | Multi-hash support                      |
|   ❓   | Other features (worktrees, notes...)    |
|   ❓   | Custom features (history analysis, etc) |


## CLI Usage

First add the `zit` executable to `PATH`, then you may use `zit -h` to get help.

Note: A full 40 characters hash must be used to identify objects; abbreviations are not yet supported.

Example:
```sh
cd path/to/parent/dir
zit init dirname
cd dirname
echo 'sample content' | zit hash-object --stdin -w
zit cat-file -p 4b4f223d5c2b7c88abd487b3eaf5de2000755cc3
```

### Available commands
- `init` - Create an empty repository or reinitialize an existing one. Usage:
  ```
  zit init [-b <branch-name> | --initial-branch=<branch-name>]
           [--bare] [<directory>]
  ```
- `hash-object` - Compute object ID and optionally writes to the database. Usage:
  ```
  zit hash-object [-t <type>] [-w] [--stdin [--literally]] <file>...
  ```
- `cat-file` - Provide contents or type and size information for objects. Usage:
  ```
  zit cat-file <type> <object>
  zit cat-file (-e | -p) <object>
  zit cat-file (-t | -s) [--allow-unknown-type] <object>
  ```
- `ls-files` - Show information about files in the index and the working tree. Usage:
  ```
  zit ls-files [-c|--cached] [-o|--others] [-d|--deleted] [-m|--modified]
               [-u|--unmerged] [-k|--killed] [-s|--stage] [-z]
  ```
- `inflate` - Decompresses an object in the repository. Usage:
  ```
  zit inflate <object>
  ```
- `help` - Show usage information. Without argument: show global help. Usage:
  ```
  zit help [<command>]
  ```
- `version` - Print the application version. Usage:
  ```
  zit version
  ```


## Library Usage

The implementation of the CLI commands may be used as reference for usage of API functions.

### APIs
The entry point is [lib.zig](./src/lib.zig).

- Repository operations (`zit.Repository`): Opening an existing repository; Setting up a new repository; loading the index; reading and writing objects from and to the storage.
- Plumbing commands:
  - object access and manipulation (`zit.object`) - creating and reading objects.
  - file listing (`zit.file`) - list tracked, untracked, deleted, and modified files.


## Development

### Requirements
You need Zig v0.15.1 to compile the project.
There are no dependencies.

### Building
Execute:
- `zig build -Doptimize=ReleaseSafe` to build a release
- `zig build test --summary all` to run tests

### Generating the documentation
To generate and serve the HTML documentation for the library module run:
```sh
zig build docs
python3 -m http.server 5000 -d zig-out/docs
```
Open a browser at [localhost:5000](http://localhost:5000/) to read the generated documentation.


## Design Notes

### Architecture
The code is structured into layers, with the higher levels depending on the lower ones.
Each level corresponds to a Zig package with the following structure (from highest to lowest).
- `lib/*` — Implementation of commands and rules; infrastructure code.
- `lib/model/*` — Data model and file formats.
- `lib/model/util/*` — Helpers and common code.
- `lib/model/newflate/*` — Porting of `flate` compression functions from Zig 0.16 that are missing in 0.15.
- `cli/*` — CLI commands.
- `cli.zig` — CLI entry-point.
- `lib.zig` — library access interface.

### Limitations
- Object names must be used in full length, i.e. 40 characters hash are needed to identify objects.
- The commit object does not handle message encoding and extra headers (such as mergetag).
- Git configuration files are ignored overall.
- Object management is naive and should be improved
  (by reading and writing streamed content, using caching or object pools, and memory-mapping large files).
  As an example, the `hash-object` command reads and allocates in memory the entire input
  without any particular performance considerations.
- _Sparse directory_ is the only supported index extension.

### Open points after migration to Zig 0.15
1. The zlib compression (_deflate_) is ported from next version of Zig in the module `lib/model/newflate` and should be removed with a future migration to Zig 0.16.


## Contributing

Contributions are always welcome!
For more details, please see [CONTRIBUTING.md](./CONTRIBUTING.md).


## License

This project is licensed under the terms of the [MPL-2.0](./LICENSE) license.
