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
|   ⚠️   | Bootstrap and history building          |
|   ❌   | Branching and naming                    |
|   ❌   | Remotes and transfer protocols          |
|   ❌   | Storage formats (pack files)            |
|   ❌   | Basic configuration                     |
|   ⚠️   | Multi-hash support                      |
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


## Library Usage

The implementation of the CLI commands may be used as reference for usage of API functions.

### APIs
The entry point is [lib.zig](./src/lib.zig).

Repository operations:
- `storage.GitRepository.open(std.mem.Allocator, ?[]const u8) !storage.GitRepository`
  Opens an existing Git repository, searching it from the directory `dir_name` or from the current one.
- `storage.GitRepository.setup(std.mem.Allocator, storage.SetupOptions) !storage.GitRepository`
  Creates an empty Git repository - or reinitializes an existing one - in the directory `options.name` or in the current one. The initial branch will be named as `options.initial_branch` or `main`.
- `storage.GitRepository.close(std.mem.Allocator) void`
  Close the Git repository and frees referenced resources.

Commands:
- `hashObject(std.mem.Allocator, ObjectStore, std.io.GenericReader, []const u8, bool, bool) ![]const u8`
  Computes the object's identifier name and optionally writes it to the object store.
- `readObject(std.mem.Allocator, ObjectStore, []const u8, ?[]const u8) !model.Object`
  Reads the object content identified by `name` in the object store.
- `readTypeAndSize(std.mem.Allocator, ObjectStore, []const u8, bool) !struct{ []const u8, usize }`
  Reads the type and the size of the object identified by `name` in the object store.
- `readEncodedData(std.mem.Allocator, ObjectStore, []const u8) ![]u8`
  Reads the encoded content (header+data) of the object identified by `name` in the object store.
- `listFiles(std.mem.Allocator, Repository, ListFilesOptions) !std.ArrayList(File)`
  Retrieves a list of files in the index and in the working directory.


## Development

### Requirements
You need Zig v0.14.x to compile the project.
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
- Core Objects:
  - `lib/model.zig` — Commonly data structures.
- Core logic:
  - `lib/*.zig` — Implementation of commands and rules.
- Adapters and infrastructure:
  - `lib/index.zig` — Handling of the Git index file format.
  - `lib/helpers.zig` — Helpers and common code used throughout the application.
  - `lib/storage.zig` — Management of Git repositories and object databases.
- Entry-points:
  - `cli/*.zig` — CLI commands.
  - `lib.zig` — library access interface.

### Limitations
- Object names must be used in full length, i.e. 40 characters hash are needed to identify objects.
- The commit object does not handle message encoding and extra headers (such as mergetag).
- Git configuration files are ignored overall.
- Object management is naive and should be improved
  (by reading and writing streamed content, using caching or object pools, and memory-mapping large files).
  As an example, the `hashObject` function reads and allocates in memory the entire input
  without any particular performance considerations.
- The maximum file size is arbitrarily limited to 1 GB,
  (see `max_file_size` constant in [storage](./src/lib/storage.zig).
- SHA-1 hashing is hardcoded in some components (ObjectId, object-read, object-write),
  ref: [hash-function-transition](https://git-scm.com/docs/hash-function-transition).
- The command-line flags must be passed as separated arguments and cannot be combined (i.e. use "-a -b", not "-ab")
- _Sparse directory_ is the only supported index extension.


## Git Concepts

From [git at v1.0.13](https://github.com/git/git/blob/v1.0.13/README):
> The object database is literally just a content-addressable collection of objects.
> All objects are named by their content, which is approximated by the SHA1 hash of the object itself.
>
> All objects have a statically determined "type" aka "tag",
> which is determined at object creation time,
> and which identifies the format of the object
> (i.e. how it is used, and how it can refer to other objects).
> There are currently four different object types: "blob", "tree", "commit" and "tag".
>
> Regardless of object type, all objects share the following characteristics:
> they are all deflated with zlib,
> and have a header that not only specifies their tag,
> but also provides size information about the data in the object.
> It's worth noting that the SHA1 hash that is used to name the object is the hash of the original data plus this header,
> so `sha1sum` 'file' does not match the object name for 'file'.

### Loose Object Handling
Data representation of objects is transformed sequentially through several stages.
The operations for creation and access go through the same stages, but in reverse order.
These transformations may be visualized as pipelines.

```
    :                   :              :               :             :
    :  +-------------+  :  +--------+  :  +---------+  :  +-------+  :
  ---->|  serialize  |---->| encode |---->| deflate |---->| write |----->
    :  +-------------+  :  +--------+  :  +---------+  :  +-------+  :
    :                   :              :               :             :
    :  +-------------+  :  +--------+  :  +---------+  :  +-------+  :
 <-----| deserialize |<----| decode |<----| inflate |<----| read  |<----
    :  +-------------+  :  +--------+  :  +---------+  :  +-------+  :
    :                   :              :               :             :
structured          serialized      encoded        compressed       file
  content              data      (header+data)        data
```

To write an object to the storage, data goes through four stages:
- serialize the structured content (blob, tree, commit or tag) into bytes
- insert data into encoded format (header + data)
- compress the encoded data with zlib deflate
- write compressed data to the file-system

While to load an object from the storage, data goes through the same four stages in the revere order:
- read a file from file-system
- decompress the file content with zlib inflate
- extract data from the encoded format (header + data)
- deserialize the data to obtain the structured content (blob, tree, commit or tag)

In both flows, the _encoded data_ - i.e. header and serialized data - may be used to name the object content.

This implementation organizes the data transformations into distinct levels.
Each transformation and its inverse (e.g., serialize/deserialize) are grouped into a logical level,
which corresponds to a dedicated code module.

```
       +-------------+     +--------+     +---------+     +-------+
  ---->|  serialize  |---->| encode |--+->| deflate |---->| write |----->
       +-------------+     +--------+  :  +---------+     +-------+
       +-------------+     +--------+  :  +---------+     +-------+
 <-----| deserialize |<----| decode |<-+--| inflate |<----| read  |<----
       +-------------+     +--------+  :  +---------+     +-------+
      '---------------'   '----------' : '-------------------------'
           Object         LooseObject  :            Store
                                     Hasher
```

The `zlib` library is used directly within the storage module and is not a separate level itself.


## Contributing

Contributions are always welcome!
For more details, please see [CONTRIBUTING.md](./CONTRIBUTING.md).


## License

This project is licensed under the terms of the [MPL-2.0](./LICENSE) license.
