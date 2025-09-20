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
2. A library module - usable as a dependency in other Zig projects that need to work on a Git repository.


## Purpose

The aim of this project is to implement only the lowest level “plumbing” Git commands,
along with everything strictly necessary for profitable use from the command line
or within an application (if used as a library).
There are no plans to implement a full Git clone.
The ideal use case would be to use it as a base kit for creating a higher-level SCM-based tool.


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
- `inflate` - Decompresses an object in the repository. Usage:
  ```
  zit inflate <object>
  ```


## Library Usage

The implementation of the CLI commands may be used as reference for usage of API functions.

### APIs
The entry point is [lib.zig](./src/lib.zig).
- `storage.openGitRepository(allocator, name)`
  Opens a repository existing on the file-system, searching it from the directory `name`.
- `storage.createGitRepository(allocator, options)`
  Creates an empty repository or reinitializes an existing one.
  The repository will be created on the file-system
  in the directory `options.name` (or in the current directory when not specified)
  and with an in initial branch named `options.initial_branch` (or `main` when not specified).
- `hashObject(allocator, object_store, reader, type_str, check_format, persist)`
  Computes the object's identifier name and - if `persist` is `true` - writes it to the object store.
  `type_str` is the type of the object, returns an error if it is not a valid type.
  When `check_format` is `true`, it checks that the content passes the standard object parsing.
  If `persist` is `true` writes to the object store.
- `readObject(allocator, object_store, name, expected_type)`
  Reads the object content identified by `name` in the object store.
  When `expected_type` is specified, the type read must match it, otherwise an error will be returned.
- `readTypeAndSize(allocator, object_store, name, allow_unknown_type)`
  Reads the type and the size of the object identified by `name` in the object store.
  If `allow_unknown_type` is `true`, no error will be raised for an unknown type.
- `readEncodedData(allocator, object_store, name)`
  Reads the encoded content - i.e. header (type name, space, and length) and
  serialized data - of the object identified by `name` in the object store.


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
The code is structured into nested layers, with the outer levels depending on the inner, more abstract ones.

The outermost layer consists of CLI commands and library access interface.

The library has the following parts:
1. `lib.zig` - the library interface.
2. `lib` - Git logic and rules.
3. `lib/core` - Git core objects.

### Limitations
- Object names must be used in full length, i.e. 40 characters hash are needed to identify objects.
- The commit object does not handle message encoding and extra headers (such as mergetag).
- Git configuration files are ignored overall.
- Object management is naive and should be improved
  (by reading and writing streamed content, using caching or object pools, and memory-mapping large files).
  As an example, the `hashObject` function reads and allocates in memory the entire input
  without any particular performance considerations.
- The maximum file size is arbitrarily limited to 1 GB,
  (see `max_file_size` constant in [GitObjectStore](./src/lib/GitObjectStore.zig).


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
For more details, please see
[CONTRIBUTING.md](./CONTRIBUTING.md).


## License

This project is licensed under the terms of the [MPL-2.0](./LICENSE) license.
