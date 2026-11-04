local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("NumberlinkBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n, diff)
        math.randomseed(42)
        local b = Board:new{ n = n or 5 }
        b:generate(diff or "easy")
        return b
    end

    describe("construction", function()
        it("creates a 5×5 board by default", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
        end)

        it("starts with empty paths", function()
            local b = Board:new{ n = 5 }
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(0, b.paths[r][c])
                end
            end
        end)
    end)

    describe("generate", function()
        it("has at least 2 colors", function()
            local b = newBoard(5)
            assert.is_true(b.n_colors >= 2)
        end)

        it("solution covers all cells", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    assert.is_true(b.solution[r][c] > 0,
                        ("solution[%d][%d] = 0 (uncovered)"):format(r, c))
                end
            end
        end)

        it("each color has exactly 2 clue cells (endpoints)", function()
            local b = newBoard(5)
            local counts = {}
            for r = 1, b.n do
                for c = 1, b.n do
                    local cl = b.clues[r][c]
                    if cl > 0 then
                        counts[cl] = (counts[cl] or 0) + 1
                    end
                end
            end
            for color = 1, b.n_colors do
                assert.are.equal(2, counts[color] or 0,
                    ("color %d has %d clue cells"):format(color, counts[color] or 0))
            end
        end)

        it("solution values match clue colors at endpoints", function()
            local b = newBoard(5)
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.clues[r][c] > 0 then
                        assert.are.equal(b.clues[r][c], b.solution[r][c],
                            ("endpoint [%d][%d]: clue=%d sol=%d"):format(r, c,
                                b.clues[r][c], b.solution[r][c]))
                    end
                end
            end
        end)
    end)

    describe("tapCell", function()
        it("selecting a clue cell sets active_color", function()
            local b = newBoard(5)
            -- Find first clue cell
            local r, c, color
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] > 0 then
                        r, c, color = rr, cc, b.clues[rr][cc]; goto done
                    end
                end
            end
            ::done::
            assert.is_not_nil(r)
            local ok, reason = b:tapCell(r, c)
            assert.is_true(ok)
            assert.are.equal("start", reason)
            assert.are.equal(color, b.active_color)
        end)

        it("extending path to adjacent cell works", function()
            local b = newBoard(5)
            -- Find a clue cell and an adjacent free cell
            local r, c, color
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] > 0 then r, c, color = rr, cc, b.clues[rr][cc]; goto done end
                end
            end
            ::done::
            b:tapCell(r, c)

            -- Find adjacent free cell (not a clue)
            local nr, nc
            for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
                local ar, ac = r+d[1], c+d[2]
                if ar >= 1 and ar <= b.n and ac >= 1 and ac <= b.n and b.clues[ar][ac] == 0 then
                    nr, nc = ar, ac; break
                end
            end
            if not nr then return end  -- no adjacent free cell (unlikely on 5×5)

            local ok, reason = b:tapCell(nr, nc)
            assert.is_true(ok)
            assert.are.equal("extend", reason)
            assert.are.equal(color, b.paths[nr][nc])
        end)

        it("tapping the far endpoint closes the loop between the two numbers", function()
            local b = newBoard(5)
            local color = 1
            local ep1, ep2 = b:getEndpoints(color)
            assert.is_not_nil(ep1)
            assert.is_not_nil(ep2)

            -- Walk color's solution path in order from ep1 to ep2 (it's a
            -- simple path, so at each step exactly one unvisited same-color
            -- neighbor exists, except at the final step which is ep2).
            local n = b.n
            local visited = {}
            for r = 1, n do visited[r] = {} end
            local path = { ep1 }
            visited[ep1[1]][ep1[2]] = true
            local cur = ep1
            while not (cur[1] == ep2[1] and cur[2] == ep2[2]) do
                local found = false
                for _, d in ipairs({ {-1,0}, {1,0}, {0,-1}, {0,1} }) do
                    local nr, nc = cur[1] + d[1], cur[2] + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                        and b.solution[nr][nc] == color and not visited[nr][nc] then
                        cur = { nr, nc }
                        visited[nr][nc] = true
                        path[#path+1] = cur
                        found = true
                        break
                    end
                end
                assert.is_true(found, "solution path for color broke before reaching ep2")
            end

            b:tapCell(ep1[1], ep1[2])
            for i = 2, #path do
                local ok, reason = b:tapCell(path[i][1], path[i][2])
                assert.is_true(ok, "tap failed at step " .. i .. " reason=" .. tostring(reason))
            end

            -- The final tap (onto ep2) must have actually extended the path
            -- onto ep2 and completed it -- not merely repositioned active_end.
            assert.are.equal(color, b.paths[ep2[1]][ep2[2]])
            assert.is_nil(b.active_color)
            assert.is_nil(b.active_end)
            assert.are.equal(1, b:getCompletedPairs())
        end)
    end)

    describe("holdCell", function()
        it("clears a path when holding a path cell", function()
            local b = newBoard(5)
            -- Start a path and extend one step
            local r, c, color
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] > 0 then r, c, color = rr, cc, b.clues[rr][cc]; goto done end
                end
            end
            ::done::
            b:tapCell(r, c)
            local nr, nc
            for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
                local ar, ac = r+d[1], c+d[2]
                if ar >= 1 and ar <= b.n and ac >= 1 and ac <= b.n and b.clues[ar][ac] == 0 then
                    nr, nc = ar, ac; break
                end
            end
            if not nr then return end
            b:tapCell(nr, nc)
            assert.are.equal(color, b.paths[nr][nc])

            -- Now hold the extended cell to clear the color
            b:holdCell(nr, nc)
            assert.are.equal(0, b.paths[nr][nc])
        end)
    end)

    describe("undo", function()
        it("canUndo is false before any action", function()
            local b = newBoard(5)
            assert.is_false(b:canUndo())
        end)

        it("undoes a path extension", function()
            local b = newBoard(5)
            local r, c, color
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] > 0 then r, c, color = rr, cc, b.clues[rr][cc]; goto done end
                end
            end
            ::done::
            b:tapCell(r, c)
            local nr, nc
            for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
                local ar, ac = r+d[1], c+d[2]
                if ar >= 1 and ar <= b.n and ac >= 1 and ac <= b.n and b.clues[ar][ac] == 0 then
                    nr, nc = ar, ac; break
                end
            end
            if not nr then return end
            b:tapCell(nr, nc)
            assert.are.equal(color, b.paths[nr][nc])

            assert.is_true(b:canUndo())
            Board.undo(b)
            assert.are.equal(0, b.paths[nr][nc])
        end)
    end)

    describe("isSolved", function()
        it("returns false for empty paths", function()
            local b = newBoard(5)
            assert.is_false(b:isSolved())
        end)

        it("returns true when paths match solution", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local n = b.n
            -- Copy solution into paths
            for r = 1, n do
                for c = 1, n do
                    b.paths[r][c] = b.solution[r][c]
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("getRemainingCells", function()
        it("returns n*n for fresh board", function()
            local b = newBoard(5)
            assert.are.equal(b.n * b.n, b:getRemainingCells())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips clues and solution", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local data = b:serialize()

            local b2 = Board:new{ n = 5 }
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(b.n_colors, b2.n_colors)
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.clues[r][c], b2.clues[r][c])
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
    -- 1.5.0: faster uniqueness check, same puzzles.
    describe("uniqueness check speed-up (1.5.0)", function()
        it("builds the same puzzles per seed as 1.4.x", function()
            -- Fingerprints taken with the 1.4.3 generator under this same
            -- interpreter (math.random differs between Lua and LuaJIT).
            local want = { 842478455, 597804743, 812133848, 516043763, 568974277 }
            local cfgs = { {5, "easy", 1}, {9, "easy", 2}, {10, "easy", 3}, {10, "medium", 4}, {10, "hard", 5} }
            for k, cfg in ipairs(cfgs) do
                math.randomseed(cfg[3])
                local b = Board:new{ n = cfg[1] }
                b:generate(cfg[2])
                local h = 0
                for r = 1, cfg[1] do
                    for c = 1, cfg[1] do
                        h = (h * 31 + b.clues[r][c] * 64 + b.solution[r][c]) % 1000000007
                    end
                end
                assert.are.equal(want[k], h, "config " .. k)
            end
        end)

        -- Plain exhaustive count (no pruning at all) on small grids.
        local function naiveCount(clues, n, k)
            local owner, ends = {}, {}
            for r = 1, n do
                owner[r] = {}
                for c = 1, n do
                    owner[r][c] = 0
                    local v = clues[r][c]
                    if v > 0 then ends[v] = ends[v] or {}; table.insert(ends[v], { r, c }) end
                end
            end
            local count = 0
            local D = { {-1, 0}, {1, 0}, {0, -1}, {0, 1} }
            local solveColor
            local function grow(col, r, c, tr, tc)
                if r == tr and c == tc then return solveColor(col + 1) end
                for _, d in ipairs(D) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and owner[nr][nc] == 0
                        and (clues[nr][nc] == 0 or clues[nr][nc] == col) then
                        owner[nr][nc] = col
                        grow(col, nr, nc, tr, tc)
                        owner[nr][nc] = 0
                    end
                end
            end
            solveColor = function(col)
                if col > k then
                    for r = 1, n do for c = 1, n do if owner[r][c] == 0 then return end end end
                    count = count + 1
                    return
                end
                local a, b = ends[col][1], ends[col][2]
                owner[a[1]][a[2]] = col
                grow(col, a[1], a[2], b[1], b[2])
                owner[a[1]][a[2]] = 0
            end
            solveColor(1)
            return count
        end

        it("counts solutions like an exhaustive search", function()
            -- Raw candidate layouts (before the uniqueness filter), so both
            -- unique and ambiguous ones get compared.
            local function up(name)
                local i = 1
                while true do
                    local nm, v = debug.getupvalue(Board.generate, i)
                    if not nm then return nil end
                    if nm == name then return v end
                    i = i + 1
                end
            end
            local gen, seg = up("generateNumberlink"), up("randomSegLengths")
            assert.is_function(gen)
            local seen = {}
            for seed = 1, 120 do
                math.randomseed(seed)
                local n = ({ 4, 5 })[seed % 2 + 1]
                local k = ({ 3, 4, 6, 8 })[seed % 4 + 1]
                local clues = gen(n, k, seg(n * n, k))
                local want = math.min(naiveCount(clues, n, k), 2)
                local got = Board._countSolutions(clues, n, k, 2, 1e9)
                assert.are.equal(want, got, "seed " .. seed)
                seen[want] = true
            end
            assert.is_true(seen[1] and seen[2])
        end)

        it("generates 10x10 Easy quickly", function()
            local t0 = os.clock()
            for seed = 1, 5 do
                math.randomseed(seed)
                Board:new{ n = 10 }:generate("easy")
            end
            -- ~2 ms each in LuaJIT; very generous for plain Lua.
            assert.is_true(os.clock() - t0 < 10)
        end)
    end)
end)
