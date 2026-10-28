-- The spec's shared conformance tests (tests/fixtures, synced from a released
-- spec tag): consumer tests T-001..T-018 and producer checks P-001..P-008,
-- run through the library's public API.
local H = require("support.harness")
local sha256 = require("support.sha256")
local mdzip = require("mdzip")
local json = mdzip.json
local zip = require("mdzip.zip")           -- only to build test archives with unusual entries
local C = mdzip.codes

local FIX = "tests/fixtures/"

local function read(path)
  local fh = assert(io.open(path, "rb"))
  local d = fh:read("a")
  fh:close()
  return d
end

local function cases(file)
  local v = assert(json.decode(read(FIX .. file)))
  return v
end

local function open_fixture(name)
  return mdzip.open(read(FIX .. name))
end

-- Build an archive with exactly these entries (name -> content), bypassing
-- the producer rules, for inputs a conforming producer would never write.
local function raw_archive(list)
  local items = {}
  for _, e in ipairs(list) do
    local method, compressed, crc, size = zip.pack_content(e[1], e[2] or "")
    items[#items + 1] = { name = e[1], method = method, compressed = compressed, crc = crc, usize = size,
      mtime = 0, mdate = 33, made_by = e.made_by, external = e.external }
  end
  return zip.write(items)
end

---------------------------------------------------------------------------
-- Fixture integrity: the copy matches SPEC-FIXTURES.json.

H.check("fixtures", "SPEC-FIXTURES.json hashes", function()
  local marker = assert(json.decode(read(FIX .. "SPEC-FIXTURES.json")))
  local n = 0
  local files = marker.files
  for _, k in ipairs(json.keys(files)) do
    local expected = files[k]
    if type(expected) == "table" then expected = expected.sha256 end
    H.eq(sha256(read(FIX .. k)), expected, k)
    n = n + 1
  end
  H.ok(n > 0, "marker lists no files")
end)

---------------------------------------------------------------------------
-- Consumer tests

H.check("T-001", "minimal.mdz opens index.md", function()
  local a = assert(open_fixture("minimal.mdz"))
  H.eq(assert(a:entry_point()), "index.md")
  H.ok(#assert(a:read_text("index.md")) > 0, "index.md is empty")
end)

H.check("T-002", "with-manifest.mdz uses manifest entryPoint", function()
  local a = assert(open_fixture("with-manifest.mdz"))
  local m = assert(a:manifest())
  H.ok(type(m.entryPoint) == "string", "fixture manifest has an entryPoint")
  H.eq(assert(a:entry_point()), (m.entryPoint:gsub("^%./", "")))
  H.ok(a:validate().valid, "archive validates")
end)

for _, t in ipairs({ { "T-003", "invalid-missing-index.mdz" }, { "T-004", "invalid-bad-entrypoint.mdz" } }) do
  H.check(t[1], t[2] .. " rejects with ERR_ENTRYPOINT_MISSING", function()
    local a = assert(open_fixture(t[2]))
    local ep, err = a:entry_point()
    H.fails(C.ENTRYPOINT_MISSING, ep, err, "entry_point")
    local report = a:validate()
    H.ok(not report.valid, "validate reports the archive invalid")
  end)
end

H.check("T-005", "line-endings-crlf.mdz is read", function()
  local a = assert(open_fixture("line-endings-crlf.mdz"))
  local text = assert(a:read_text(assert(a:entry_point())))
  H.ok(text:find("\r\n", 1, true), "CRLF kept as stored")
end)

-- T-006 and T-008: every entrypoint case (with and without expectedError).
for i, c in ipairs(cases("entrypoint-cases.json")) do
  local id = c.expectedError ~= nil and c.expectedError ~= json.null and "T-008" or "T-006"
  H.check(id, "entrypoint case " .. i .. ": " .. c.name, function()
    local m = nil
    if type(c.manifestJson) == "string" then
      local state = mdzip.parse_manifest(c.manifestJson)
      m = state.manifest
    elseif c.manifest ~= json.null and c.manifest ~= nil then
      m = c.manifest
    end
    local files = {}
    for k = 1, #c.files do files[k] = c.files[k] end
    local ep, err = mdzip.find_entry_point(files, m)
    if c.expectedError ~= nil and c.expectedError ~= json.null then
      H.fails(c.expectedError, ep, err)
    elseif c.expectedEntryPoint == json.null then
      H.fails(C.ENTRYPOINT_UNRESOLVED, ep, err)
    else
      H.eq(ep, c.expectedEntryPoint)
    end
  end)
end

H.check("T-007", "minimal.mdz opens without a manifest, no findings", function()
  local a = assert(open_fixture("minimal.mdz"))
  H.ok(not a:has_manifest(), "fixture has no manifest")
  local report = a:validate()
  H.ok(report.valid, "valid")
  H.eq(#report.warnings, 0, "warnings")
  H.eq(assert(a:mode()), "document")
end)

for i, c in ipairs(cases("path-matching-cases.json")) do
  H.check("T-009", "path matching " .. i .. ": " .. c.name, function()
    H.eq(mdzip.same_path(c.entry, c.lookup), c.matches, "same_path")
    -- Through an archive whose stored name is exactly c.entry (not normalized).
    local a = assert(mdzip.open(raw_archive({ { c.entry, "x" } })))
    H.eq(a:find(c.lookup) ~= nil, c.matches, "archive:find")
    if c.matches then H.eq(a:find(c.lookup), c.entry, "find returns the stored name") end
  end)
end

H.check("T-010", "support files are detected without locale rules", function()
  local locales = { "tr_TR.UTF-8", "tr_TR", "Turkish_Turkey.1254", "Turkish" }
  local previous = os.setlocale(nil, "all")
  local set = nil
  for _, l in ipairs(locales) do set = set or os.setlocale(l, "all") end
  local ep, err = mdzip.find_entry_point({ "LICENSE.md", "notes.md" }, nil)
  os.setlocale(previous, "all")
  H.eq(ep, "notes.md", tostring(err))
  -- Without a Turkish locale installed the check still runs, it just can't
  -- prove locale independence; note it rather than fail.
  if set == nil then H.note("T-010", "no Turkish locale installed, so it ran in the default locale") end
end)

-- T-011: links. This library resolves inside archives only, so it runs the
-- archive-sourced cases with outsideLinks and intoArchiveLinks off: anything
-- that leaves the archive must come back unresolved, never another target.
do
  local lr = cases("link-resolution-cases.json")
  local host_from = 0
  for i, c in ipairs(lr.cases) do
    if c.from.archive then
      H.check("T-011", "link case " .. i .. ": " .. c.name, function()
        local spec = lr.host.archives[c.from.archive]
        local files = {}
        for k = 1, #spec.entries do files[k] = spec.entries[k] end
        local r = mdzip.resolve_link(files, c.from.path, c.link)
        local want = c.expected
        if want.kind == "internal" then
          H.eq(r.kind, "internal", "kind (reason " .. tostring(r.reason) .. ")")
          H.eq(r.entry, want.entry, "entry")
          H.eq(r.fragment, want.fragment ~= nil and want.fragment or nil, "fragment")
        elseif want.kind == "url" then
          H.eq(r.kind, "url", "kind")
        else
          -- unresolved, or host/archive targets this library doesn't support
          H.eq(r.kind, "unresolved", "kind (expected " .. want.kind .. ", unsupported here)")
        end
      end)
    else
      host_from = host_from + 1
    end
  end
  H.not_applicable("T-011", host_from .. " cases start from a host file; this library has no host-file links (optional, spec 9.4-9.5)")
end

for i, c in ipairs(cases("manifest-cases.json").cases) do
  H.check("T-012", "manifest case " .. i .. ": " .. c.name, function()
    local state = mdzip.parse_manifest(c.manifestJson)
    local e = c.expected
    if e.valid then
      H.eq(#state.errors, 0, "errors (" .. tostring(state.errors[1]) .. ")")
    else
      H.ok(#state.errors > 0, "expected " .. e.errorCode)
      H.eq(state.errors[1].code, e.errorCode, "error code")
    end
    local ignored = {}
    for _, w in ipairs(state.warnings) do
      if w.code == "WARN_MANIFEST_FIELD_IGNORED" then ignored[#ignored + 1] = w.field end
    end
    table.sort(ignored)
    local want = {}
    for k = 1, #(e.ignoredFields or {}) do want[k] = e.ignoredFields[k] end
    table.sort(want)
    H.eq(table.concat(ignored, ","), table.concat(want, ","), "ignored fields")
    local dups = #(state.duplicates or {}) > 0
    H.eq(dups, e.duplicateMembers == true, "duplicate members reported")
    if e.values then
      for _, pointer in ipairs(json.keys(e.values)) do
        H.ok(json.equal(json.pointer(state.manifest, pointer), e.values[pointer]), "value at " .. pointer)
      end
    end
  end)
end

for i, c in ipairs(cases("entry-set-cases.json").cases) do
  H.check("T-013", "entry set " .. i .. ": " .. c.name, function()
    local names = {}
    for k = 1, #c.entries do names[k] = c.entries[k] end
    local ok, err = mdzip.check_entry_names(names)
    if c.valid then
      H.ok(ok, tostring(err))
    else
      H.fails(c.errorCode, ok, err)
    end
    -- The same names in a real archive: open() must reject the invalid sets.
    local list = {}
    for k, n in ipairs(names) do list[k] = { n, n:sub(-1) == "/" and "" or "x" } end
    local a, oerr = mdzip.open(raw_archive(list))
    if c.valid then H.ok(a, "open: " .. tostring(oerr)) else H.fails(c.errorCode, a, oerr, "open") end
  end)
end

H.check("T-014", "unsupported-compression.mdz is rejected with ERR_ZIP_INVALID", function()
  local a, err = open_fixture("unsupported-compression.mdz")
  H.fails(C.ZIP_INVALID, a, err, "open")
end)

H.check("T-015", "project-mode.mdz: each document opens on its own", function()
  local a = assert(open_fixture("project-mode.mdz"))
  H.eq(assert(a:mode()), "project")
  H.eq(assert(a:entry_point()), "index.md")
  for _, doc in ipairs({ "index.md", "chapters/one.md", "chapters/two.md" }) do
    local text = assert(a:read_text(doc))
    H.ok(#text > 0, doc .. " is empty")
  end
  local docs = a:documents()
  H.ok(#docs >= 3, "documents() lists each document")
end)

H.not_applicable("T-016", "hostile content is a rendering test; this library doesn't render Markdown")

H.check("T-017", "symlink-entries.mdz: links are never followed", function()
  local spec
  for _, c in ipairs(cases("archive-cases.json").cases) do if c.id == "symlink-entries" then spec = c end end
  local a = assert(open_fixture("symlink-entries.mdz"))
  H.eq(assert(a:entry_point()), spec.expectedEntryPoint)
  local special = {}
  for _, s in ipairs(a:special_entries()) do special[s.path] = s.kind end
  for _, name in ipairs(json.keys(spec.symlinks)) do
    H.eq(special[name], "symlink", name .. " reported as a symlink")
    H.ok(not a:has(name), name .. " is not readable as a file")
  end
  for _, l in ipairs(spec.links) do
    local r = a:resolve_link("index.md", l.href)
    if l.expected == "resolved" then
      H.eq(r.kind, "internal", l.href)
      H.eq(r.entry, l.target, l.href)
    else
      H.eq(r.kind, "unresolved", l.href .. " (" .. l.expected .. ")")
    end
  end
  local reported = 0
  for _, w in ipairs(a:validate().warnings) do if w.code == "WARN_SPECIAL_ENTRY" then reported = reported + 1 end end
  H.eq(reported, 3, "each symbolic link reported")
end)

H.check("T-018", "limit-forged-size.mdz: reading the entry fails with a stable code", function()
  local a, err = open_fixture("limit-forged-size.mdz")
  if not a then H.fails({ C.ZIP_INVALID, C.LIMIT_EXCEEDED }, a, err, "open"); return end
  H.ok(a:read_text(assert(a:entry_point())), "index.md reads normally")
  local t0 = os.clock()
  local data, rerr = a:read("data/blob.bin")
  H.fails({ C.ZIP_INVALID, C.LIMIT_EXCEEDED }, data, rerr, "read data/blob.bin")
  H.ok(os.clock() - t0 < 2, "stopped early (took " .. (os.clock() - t0) .. "s)")
end)
H.check("T-018", "limit-high-ratio.mdz is rejected", function()
  local a, err = open_fixture("limit-high-ratio.mdz")
  if not a then H.fails(C.LIMIT_EXCEEDED, a, err, "open"); return end
  H.ok(a:read_text(assert(a:entry_point())), "index.md reads normally")
  local data, rerr = a:read("data/zeros.bin")
  H.fails(C.LIMIT_EXCEEDED, data, rerr, "read data/zeros.bin")
end)
H.check("T-018", "limit-overlapping-entries.mdz is rejected at open", function()
  local a, err = open_fixture("limit-overlapping-entries.mdz")
  H.fails({ C.LIMIT_EXCEEDED, C.ZIP_INVALID }, a, err, "open")
end)

---------------------------------------------------------------------------
-- Producer checks

local function created_manifest(bytes)
  local a = assert(mdzip.open(bytes))
  return a, assert(a:manifest())
end

H.check("P-001", "a new archive has a complete manifest", function()
  local bytes = assert(mdzip.create({
    files = { { path = "index.md", text = "# Hello\n" }, { path = "images/a.png", data = "\137PNG fake" } },
    title = "Hello", application = { name = "tests", version = "1" },
  }))
  local a, m = created_manifest(bytes)
  H.ok(mdzip.json.is_object(m.spec) and type(m.spec.version) == "string", "spec.version")
  H.eq(m.entryPoint, "index.md", "entryPoint")
  H.ok(a:has(m.entryPoint) and mdzip.is_markdown(m.entryPoint), "entryPoint names a Markdown file in the archive")
  H.eq(m.title, "Hello", "title")
  H.eq(m.mode, "document", "mode")
  local report = a:validate()
  H.ok(report.valid and #report.warnings == 0, "created archive validates with no warnings")
end)

H.check("P-002", "adding a support file to a manifest-less archive adds a manifest", function()
  local a = assert(mdzip.open(raw_archive({ { "notes.md", "# Notes\n" } })))
  local bytes = assert(a:update({ put = { { path = "AGENTS.md", text = "# Agents\n" } } }))
  local b, m = created_manifest(bytes)
  H.eq(m.entryPoint, "notes.md", "manifest entryPoint")
  H.eq(assert(b:entry_point()), "notes.md")
end)

H.check("P-003", "a second support file makes the producer record the entry point", function()
  local a = assert(mdzip.open(raw_archive({ { "README.md", "# Read me\n" } })))
  local bytes = assert(a:update({ put = { { path = "AGENTS.md", text = "# Agents\n" } } }))
  local b, m = created_manifest(bytes)
  H.eq(m.entryPoint, "README.md", "manifest entryPoint")
  H.eq(assert(b:entry_point()), "README.md")
end)

-- P-004 / P-005: round-trip flows, each run twice.
do
  local rt = cases("round-trip-expectations.json")
  local function check_saved(id, flow, bytes, changed)
    local a = assert(mdzip.open(bytes))
    if id == "P-004" then
      local m = assert(a:manifest())
      for _, pv in ipairs(rt.preservedManifestValues) do
        H.ok(json.equal(json.pointer(m, pv.pointer), pv.value), flow.name .. ": " .. pv.pointer .. " preserved")
      end
    else
      for _, pe in ipairs(rt.preservedEntries) do
        if changed[pe.path] == "removed" then
          H.ok(not a:has(pe.path), flow.name .. ": " .. pe.path .. " removed")
        elseif not changed[pe.path] then
          local d = assert(a:read(pe.path))
          H.eq(#d, pe.bytes, flow.name .. ": " .. pe.path .. " length")
          H.eq(sha256(d), pe.sha256, flow.name .. ": " .. pe.path .. " sha256")
        end
      end
    end
  end
  for _, id in ipairs({ "P-004", "P-005" }) do
    for _, flow in ipairs(rt.flows) do
      H.check(id, flow.name, function()
        local bytes = read(FIX .. "round-trip.mdz")
        local changed = {}
        for k = 1, #flow.changes do changed[flow.changes[k]] = true end
        for k = 1, #(flow.removes or {}) do changed[flow.removes[k]] = "removed" end
        for _ = 1, 2 do
          local a = assert(mdzip.open(bytes))
          local ch = {}
          if flow.name:find("manifest field") then
            ch.manifest = { title = "Edited title" }
          elseif flow.name:find("edit document") then
            ch.put = { { path = "index.md", text = assert(a:read_text("index.md")) .. "\nAppended line.\n" } }
          elseif flow.name:find("add a resource") then
            ch.put = { { path = "images/added.png", data = "\137PNG\r\n\26\nnot really" } }
          elseif flow.name:find("remove") then
            local text = assert(a:read_text("index.md"))
            local without = text:gsub("[^\n]*docs/guide%.md[^\n]*\n?", "")
            ch.put = { { path = "index.md", text = without } }
            if a:has("docs/guide.md") then ch.remove = { "docs/guide.md" } end
          end
          local out, report = a:update(ch)
          H.ok(out, flow.name .. ": update failed: " .. tostring(report))
          bytes = out
          check_saved(id, flow, bytes, changed)
        end
      end)
    end
  end
end

H.check("P-006", "create always writes a manifest", function()
  local bytes = assert(mdzip.create({ files = { { path = "notes.md", text = "x" } } }))
  local a = assert(mdzip.open(bytes))
  H.ok(a:has_manifest(), "manifest written")
  H.eq(assert(a:entry_point()), "notes.md")
end)
H.check("P-006", "saving an edit to a manifest-less archive keeps its entry point", function()
  local a = assert(mdzip.open(raw_archive({ { "index.md", "# A\n" }, { "other.md", "# B\n" } })))
  local bytes = assert(a:update({ put = { { path = "index.md", text = "# A, edited\n" } } }))
  local b = assert(mdzip.open(bytes))
  H.eq(assert(b:entry_point()), "index.md")
end)

H.check("P-007", "entry names and ZIP flags", function()
  local bytes = assert(mdzip.create({
    files = {
      { path = "index.md", text = "# Café\n" },
      { path = "docs/caf\u{e9}/menu.md", text = "menu" },        -- non-ASCII: needs bit 11
      { path = "docs/cafe\u{301}-nfd.md", text = "nfd name" },  -- NFD input, written as NFC
      { path = "images/logo.png", data = string.rep("\0", 100) },
    },
  }))
  local records = zip.read(bytes)
  for _, e in ipairs(records) do
    H.ok(e.method == 0 or e.method == 8, e.name .. " method " .. e.method)
    H.eq(e.kind, "file", e.name .. " kind")
    if e.name:find("[\128-\255]") then H.ok(e.flags & 0x0800 ~= 0, e.name .. " has the UTF-8 flag") end
    H.ok(e.name:find("//", 1, true) == nil and e.name:find("/./", 1, true) == nil, e.name .. " segments")
    H.eq(e.name, mdzip.nfc(e.name), e.name .. " is NFC")
  end
  local a = assert(mdzip.open(bytes))
  local _, dups = json.decode(assert(a:read_text("manifest.json")))
  H.eq(#dups, 0, "duplicate manifest members")
  H.ok(a:validate().valid, "validates")
end)

H.check("P-008", "editing an archive with symbolic links keeps them and says so", function()
  local a = assert(open_fixture("symlink-entries.mdz"))
  local bytes, report = a:update({ put = { { path = "notes.md", text = "# Notes, edited\n" } } })
  H.ok(bytes, tostring(report))
  local kept = 0
  for _, w in ipairs(report.warnings) do if w.code == "WARN_SPECIAL_ENTRY_KEPT" then kept = kept + 1 end end
  H.eq(kept, 3, "each kept symbolic link is reported")
  local b = assert(mdzip.open(bytes))
  local count = 0
  for _, s in ipairs(b:special_entries()) do if s.kind == "symlink" then count = count + 1 end end
  H.eq(count, 3, "symbolic links kept, not dropped and not added")
  H.ok(b:read_text("notes.md"):find("edited"), "edit saved")
end)
