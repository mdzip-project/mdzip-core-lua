-- Unit tests for the public API beyond the spec fixtures.
local H = require("support.harness")
local mdzip = require("mdzip")
local json = mdzip.json
local zip = require("mdzip.zip")
local C = mdzip.codes

local function raw_archive(list)
  local items = {}
  for _, e in ipairs(list) do
    local method, compressed, crc, size = zip.pack_content(e[1], e[2] or "")
    items[#items + 1] = { name = e[1], method = method, compressed = compressed, crc = crc, usize = size, mtime = 0, mdate = 33 }
  end
  return zip.write(items)
end

local function sample()
  return assert(mdzip.create({
    files = {
      { path = "index.md", text = "# Guide\r\n\r\n![Logo](images/logo.png)\r\n" },
      { path = "chapters/one.md", text = "# One\n" },
      { path = "images/logo.png", data = "\137PNG\r\n\26\n" .. string.rep("\1\2\3", 50) },
    },
    title = "Guide",
    manifest = { author = { name = "Ada" }, language = "en", ["x-tool"] = { keep = true } },
    time = 1767225600, -- 2026-01-01T00:00:00Z
  }))
end

-- R1/R2: open and inspect

H.check("open", "create then open", function()
  local a = assert(mdzip.open(sample()))
  H.eq(assert(a:entry_point()), "index.md")
  H.eq(a:title(), "Guide")
  H.eq(a:spec_version(), mdzip.SPEC_VERSION)
  H.eq(#a:files(), 4)
  H.eq(table.concat(a:documents(), ","), "index.md,chapters/one.md")
  H.eq(assert(a:read_text("index.md")), "# Guide\n\n![Logo](images/logo.png)\n", "Markdown written with LF")
  H.eq(assert(a:manifest()).created.when, "2026-01-01T00:00:00Z")
  local kinds = {}
  for _, e in ipairs(a:entries()) do kinds[#kinds + 1] = e.kind end
  H.eq(table.concat(kinds, ","), "file,file,file,file")
end)

H.check("open", "not a ZIP", function()
  H.fails(C.ZIP_INVALID, mdzip.open("hello, world"))
  H.fails(C.ARGUMENT, mdzip.open(42))
end)

H.check("open", "missing file and near match", function()
  local a = assert(mdzip.open(sample()))
  local d, err = a:read("Index.md")
  H.fails(C.NOT_FOUND, d, err)
  H.eq(err.suggestion, "index.md")
  H.eq(a:find("Index.md"), nil, "never a case-insensitive match")
end)

H.check("open", "text that isn't UTF-8", function()
  local a = assert(mdzip.open(raw_archive({ { "index.md", "ok" }, { "bad.txt", "\255\254" } })))
  H.fails(C.TEXT_INVALID, a:read_text("bad.txt"))
  H.eq(assert(a:read("bad.txt")), "\255\254")
end)

H.check("open", "directory entries", function()
  local a = assert(mdzip.open(raw_archive({ { "docs/", "" }, { "docs/a.md", "a" }, { "index.md", "i" } })))
  H.eq(table.concat(a:directories(), ","), "docs/")
  H.eq(a:has("docs/"), false)
  H.eq(table.concat(a:files(), ","), "docs/a.md,index.md")
end)

-- R7: unsafe archives

H.check("safety", "unsafe entry names are rejected at open", function()
  for _, bad in ipairs({ "../escape.md", "/abs.md", "a\\b.md", "docs//x.md", "./index.md", "con:x.md" }) do
    local a, err = mdzip.open(raw_archive({ { "index.md", "x" }, { bad, "y" } }))
    H.fails(C.PATH_INVALID, a, err, bad)
  end
end)

H.check("safety", "encrypted entries", function()
  local bytes = raw_archive({ { "index.md", "x" } })
  -- Set general purpose bit 0 (encrypted) in the local and central headers.
  local cd = bytes:find("PK\1\2", 1, true)
  local patched = bytes:sub(1, 6) .. "\1" .. bytes:sub(8, cd + 7) .. "\1" .. bytes:sub(cd + 9)
  H.fails(C.ZIP_ENCRYPTED, mdzip.open(patched))
end)

H.check("safety", "corrupt data fails with a stable code", function()
  local bytes = assert(mdzip.create({ files = { { path = "index.md", text = string.rep("hello world ", 200) } } }))
  local a = assert(mdzip.open(bytes))
  local rec
  for _, r in ipairs(a.records) do if r.name == "index.md" then rec = r end end
  local p = rec.data_start + 5
  local broken = bytes:sub(1, p - 1) .. string.char((bytes:byte(p) + 1) % 256) .. bytes:sub(p + 1)
  local b = assert(mdzip.open(broken))
  H.fails({ C.ZIP_INVALID, C.LIMIT_EXCEEDED }, b:read("index.md"))
end)

H.check("safety", "entry count limit", function()
  local archive = require("mdzip.archive")
  local limits = {}
  for k, v in pairs(mdzip.LIMITS) do limits[k] = v end
  limits.max_entries = 2
  H.fails(C.LIMIT_EXCEEDED, archive.open(raw_archive({ { "a.md", "" }, { "b.md", "" }, { "c.md", "" } }), limits))
end)

-- R4: validation findings

H.check("validate", "manifest problems are reported", function()
  local bytes = raw_archive({ { "manifest.json", '{"mode":"Project","title":"","cover":"nope.png","entryPoint":"index.md"}' }, { "index.md", "x" } })
  local report = mdzip.validate(bytes)
  H.eq(report.valid, false)
  H.eq(report.errors[1].code, C.MODE_UNSUPPORTED)
  local codes = {}
  for _, w in ipairs(report.warnings) do codes[#codes + 1] = w.code .. (w.field and (":" .. w.field) or "") end
  table.sort(codes)
  H.eq(table.concat(codes, " "), "WARN_COVER_MISSING WARN_MANIFEST_FIELD_IGNORED:title")
  local a = assert(mdzip.open(bytes))
  H.fails(C.MODE_UNSUPPORTED, a:mode())
  H.eq(assert(a:entry_point()), "index.md", "entry point still resolves")
end)

H.check("validate", "unreadable manifest never falls back", function()
  local a = assert(mdzip.open(raw_archive({ { "manifest.json", "{not json" }, { "index.md", "x" } })))
  H.fails(C.MANIFEST_INVALID, a:entry_point())
  H.fails(C.MANIFEST_INVALID, a:manifest())
  H.fails(C.MANIFEST_INVALID, a:mode())
end)

H.check("validate", "newer major version is rejected", function()
  local a = assert(mdzip.open(raw_archive({ { "manifest.json", '{"spec":{"version":"2.0.0"}}' }, { "index.md", "x" } })))
  H.fails(C.VERSION_UNSUPPORTED, a:entry_point())
  H.fails(C.VERSION_UNSUPPORTED, a:update({ put = { { path = "x.md", text = "x" } } }))
end)

H.check("validate", "case-only collisions and missing UTF-8 flag", function()
  local items = {}
  for _, n in ipairs({ "Index.md", "index.md", "caf\u{e9}.md" }) do
    local method, compressed, crc, size = zip.pack_content(n, "x")
    items[#items + 1] = { name = n, method = method, compressed = compressed, crc = crc, usize = size, mtime = 0, mdate = 33 }
  end
  local bytes = zip.write(items)
  -- Clear bit 11 everywhere to imitate a tool that doesn't set it.
  bytes = bytes:gsub("(PK\3\4..)\0\8", "%1\0\0"):gsub("(PK\1\2....)\0\8", "%1\0\0")
  local report = mdzip.validate(bytes)
  H.ok(report.valid, "still valid")
  local codes = {}
  for _, w in ipairs(report.warnings) do codes[w.code] = (codes[w.code] or 0) + 1 end
  H.eq(codes.WARN_CASE_COLLISION, 1, "case collision")
  H.eq(codes.WARN_UTF8_FLAG_MISSING, 1, "UTF-8 flag")
end)

-- R5: create

H.check("create", "entry point discovery and errors", function()
  H.fails(C.ENTRYPOINT_UNRESOLVED, mdzip.create({ files = { { path = "a.md", text = "a" }, { path = "b.md", text = "b" } } }))
  H.fails(C.ENTRYPOINT_MISSING, mdzip.create({ files = { { path = "a.md", text = "a" } }, entry_point = "b.md" }))
  H.fails(C.ENTRYPOINT_INVALID, mdzip.create({ files = { { path = "a.md", text = "a" } }, entry_point = "a.txt" }))
  local a = assert(mdzip.open(assert(mdzip.create({ files = { { path = "a.md", text = "a" }, { path = "b.md", text = "b" } }, entry_point = "b.md" }))))
  H.eq(assert(a:entry_point()), "b.md")
end)

H.check("create", "rejects bad input", function()
  H.fails(C.PATH_INVALID, mdzip.create({ files = { { path = "../x.md", text = "x" } } }))
  H.fails(C.ARGUMENT, mdzip.create({ files = { { path = "manifest.json", text = "{}" } } }))
  H.fails(C.DUPLICATE_PATH, mdzip.create({ files = { { path = "caf\u{e9}.md", text = "x" }, { path = "cafe\u{301}.md", text = "y" } } }))
  H.fails(C.PATH_CONFLICT, mdzip.create({ files = { { path = "index.md", text = "x" }, { path = "docs", data = "" }, { path = "docs/a.md", text = "y" } } }))
  H.fails(C.TEXT_INVALID, mdzip.create({ files = { { path = "index.md", data = "\255" } } }))
  H.fails(C.MODE_UNSUPPORTED, mdzip.create({ files = { { path = "index.md", text = "x" } }, mode = "book" }))
  H.fails(C.MANIFEST_INVALID, mdzip.create({ files = { { path = "index.md", text = "x" } }, title = "" }))
  H.fails(C.MANIFEST_INVALID, mdzip.create({ files = { { path = "index.md", text = "x" } }, manifest = { cover = "missing.png" } }))
  H.fails(C.ARGUMENT, mdzip.create({ files = { { path = "index.md", text = "x" } }, manifest = { entryPoint = "index.md" } }))
end)

H.check("create", "large and binary content round-trips", function()
  math.randomseed(7)
  local r = {}
  for i = 1, 100000 do r[i] = string.char(math.random(0, 255)) end
  local noise = table.concat(r)
  local text = string.rep("Some *Markdown* text with words that repeat.\n", 5000)
  local a = assert(mdzip.open(assert(mdzip.create({ files = {
    { path = "index.md", text = text }, { path = "data/noise.bin", data = noise },
  } }))))
  H.eq(assert(a:read("data/noise.bin")), noise)
  H.eq(assert(a:read_text("index.md")), text)
  local sizes = {}
  for _, e in ipairs(a:entries()) do sizes[e.path] = e end
  H.ok(sizes["index.md"].compressed_size < #text / 10, "text is compressed")
  H.eq(sizes["data/noise.bin"].method, 0, "incompressible data is stored")
end)

-- R6: update

H.check("update", "keeps untouched entries byte for byte", function()
  local bytes = sample()
  local a = assert(mdzip.open(bytes))
  local out = assert(a:update({ put = { { path = "chapters/two.md", text = "# Two\n" } } }, { time = 1767312000 }))
  local b = assert(mdzip.open(out))
  for _, name in ipairs({ "index.md", "chapters/one.md", "images/logo.png" }) do
    H.eq(assert(b:read(name)), assert(a:read(name)), name)
  end
  local m = assert(b:manifest())
  H.eq(m["x-tool"].keep, true, "unknown field kept")
  H.eq(m.author.name, "Ada")
  H.eq(m.modified.when, "2026-01-02T00:00:00Z", "modified updated")
  H.eq(m.created.when, "2026-01-01T00:00:00Z", "created unchanged")
end)

H.check("update", "manifest fields: set, remove, application", function()
  local a = assert(mdzip.open(sample()))
  local out = assert(a:update({ manifest = { title = "New", language = mdzip.REMOVE } }, { application = { name = "App", version = "2" } }))
  local m = assert(assert(mdzip.open(out)):manifest())
  H.eq(m.title, "New")
  H.eq(m.language, nil)
  H.eq(m.producer.application.name, "App")
  H.eq(m.producer.core.name, "mdzip-core-lua", "core kept")
end)

H.check("update", "refuses to break or move the entry point", function()
  local a = assert(mdzip.open(sample()))
  H.fails(C.ENTRYPOINT_MISSING, a:update({ remove = { "index.md" } }))
  local out = assert(a:update({ entry_point = "chapters/one.md" }))
  H.eq(assert(assert(mdzip.open(out)):entry_point()), "chapters/one.md")
  H.fails(C.ENTRYPOINT_MISSING, a:update({ entry_point = "missing.md" }))
  -- Without a manifest, adding a file that changes discovery must not move it.
  local plain = assert(mdzip.open(raw_archive({ { "notes.md", "n" } })))
  local kept = assert(plain:update({ put = { { path = "index.md", text = "i" } } }))
  H.eq(assert(assert(mdzip.open(kept)):entry_point()), "notes.md", "manifest added to keep notes.md")
end)

H.check("update", "other failures leave nothing half done", function()
  local a = assert(mdzip.open(sample()))
  H.fails(C.NOT_FOUND, a:update({ remove = { "nope.md" } }))
  H.fails(C.PATH_CONFLICT, a:update({ put = { { path = "chapters", data = "x" } } }))
  H.fails(C.ARGUMENT, a:update({ remove = { "manifest.json" } }))
  H.fails(C.MANIFEST_INVALID, a:update({ manifest = { keywords = "not a list" } }))
end)

H.check("update", "a kept problem is reported, not fixed silently", function()
  local a = assert(mdzip.open(raw_archive({ { "manifest.json", '{"title":"","entryPoint":"index.md","x":1}' }, { "index.md", "x" } })))
  local out, report = a:update({ put = { { path = "index.md", text = "y" } } })
  H.ok(out, tostring(report))
  H.eq(report.warnings[1].code, "WARN_STILL_NONCONFORMING")
  H.eq(assert(assert(mdzip.open(out)):manifest()).x, 1)
end)

-- Files on disk

local function slurp(path)
  local fh = assert(io.open(path, "rb"))
  local d = fh:read("a")
  fh:close() -- Windows can't replace a file that is still open
  return d
end

H.check("files", "create_file, update_file and a failed update", function()
  local path = os.tmpname()
  os.remove(path)
  path = path .. ".mdz"
  assert(mdzip.create_file(path, { files = { { path = "index.md", text = "# File\n" } } }))
  local before = slurp(path)
  local report = assert(mdzip.update_file(path, { put = { { path = "two.md", text = "2" } } }))
  H.ok(report.warnings, "report")
  H.ok(assert(mdzip.open_file(path)):has("two.md"), "update saved")
  local saved = slurp(path)
  H.ok(saved ~= before, "file changed")
  H.fails(C.ENTRYPOINT_MISSING, mdzip.update_file(path, { remove = { "index.md" } }))
  H.eq(slurp(path), saved, "failed update left the file alone")
  os.remove(path)
  H.fails(C.IO, mdzip.open_file(path))
end)

-- JSON

H.check("json", "round trip keeps types and order", function()
  local text = '{"b":1,"a":[1,2.5,"x",true,false,null,{},[]],"c":{"z":null}}'
  local v = assert(json.decode(text))
  local again = assert(json.decode(json.encode(v)))
  H.ok(json.equal(v, again), "equal after encode/decode")
  H.eq(table.concat(json.keys(again), ","), "b,a,c", "member order")
  H.eq(math.type(again.b), "integer")
  H.ok(json.is_object(again.a[7]) and json.is_array(again.a[8]), "{} and [] kept apart")
  H.eq(again.c.z, json.null)
end)

H.check("json", "rejects what RFC 8259 rejects", function()
  for _, bad in ipairs({ "{,}", "[1,]", "01", "1.", ".5", "'x'", '"\1"', '"\\x"', '"\\ud800"', "nul", "{} x", "" }) do
    H.eq(json.decode(bad), nil, bad)
  end
end)

-- Unicode

H.check("unicode", "NFC", function()
  local nfc = mdzip.nfc
  H.eq(nfc("cafe\u{301}"), "caf\u{e9}")
  H.eq(nfc("\u{1100}\u{1161}\u{11A8}"), "\u{AC01}", "Hangul LVT")
  H.eq(nfc("a\u{323}\u{302}"), "\u{1EAD}", "reordered marks compose")
  H.eq(nfc("\u{212B}"), "\u{C5}", "singleton decomposition")
  H.eq(nfc("\u{FB01}"), "\u{FB01}", "compatibility character unchanged")
end)
