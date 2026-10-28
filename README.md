# mdzip-core-lua

Read, write and validate **MDZip** (`.mdz`) files in Lua: one or more Markdown documents and their images and other files, packaged in a single ZIP archive.

This library implements the [MDZip specification](https://github.com/mdzip-project/mdzip-spec) 1.2 and the operations in the [core library contract](https://github.com/mdzip-project/.github/blob/main/docs/core-contract.md) (R1–R7). It's a standalone implementation, not a binding to the JavaScript, .NET, Rust or Python cores, and it passes the specification's shared conformance fixtures, the same ones every MDZip core runs.

- Pure Lua 5.3 or 5.4. No C modules, no dependencies.
- Everything it needs is built in: ZIP, DEFLATE, CRC-32, strict JSON, and Unicode NFC normalization ([why](#why-no-zip-library)).
- It doesn't render Markdown; that's up to your app.

## Install

Copy `src/mdzip/` onto your `package.path`, or, once it's published, `luarocks install mdzip-core-lua`. Then:

```lua
local mdzip = require("mdzip")
```

## Errors

Functions that can fail return `nil, err`, the usual Lua convention. `err` is a table with a stable `code`, a `message`, and usually the archive `path` involved; `tostring(err)` gives `"CODE: message (path)"`.

```lua
local archive, err = mdzip.open_file("guide.mdz")
if not archive then
  if err.code == "ERR_ZIP_INVALID" then print("not an MDZip file") end
  error(tostring(err))
end
```

The codes are the specification's (Section 16.5) wherever one applies:

| Code | Meaning |
|---|---|
| `ERR_ZIP_INVALID` | Not a valid ZIP, compression other than stored or DEFLATE, overlapping entries, bad CRC or corrupt data |
| `ERR_ZIP_ENCRYPTED` | Encrypted entries |
| `ERR_PATH_INVALID` | An entry name breaks spec 5.4; `err.detail` says how (`ERR_PATH_TRAVERSAL`, `ERR_PATH_LEADING_SLASH`, `ERR_PATH_RESERVED_CHAR`, `ERR_PATH_CONTROL_CHAR` or `ERR_PATH_INVALID`) |
| `ERR_DUPLICATE_PATH` | Two entries are the same path after NFC normalization |
| `ERR_PATH_CONFLICT` | A file's path is also a directory of another entry |
| `ERR_MANIFEST_INVALID` | `manifest.json` isn't UTF-8 JSON with an object at the top, or `spec`/`spec.version`/`mode` has the wrong type |
| `ERR_VERSION_UNSUPPORTED` | `spec.version` has a major version above 1 |
| `ERR_MODE_UNSUPPORTED` | `mode` is a string other than `document` or `project` |
| `ERR_ENTRYPOINT_INVALID` | `entryPoint` isn't a valid entry point path |
| `ERR_ENTRYPOINT_MISSING` | `entryPoint` names a file that isn't there (`err.suggestion` holds a case-only near match, if any) |
| `ERR_ENTRYPOINT_UNRESOLVED` | No manifest entry point and no unambiguous one by the discovery rules (`err.candidates` lists them) |
| `ERR_LIMIT_EXCEEDED` | A resource limit was hit ([limits](#safety-and-limits)) |
| `ERR_NOT_FOUND`, `ERR_TEXT_INVALID`, `ERR_IO`, `ERR_ARGUMENT` | The library's own: no such file in the archive, text that isn't UTF-8, a host file problem, a bad argument |

All codes are also in `mdzip.codes` (for example `mdzip.codes.ENTRYPOINT_MISSING`).

## Reading

```lua
local archive = assert(mdzip.open_file("guide.mdz"))   -- or mdzip.open(bytes)

local entry = assert(archive:entry_point())   -- e.g. "index.md" (spec 5.5)
local text = assert(archive:read_text(entry)) -- UTF-8 text, line endings as stored
local logo = assert(archive:read("images/logo.png"))

print(archive:title(), archive:mode())        -- "My Guide"  "document"
for _, doc in ipairs(archive:documents()) do print(doc) end
```

| Method | Returns |
|---|---|
| `archive:entries()` | Every entry in archive order: `{ path, kind, size, compressed_size, method }`, where `kind` is `"file"`, `"directory"`, `"symlink"` or `"special"` |
| `archive:files()` | Stored names of regular files |
| `archive:directories()` | Stored directory entries (each ends in `/`) |
| `archive:documents()` | Markdown files (`.md`, `.markdown`, ASCII case-insensitive) |
| `archive:special_entries()` | Symbolic links and other special entries, which are skipped: `{ path, kind }` |
| `archive:find(path)` | The stored name matching `path`, or `nil` |
| `archive:has(path)` | `true` when `find` succeeds |
| `archive:near_match(path)` | A file whose name differs from `path` only in case, for "did you mean" hints; never a match |
| `archive:read(path)` | The file's bytes |
| `archive:read_text(path)` | The file as UTF-8 text (`ERR_TEXT_INVALID` otherwise) |
| `archive:manifest()` | The decoded manifest, `nil` when there is none, or `nil, ERR_MANIFEST_INVALID` when it can't be read |
| `archive:has_manifest()` | Whether `manifest.json` exists |
| `archive:spec_version()` | `spec.version` as declared, or `nil` |
| `archive:entry_point()` | The entry point's stored name |
| `archive:mode()` | `"document"` or `"project"` |
| `archive:title()` | The manifest title when it's valid, else `nil` |

Lookups follow the spec's matching rule: case-sensitive, after NFC normalization. So `café.md` is found however it's encoded, and `Index.md` doesn't match `index.md`. The archive is held in memory; nothing is extracted to disk.

A declared `entryPoint` that is invalid or missing is an error. The library never falls back to `index.md` or a lone Markdown file in that case; offering that recovery, with a visible warning, is up to your app (spec 5.5). An unreadable manifest or an unsupported `spec.version` makes `entry_point()` and `mode()` fail too, rather than being ignored.

The manifest is a JSON object table: index it like any table (`m.title`, `m.author.name`). `mdzip.json` has the helpers: `json.null`, `json.keys(obj)` (in their original order), `json.is_object`, `json.is_array`, `json.pointer(v, "/a/b")`, `json.equal`, `json.encode`, `json.decode`.

### Links

```lua
local r = archive:resolve_link("chapters/intro.md", "../images/logo.png#top")
-- { kind = "internal", entry = "images/logo.png", fragment = "top" }
```

`kind` is `"internal"` (with `entry`, the stored name), `"url"` (a destination with a scheme, such as `https:` or `mailto:`) or `"unresolved"` (with `reason`: `"not-found"`, `"invalid"` or `"unsupported"`). `fragment` is kept in every case. Resolution follows spec 9.3: the query is dropped, each segment is percent-decoded once, and `..` is never clamped at the archive root.

Links that climb out of the archive (spec 9.4) or into another archive (9.5) are optional in the spec, and this library doesn't support them: they come back `"unresolved"` with reason `"unsupported"`, never as some other target.

## Validating

```lua
local report = archive:validate()          -- or mdzip.validate(bytes) / mdzip.validate_file(path)
print(report.valid)
for _, e in ipairs(report.errors) do print(e.code, e.message, e.path) end
for _, w in ipairs(report.warnings) do print(w.code, w.message, w.path) end
```

`errors` hold the spec codes above. `mdzip.validate(bytes)` also turns a failure to open into an error finding. `warnings` don't stop the archive from opening:

| Warning | Meaning |
|---|---|
| `WARN_MANIFEST_FIELD_IGNORED` | A descriptive field (`title`, `author`, `created`, `cover` …) has a wrong type or value and is ignored (`w.field`) |
| `WARN_MANIFEST_DUPLICATE_MEMBER` | A member name appears twice in one object; the last one is used (`w.pointer`) |
| `WARN_SPEC_VERSION_OLD` | `spec.version` has a major version below 1 |
| `WARN_COVER_MISSING` | `cover` names a file that isn't in the archive |
| `WARN_SPECIAL_ENTRY` | A symbolic link or other special entry, which is skipped |
| `WARN_CASE_COLLISION` | Names that differ only in case, which collide when extracted on Windows or macOS (`w.names`) |
| `WARN_ZIP64_UNNEEDED` | ZIP64 records where no value needed them |
| `WARN_UTF8_FLAG_MISSING` | A non-ASCII name without the UTF-8 flag |

An archive without a manifest is valid and gets no warning for it.

## Creating

```lua
local bytes = assert(mdzip.create({
  files = {
    { path = "index.md", text = "# My Guide\n\n![Logo](images/logo.png)\n" },
    { path = "images/logo.png", data = png_bytes },
  },
  title = "My Guide",
  application = { name = "my-editor", version = "1.0", url = "https://example.com" },
  manifest = { author = { name = "Ada" }, language = "en" },  -- any other fields
}))
-- or mdzip.create_file("guide.mdz", { ... })
```

| Option | Meaning |
|---|---|
| `files` | `{ path, text }` or `{ path, data }` items. Paths are checked against spec 5.4 and written in NFC; their capitalization is kept. |
| `entry_point` | The entry point. Default: `index.md`, or the only Markdown file at the root (otherwise `ERR_ENTRYPOINT_UNRESOLVED`). |
| `title`, `mode` | `mode` is `"document"` (default) or `"project"`. |
| `application` | `{ name, version, url }` of your app, recorded as `producer.application`. |
| `manifest` | Other manifest fields. Plain Lua tables are fine: sequences become arrays. |
| `time` | Creation time as an `os.time()` value (default now). |

The library always writes a `manifest.json` with `spec`, `producer.core`, `mode`, `entryPoint` and `created`, plus `title` when you give one. Markdown files are checked to be UTF-8 and written with LF line endings; other files are written exactly as given. Entries are compressed with DEFLATE when that makes them smaller, and stored otherwise (images and other already-compressed formats are always stored). Non-ASCII names get the UTF-8 flag, and ZIP64 is written only when a value doesn't fit without it.

## Modifying

```lua
local bytes, report = archive:update({
  put = { { path = "AGENTS.md", text = "# Notes for agents\n" } },   -- add or replace
  remove = { "drafts/old.md" },
  manifest = { title = "New title", keywords = mdzip.REMOVE },     -- set or remove fields
}, { application = { name = "my-editor", version = "1.0" } })
if not bytes then error(tostring(report)) end
for _, w in ipairs(report.warnings) do print(w.code, w.message) end

-- or, on a file:  local report, err = mdzip.update_file("guide.mdz", changes, options)
```

- Every entry you don't name keeps its path and bytes: its compressed data is copied as stored. Directory entries are kept too.
- Unknown manifest fields are kept, at every level, in their original order. `modified.when` is set to now unless you pass `{ touch = false }`.
- A replaced file keeps its stored name and its place in the archive.
- The entry point must stay where it was. A change that would move or break it fails (pass `entry_point = "new.md"` when changing it is the point). An archive without a manifest gets one, recording the entry point it had.
- Problems that were already there are kept and reported as `WARN_STILL_NONCONFORMING`; new ones fail. Symbolic links are kept as they were, with `WARN_SPECIAL_ENTRY_KEPT`; remove them by path if you want them gone.
- Nothing is written when anything fails. `update_file` writes the new archive to a temporary file next to the original and swaps it in only when it's complete.

## Safety and limits

Opening is safe for untrusted input:

- Entry names are checked when opening: absolute names, `..`, empty or `.` segments, reserved or control characters, NFC duplicates and file/directory conflicts are rejected, not renamed.
- Encrypted entries and compression methods other than 0 and 8 are rejected.
- Symbolic links are never followed or read, and no path resolves through one. They're listed in `special_entries()`, not `files()`.
- Entries whose data overlaps another entry's are rejected.
- Built-in limits (`mdzip.LIMITS`) are checked against the declared sizes when opening, and again while decompressing, since declared sizes can lie: decompression stops as soon as an entry produces more than it declared.

| Limit | Default |
|---|---|
| Entries | 100,000 |
| Uncompressed size of one entry | 1 GiB |
| Uncompressed size in total | 4 GiB |
| Compression ratio (entries over 1 MiB) | 1,000:1 |

These match the spec fixtures' reference limits. They aren't configurable yet.

## The core contract, operation by operation

| | Contract operation | This library |
|---|---|---|
| R1 | Open/read an archive | `mdzip.open(bytes)`, `mdzip.open_file(path)` |
| R2 | Inspect entries and metadata | `entries`, `files`, `directories`, `documents`, `special_entries`, `find`, `has`, `read`, `read_text`, `manifest`, `spec_version`, `entry_point`, `mode`, `title` |
| R3 | Resolve a link | `archive:resolve_link(from, link)`; also `mdzip.resolve_link(file_list, from, link)` without an archive |
| R4 | Validate | `archive:validate()`, `mdzip.validate(bytes)`, `mdzip.validate_file(path)`; open-time rejections cover unrecoverable ZIP and path problems |
| R5 | Create | `mdzip.create(options)`, `mdzip.create_file(path, options)` |
| R6 | Modify | `archive:update(changes, options)`, `mdzip.update_file(path, changes, options)` |
| R7 | Safety boundaries | Enforced by `open`, `read` and `update`; see [Safety and limits](#safety-and-limits) |

Building blocks usable without an archive: `mdzip.check_path(path)`, `mdzip.check_entry_names(list)`, `mdzip.parse_manifest(text)`, `mdzip.find_entry_point(file_list, manifest)`, `mdzip.same_path(a, b)`, `mdzip.nfc(s)`, `mdzip.is_markdown(path)`, `mdzip.is_support_file(path)`.

Optional extensions from the contract that this library doesn't have: image analysis, a workspace/editor model, asset presentation helpers (MIME types, data URIs), packaging conveniences (directory scans, filters), configurable limits, and links outside or into archives.

## Conformance

`lua tests/run.lua` runs the spec's shared tests from `tests/fixtures/` (copied from spec tag [v1.2.1](https://github.com/mdzip-project/mdzip-spec/releases/tag/v1.2.1) and checked against `SPEC-FIXTURES.json`) through the public API, plus the library's own unit tests. Results on Lua 5.4.6:

| Test | Result |
|---|---|
| T-001 to T-010, T-012 to T-015, T-017, T-018 | Passed |
| T-011 Link resolution | Passed: all 42 cases that start inside an archive, run with links out of and into archives turned off (expected `host` and `archive` targets must come back unresolved). The 11 cases that start from a host file don't apply: this library has no host-file links. |
| T-016 Hostile content | Not applicable: it's a rendering test, and this library doesn't render |
| T-018 ZIP-bomb limits | Passed: `limit-high-ratio.mdz` and `limit-overlapping-entries.mdz` are rejected at open; `limit-forged-size.mdz` opens, `index.md` reads, and reading `data/blob.bin` fails with `ERR_LIMIT_EXCEEDED` after decompressing its declared 1 KiB |
| P-001 to P-008 | Passed. P-004 and P-005 run each round-trip flow twice. P-008: symbolic links are kept and reported. |

Archives written by the library also pass `mdz validate` (MDZip CLI 2.0.0) with no errors or warnings, and Python's `zipfile` reads them with every CRC intact.

T-014 passes by rejecting `unsupported-compression.mdz` with `ERR_ZIP_INVALID`; the library doesn't read BZIP2.

## Why no ZIP library

The other MDZip cores build on a well-maintained ZIP library. Lua doesn't have one that fits:

- `lua-zip` and `luazip` bind C libraries (libzip, zziplib). C modules have to be compiled for each platform, which rules them out in hosts that can't load them, such as Pandoc's built-in Lua, and neither project is actively maintained.
- LibDeflate, the best-known pure-Lua DEFLATE, decompresses a whole entry at once. The spec's ZIP-bomb rules need decompression that stops as soon as an entry exceeds its declared size.
- None of them exposes what the spec needs from the ZIP layer: the central directory's names and file types (to spot symbolic links), overlapping entries, and no ZIP64 unless needed.

So the container, DEFLATE and CRC-32 are part of the library, in about 650 lines of Lua. The compressor uses the fixed Huffman codes only, so archives are somewhat larger than zlib's. Speed is fine for documents: on a laptop, about 4 MB/s compressing text and 20 MB/s decompressing.

JSON and Unicode NFC aren't in Lua's standard library either. The JSON decoder is strict (RFC 8259) and reports duplicate member names, which general-purpose Lua JSON libraries don't. The NFC tables are generated from Unicode 16.0 by `tools/gen_unicode.py`.

## Development

```sh
lua tests/run.lua                                   # all tests; exit code 1 on failure
node ../mdzip-spec/tools/sync-fixtures.mjs tests/fixtures --ref v1.2.1   # update the fixtures (from a released tag)
python tools/gen_unicode.py                          # regenerate src/mdzip/unicode_data.lua
```

CI runs the tests on Lua 5.3 and 5.4.

## What's left to do

- Run CI. The tests have run locally on Lua 5.4.6 only; Lua 5.3 is supported by design but not yet tested.
- Publish to LuaRocks (`mdzip-core-lua-0.1.0-1.rockspec` is ready) and tag v0.1.0.
- Try it in its intended hosts: a Pandoc custom reader and writer, and a Neovim plugin. Pandoc's Lua is 5.4; Neovim uses LuaJIT, which this library doesn't support yet (it needs 5.3's integers, bitwise operators and `string.pack`).
- Dynamic Huffman compression, for smaller archives.
- Optional extensions, when a consumer needs them: configurable limits, links outside and into archives (spec 9.4–9.6), image analysis.
- Add the repo to the workspace manifest (`.github/docs/workspace.md`) and to mdzip.org's ecosystem list once it's published.

## License

Apache License 2.0. See [LICENSE](LICENSE).
