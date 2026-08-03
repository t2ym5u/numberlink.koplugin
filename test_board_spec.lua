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
end)
