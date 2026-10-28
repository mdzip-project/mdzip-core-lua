-- A tiny test harness. Results are grouped by ID: a spec test ID such as
-- "T-001" (from the fixtures README) or a unit-test group name.
local H = { groups = {}, order = {} }

local NA = {}

local function group(id)
  local g = H.groups[id]
  if not g then
    g = { id = id, passed = 0, failed = {}, na = nil }
    H.groups[id] = g
    H.order[#H.order + 1] = id
  end
  return g
end

-- Mark a test ID as not applicable, with the reason.
function H.not_applicable(id, reason)
  group(id).na = reason
end

-- Add a note to a test ID's result line (for example, a check that ran with
-- less coverage than usual). It doesn't change the result.
function H.note(id, text)
  group(id).na = text
end

-- Run one check under a test ID.
function H.check(id, name, fn)
  local g = group(id)
  local ok, err = xpcall(fn, function(e)
    if type(e) == "table" and e[NA] then return e end
    return debug.traceback(tostring(e), 2)
  end)
  if ok then
    g.passed = g.passed + 1
  elseif type(err) == "table" and err[NA] then
    g.na = err.reason
  else
    g.failed[#g.failed + 1] = name .. ": " .. tostring(err)
  end
end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function H.eq(actual, expected, what)
  if actual ~= expected then
    error((what and (what .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function H.ok(cond, what)
  if not cond then error(what or "assertion failed", 2) end
  return cond
end

-- Assert that `fn` (or a nil, err pair) failed with one of the given codes.
function H.fails(code_or_codes, value, err, what)
  local codes = type(code_or_codes) == "table" and code_or_codes or { code_or_codes }
  if value ~= nil then error((what or "call") .. " succeeded; expected " .. table.concat(codes, " or "), 2) end
  if type(err) ~= "table" or not err.code then error((what or "call") .. " failed without a stable code: " .. tostring(err), 2) end
  for _, c in ipairs(codes) do if err.code == c then return err end end
  error((what or "call") .. ": expected " .. table.concat(codes, " or ") .. ", got " .. tostring(err), 2)
end

function H.report()
  local failed_ids, total_failed = {}, 0
  print(string.format("%-8s %-15s %s", "ID", "RESULT", "DETAIL"))
  for _, id in ipairs(H.order) do
    local g = H.groups[id]
    local result, detail
    if #g.failed > 0 then
      result = "FAILED"
      detail = string.format("%d of %d checks failed", #g.failed, #g.failed + g.passed)
      failed_ids[#failed_ids + 1] = g
      total_failed = total_failed + #g.failed
    elseif g.na and g.passed == 0 then
      result, detail = "NOT APPLICABLE", g.na
    else
      result = "passed"
      detail = string.format("%d checks", g.passed) .. (g.na and ("; " .. g.na) or "")
    end
    print(string.format("%-8s %-15s %s", id, result, detail))
  end
  for _, g in ipairs(failed_ids) do
    print("\n" .. g.id .. " failures:")
    for _, f in ipairs(g.failed) do print("  - " .. f) end
  end
  return total_failed == 0
end

return H
