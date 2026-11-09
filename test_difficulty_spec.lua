-- Difficulty guarantees for Numberlink (see docs/dev/TESTING.md,
-- "Difficulty specs"): every size x level is finished by the game's own
-- no-trial solver within its tier (Easy and Medium tier 1), small grids have
-- one solution by exhaustive count, Easy/Medium/Hard are ordered on colours
-- (fewer, longer paths) and on reasoning work, side-by-side pairs stay a
-- minority, a seed gives the same puzzle, and generation is quick and never
-- reads the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

describe("Numberlink difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function flatClues(b)
        local clue = {}
        for r = 1, b.n do for c = 1, b.n do clue[(r - 1) * b.n + c] = b.clues[r][c] end end
        return clue
    end

    it("the level table is ordered", function()
        for _, n in ipairs({ 5, 7, 9, 10 }) do
            local e, m, h = Board._levelFor(n, "easy"), Board._levelFor(n, "medium"), Board._levelFor(n, "hard")
            assert.is_true(e.min_colours > m.max_colours and m.min_colours > h.max_colours, n .. ": colours")
            assert.is_true(e.tier <= m.tier and m.tier <= h.tier)
            assert.is_true(e.min_work <= m.min_work and m.min_work <= h.min_work, n .. ": work")
            assert.is_true(e.tier == 1 and h.tier <= 2)
        end
    end)

    -- moved from test_board_spec.lua
    -- 1.6.0: random paths instead of the cut-up snake, a no-trial solver,
    -- and levels that really differ (Hard used to be the easiest).
    describe("levels (1.6.0)", function()
        local SIZES, LEVELS = { 5, 7, 9, 10 }, { "easy", "medium", "hard" }
        local SEEDS = 10
        local results = {}   -- results[n][level] = list of { k=, work=, two= }

        setup(function()
            for _, n in ipairs(SIZES) do
                results[n] = {}
                for _, d in ipairs(LEVELS) do
                    local list = {}
                    for seed = 1, SEEDS do
                        math.randomseed(1000 * n + seed)
                        local b = Board:new{ n = n }
                        b:generate(d)
                        local lv = Board._levelFor(n, d)
                        local ok, st = Board._logicSolve(flatClues(b), n, b.n_colors, lv.tier)
                        local cnt = {}
                        for r = 1, n do for c = 1, n do
                            local v = b.solution[r][c]; cnt[v] = (cnt[v] or 0) + 1
                        end end
                        local two = 0
                        for col = 1, b.n_colors do if cnt[col] == 2 then two = two + 1 end end
                        list[#list + 1] = { b = b, lv = lv, ok = ok, st = st, k = b.n_colors,
                                            work = ok and Board._workOf(st), two = two }
                    end
                    results[n][d] = list
                end
            end
        end)

        it("every puzzle is finished by reasoning alone, within its level's tier", function()
            for _, n in ipairs(SIZES) do
                for _, d in ipairs(LEVELS) do
                    for s, r in ipairs(results[n][d]) do
                        local where = ("%dx%d %s seed %d"):format(n, n, d, s)
                        assert.is_true(r.ok, where)
                        assert.is_false(r.b.gen_info.rescued, where)
                        assert.is_true(r.k >= r.lv.min_colours and r.k <= r.lv.max_colours, where)
                        if d ~= "hard" then
                            assert.are.equal(0, r.st.t2, where)
                        end
                        -- the solver's colours are the stored solution
                        local _, _, owner = Board._logicSolve(flatClues(r.b), n, r.k, 2)
                        for i = 1, n * n do
                            local row, col = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
                            assert.are.equal(r.b.solution[row][col], owner[i], where)
                        end
                    end
                end
            end
        end)

        it("Easy, Medium and Hard differ: fewer, longer paths and more reasoning", function()
            for _, n in ipairs(SIZES) do
                local mk, mw = {}, {}
                for li, d in ipairs(LEVELS) do
                    local k, w = 0, 0
                    for _, r in ipairs(results[n][d]) do k = k + r.k; w = w + r.work end
                    mk[li], mw[li] = k / SEEDS, w / SEEDS
                end
                assert.is_true(mk[1] > mk[2] and mk[2] > mk[3], n .. ": colours")
                assert.is_true(mw[1] < mw[2] and mw[2] < mw[3], n .. ": work")
            end
        end)

        it("pairs of side-by-side numbers stay a minority", function()
            for _, n in ipairs(SIZES) do
                for _, d in ipairs(LEVELS) do
                    local two, k = 0, 0
                    for _, r in ipairs(results[n][d]) do two = two + r.two; k = k + r.k end
                    assert.is_true(two / k < 0.35, ("%dx%d %s: %d/%d"):format(n, n, d, two, k))
                end
            end
        end)

        it("small puzzles have exactly one solution (exhaustive count)", function()
            for _, n in ipairs({ 5, 7 }) do
                for _, d in ipairs(LEVELS) do
                    for s, r in ipairs(results[n][d]) do
                        local sol, exhausted = Board._countSolutions(r.b.clues, n, r.k, 2, 1e7)
                        assert.is_false(exhausted)
                        assert.are.equal(1, sol, ("%dx%d %s seed %d"):format(n, n, d, s))
                    end
                end
            end
        end)

        it("same seed, same puzzle (the Daily Challenge relies on it)", function()
            for _, d in ipairs(LEVELS) do
                local grids = {}
                for t = 1, 2 do
                    math.randomseed(77)
                    local b = Board:new{ n = 9 }
                    b:generate(d)
                    grids[t] = b
                end
                for r = 1, 9 do for c = 1, 9 do
                    assert.are.equal(grids[1].clues[r][c], grids[2].clues[r][c])
                    assert.are.equal(grids[1].solution[r][c], grids[2].solution[r][c])
                end end
            end
        end)

        it("generates 10x10 Hard quickly", function()
            local t0 = os.clock()
            for seed = 1, 5 do
                math.randomseed(seed)
                Board:new{ n = 10 }:generate("hard")
            end
            -- ~5 ms each in LuaJIT; very generous for plain Lua.
            assert.is_true(os.clock() - t0 < 10)
        end)
    end)

    it("generation never reads the clock", function()
        for _, n in ipairs({ 5, 7, 9, 10 }) do
            for _, d in ipairs({ "easy", "medium", "hard" }) do
                local reads = clockReads(function()
                    math.randomseed(303 + n)
                    Board:new{ n = n }:generate(d)
                end)
                assert.are.equal(0, reads, ("%dx%d %s read the clock"):format(n, n, d))
            end
        end
    end)
end)
