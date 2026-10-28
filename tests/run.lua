-- Run all tests from the repository root:  lua tests/run.lua
package.path = "src/?.lua;src/?/init.lua;tests/?.lua;" .. package.path

local H = require("support.harness")
print("mdzip-core-lua " .. require("mdzip").VERSION .. " on " .. _VERSION .. "\n")

require("conformance")
require("api")

local ok = H.report()
os.exit(ok and 0 or 1)
