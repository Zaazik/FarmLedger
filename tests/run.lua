-- Test runner: lua tests/run.lua (from the addon root). Lua 5.4 with WoW Lua 5.1 shims.
unpack = unpack or table.unpack

local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path

local ns = {}
assert(loadfile(root .. "/Core/Ledger.lua"))("FarmLedger", ns)

local passed, failed = 0, 0
local T = { root = root }
function T.eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
	end
end
function T.truthy(v, msg) if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end end

for _, f in ipairs({ "test_ledger", "test_game" }) do
	for _, case in ipairs(require(f)(ns, T)) do
		local ok, err = pcall(case[2])
		if ok then
			passed = passed + 1
		else
			failed = failed + 1
			print(string.format("FAIL %s / %s\n    %s", f, case[1], err))
		end
	end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
