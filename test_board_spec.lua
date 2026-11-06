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

    local function flatClues(b)
        local clue = {}
        for r = 1, b.n do for c = 1, b.n do clue[(r - 1) * b.n + c] = b.clues[r][c] end end
        return clue
    end

    -- Random candidate layouts (before any filter), as clue grids.
    local function candidate(n, target)
        local paths
        repeat paths = Board._randomPartition(n, target, Board._gridLinks(n)) until paths
        local clues = {}
        for r = 1, n do clues[r] = {} for c = 1, n do clues[r][c] = 0 end end
        for colour, p in ipairs(paths) do
            for _, i in ipairs({ p[1], p[#p] }) do
                clues[math.floor((i - 1) / n) + 1][(i - 1) % n + 1] = colour
            end
        end
        return clues, #paths
    end

    describe("solution counter", function()
        it("counts solutions like an exhaustive search", function()
            local seen = {}
            for seed = 1, 120 do
                math.randomseed(seed)
                local n = ({ 4, 5 })[seed % 2 + 1]
                local clues, k = candidate(n, ({ 2, 3, 4, 6 })[seed % 4 + 1])
                local want = math.min(naiveCount(clues, n, k), 2)
                local got = Board._countSolutions(clues, n, k, 2, 1e9)
                assert.are.equal(want, got, "seed " .. seed)
                seen[want] = true
            end
            assert.is_true(seen[1] and seen[2])
        end)
    end)

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

        it("whenever the solver finishes a candidate, it has one solution", function()
            local finished = 0
            for seed = 1, 150 do
                math.randomseed(seed)
                local n = ({ 4, 5, 6 })[seed % 3 + 1]
                local clues, k = candidate(n, ({ 2, 3, 4, 5 })[seed % 4 + 1])
                local flat = {}
                for r = 1, n do for c = 1, n do flat[(r - 1) * n + c] = clues[r][c] end end
                if Board._logicSolve(flat, n, k, 2) then
                    finished = finished + 1
                    assert.are.equal(1, Board._countSolutions(clues, n, k, 2, 1e9), "seed " .. seed)
                end
            end
            assert.is_true(finished > 30)
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

        it("reports progress while generating", function()
            local calls = 0
            math.randomseed(3)
            Board:new{ n = 7 }:generate("hard", function(f)
                calls = calls + 1
                assert.is_true(f > 0 and f <= 1)
            end)
            assert.is_true(calls >= 1)
        end)
    end)

    describe("win check (1.6.0)", function()
        -- 3x3, one pair in opposite corners: two different full snakes.
        local function snakeBoard()
            local b = Board:new{ n = 3 }
            b.n_colors = 1
            b.clues = { { 1, 0, 0 }, { 0, 0, 0 }, { 0, 0, 1 } }
            b.solution = { { 1, 1, 1 }, { 1, 1, 1 }, { 1, 1, 1 } }
            b.path_cells = { {} }
            return b
        end

        it("accepts any drawing that keeps the rules", function()
            local b = snakeBoard()
            -- columns-first snake; the stored "solution" could be either
            local route = { {1,1}, {2,1}, {3,1}, {3,2}, {2,2}, {1,2}, {1,3}, {2,3}, {3,3} }
            for _, cell in ipairs(route) do b.paths[cell[1]][cell[2]] = 1 end
            b.path_cells[1] = route
            assert.is_true(b:isSolved())
        end)

        it("accepts a drawn route on a grid with an alternative solution", function()
            -- 1 . 1 / 2 . 2 style: solution says row paths, player draws them too
            local b = Board:new{ n = 2 }
            b.n_colors = 2
            b.clues = { { 1, 1 }, { 2, 2 } }
            b.solution = { { 1, 1 }, { 2, 2 } }
            b.paths = { { 1, 1 }, { 2, 2 } }
            b.path_cells = { { {1,1}, {1,2} }, { {2,1}, {2,2} } }
            assert.is_true(b:isSolved())
        end)

        it("rejects uncovered cells, broken paths and detached loops", function()
            local b = snakeBoard()
            -- every cell coloured but no route drawn and the colour is a
            -- blob, not a path
            for r = 1, 3 do for c = 1, 3 do b.paths[r][c] = 1 end end
            assert.is_false(b:isSolved())
            -- route that skips a cell
            local b2 = snakeBoard()
            local route = { {1,1}, {2,1}, {3,1}, {3,2}, {3,3} }
            for _, cell in ipairs(route) do b2.paths[cell[1]][cell[2]] = 1 end
            b2.path_cells[1] = route
            assert.is_false(b2:isSolved())
            -- 4x4: a path plus a separate loop of the same colour
            local b3 = Board:new{ n = 4 }
            b3.n_colors = 1
            b3.clues = { { 1, 0, 0, 1 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
            b3.paths = { { 1, 1, 1, 1 }, { 0, 0, 0, 0 }, { 1, 1, 0, 0 }, { 1, 1, 0, 0 } }
            b3.path_cells = { {} }
            assert.is_false(b3:isSolved())
        end)
    end)

    describe("old saves", function()
        it("loads a 1.5.x save (snake layout) and still plays it", function()
            -- 5x5 Easy from 1.5.3: the snake cut into 6 colours (colour 4
            -- even fills a 2x2 block).
            local sol = {
                { 1, 1, 1, 1, 1 },
                { 3, 2, 2, 2, 1 },
                { 3, 3, 3, 4, 4 },
                { 5, 5, 5, 4, 4 },
                { 5, 6, 6, 6, 6 },
            }
            local clues = {
                { 1, 0, 0, 0, 0 },
                { 3, 2, 0, 2, 1 },
                { 0, 0, 3, 4, 0 },
                { 0, 0, 5, 4, 0 },
                { 5, 6, 0, 0, 6 },
            }
            local data = {
                n = 5, difficulty = "easy", n_colors = 6, clues = clues, solution = sol,
                paths = { {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0} },
                path_cells = { {}, {}, {}, {}, {}, {} }, reveal = false,
            }
            local b = Board:new{ n = 5 }
            assert.is_true(b:load(data))
            assert.are.equal(6, b.n_colors)
            assert.is_false(b:isSolved())
            -- Fill each colour with the hint's route: solved.
            for colour = 1, 6 do b:applyHint({ color = colour }) end
            assert.is_true(b:isSolved())
        end)
    end)
end)
