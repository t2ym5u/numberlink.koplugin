local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local bit        = require("bit")
local UndoStack  = lrequire_common("undo_stack")
local grid_utils = lrequire_common("grid_utils")

local emptyGrid = grid_utils.emptyGrid
local copyGrid  = grid_utils.copyGrid

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }

-- What each level asks for (1.6.0). Before, the only knob was the number
-- of colours, and it ran the wrong way: Hard had the most pairs, so most
-- of them were two numbers side by side (about 60%) and the puzzle all but
-- solved itself, while Easy had the fewest. Every solution was also the
-- same back-and-forth snake cut into pieces.
--   colours  how many pairs (fewer pairs = longer paths = harder)
--   tier     the hardest reasoning the solution may need (see logicSolve)
-- Easy: many short paths, tier 1. Medium: fewer, longer paths, tier 1.
-- Hard: the fewest, longest paths, and tier 2 is allowed.
local LEVEL_COLOURS = {
    --          easy        medium      hard
    [5]  = { { 6, 7 },   { 5, 5 },   { 3, 4 } },
    [7]  = { { 10, 12 }, { 8, 9 },   { 5, 7 } },
    [9]  = { { 16, 18 }, { 13, 15 }, { 8, 12 } },
    [10] = { { 19, 22 }, { 16, 18 }, { 10, 15 } },
}
local LEVEL_INDEX = { easy = 1, medium = 2, hard = 3 }
local LEVEL_TIER  = { 1, 1, 2 }
-- How much reasoning the solution needs (logicSolve's work score), as a
-- share of the cells: Easy at most, Medium and Hard at least.
local LEVEL_WORK  = { { 0, 0.20 }, { 0.14, math.huge }, { 0.22, math.huge } }

local function levelFor(n, difficulty)
    local li = LEVEL_INDEX[difficulty] or 1
    local row = LEVEL_COLOURS[n]
    local w
    if row then
        w = row[li]
    else
        -- Any other size: the same colours-per-cell ratios.
        local N = n * n
        local f = ({ { 0.19, 0.22 }, { 0.15, 0.18 }, { 0.10, 0.145 } })[li]
        w = { math.min(30, math.max(2, math.floor(N * f[1] + 0.5))),
              math.min(30, math.max(2, math.floor(N * f[2] + 0.5))) }
    end
    local N, wk = n * n, LEVEL_WORK[li]
    return { min_colours = w[1], max_colours = w[2], tier = LEVEL_TIER[li],
             min_work = math.floor(N * wk[1] + 0.5), max_work = math.floor(N * wk[2] + 0.5) }
end

-- Neighbour cells (flat indices) and the matching edge ids. Edge e < N is
-- the one between cell e and the cell to its right, edge N + e the one
-- between cell e and the cell below.
local function gridLinks(n)
    local N = n * n
    local nbr, nedge = {}, {}
    for r = 1, n do
        for c = 1, n do
            local i, l, e = (r - 1) * n + c, {}, {}
            if r > 1 then l[#l + 1] = i - n; e[#e + 1] = N + i - n end
            if r < n then l[#l + 1] = i + n; e[#e + 1] = N + i end
            if c > 1 then l[#l + 1] = i - 1; e[#e + 1] = i - 1 end
            if c < n then l[#l + 1] = i + 1; e[#e + 1] = i end
            nbr[i], nedge[i] = l, e
        end
    end
    return nbr, nedge
end

-- ---------------------------------------------------------------------------
-- Generator: a random partition of the grid into paths.
--
-- Every cell starts as its own one-cell path; the ends of two paths that
-- touch are then joined, one pair at a time, until `target` paths are left
-- or no join is possible. A join is refused when the two paths would also
-- touch anywhere else ("tight" paths, no path runs alongside itself): such
-- a path could take a shortcut, and those puzzles were rarely solvable by
-- reasoning. Cells still alone are joined first, the one with the fewest
-- options first, so none is ever left stranded. Returns the paths as lists
-- of flat cells (each at least two cells long).
-- ---------------------------------------------------------------------------
local function randomPartition(n, target, nbr)
    local N = n * n
    local random = math.random
    local pid, paths = {}, {}
    -- cells still alone, in a list with their positions (swap-remove)
    local single, spos = {}, {}
    for i = 1, N do
        pid[i] = i; paths[i] = { i }
        single[i] = i; spos[i] = i
    end
    local nsingle = N
    local function unsingle(x)
        local p = spos[x]
        local last = single[nsingle]
        single[p] = last; spos[last] = p
        single[nsingle] = nil; spos[x] = nil
        nsingle = nsingle - 1
    end
    local count = N
    local function isEnd(i)
        local p = paths[pid[i]]
        return p[1] == i or p[#p] == i
    end
    local function canJoin(i, j)
        if pid[i] == pid[j] or not isEnd(i) or not isEnd(j) then return false end
        local A, B = paths[pid[i]], paths[pid[j]]
        if #A > #B then A, B, i, j = B, A, j, i end
        local idB = pid[j]
        for q = 1, #A do
            local x = A[q]
            local l = nbr[x]
            for w = 1, #l do
                local y = l[w]
                if pid[y] == idB and not (x == i and y == j) then return false end
            end
        end
        return true
    end
    local opts, urgent, nurgent = {}, {}, 0
    local function options(s)
        local m, l = 0, nbr[s]
        for w = 1, #l do
            if canJoin(s, l[w]) then m = m + 1; opts[m] = l[w] end
        end
        return m
    end
    local function join(i, j)
        local A, B = paths[pid[i]], paths[pid[j]]
        if #A == 1 then unsingle(i) end
        if #B == 1 then unsingle(j) end
        local out = {}
        if A[#A] == i then
            for q = 1, #A do out[q] = A[q] end
        else
            for q = #A, 1, -1 do out[#out + 1] = A[q] end
        end
        if B[1] == j then
            for q = 1, #B do out[#out + 1] = B[q] end
        else
            for q = #B, 1, -1 do out[#out + 1] = B[q] end
        end
        local id = pid[i]
        paths[pid[j]] = false
        paths[id] = out
        for q = 1, #out do pid[out[q]] = id end
        count = count - 1
        -- lone cells next to the new path may have lost options
        if nsingle > 0 then
            for q = 1, #out do
                local l = nbr[out[q]]
                for w = 1, #l do
                    local y = l[w]
                    if spos[y] and options(y) <= 1 then
                        nurgent = nurgent + 1; urgent[nurgent] = y
                    end
                end
            end
        end
    end
    local stuck = 0
    while count > target do
        if nsingle > 0 then
            local s
            while nurgent > 0 and not s do
                local y = urgent[nurgent]
                urgent[nurgent] = nil; nurgent = nurgent - 1
                if spos[y] then s = y end
            end
            s = s or single[random(nsingle)]
            local m = options(s)
            if m == 0 then return nil end
            join(s, opts[random(m)])
        else
            local i = random(N)
            local l = nbr[i]
            local j = l[random(#l)]
            if canJoin(i, j) then
                join(i, j)
                stuck = 0
            else
                stuck = stuck + 1
                if stuck > 6 * N then break end
            end
        end
    end
    local out = {}
    for i = 1, N do
        local p = paths[i]
        if p then
            if #p < 2 then return nil end
            out[#out + 1] = p
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Human-style solver, no trial and error.
--
-- It keeps, for every cell, the colours it can still be, and for every
-- link between two neighbouring cells whether a path uses it (on, off or
-- not known yet). Tier 1 is what a player sees at a glance:
--   * a numbered cell has exactly one link, any other cell exactly two:
--     when only that many links are still possible they are all on, and
--     once a cell has them all, its other links are off (corners, edges
--     and dead ends);
--   * linked cells have the same colour; two cells that can no longer
--     share a colour are not linked; a link that would close a loop is
--     off;
--   * a cell can only be colour c if it still has enough neighbours that
--     can be c to pass the path through (dead-end pockets);
--   * a cell can only be colour c if c's path can still reach it from its
--     number (walled-off cells).
-- Tier 2, only when tier 1 is stuck: a cell (or link) that every remaining
-- route of a colour must cross belongs to that colour (bottlenecks).
-- Every step is a plain consequence of the rules, so when the solver
-- colours every cell the puzzle has exactly that one solution.
--
-- clue: flat array (0 or the colour of a number), k colours.
-- Returns solved, stats { waves = tier-1 passes, t2 = tier-2 steps },
-- and the flat colour array when solved.
-- ---------------------------------------------------------------------------
local function logicSolve(clue, n, k, max_tier, nbr, nedge)
    local N = n * n
    if not nbr then nbr, nedge = gridLinks(n) end
    -- colour sets are bit masks (the levels use at most 22 colours)
    if k > 30 then return false, { waves = 0, t2 = 0 } end
    local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift
    local ALL = lshift(1, k) - 1
    -- dom[i]: bit c-1 set while cell i can still be colour c
    local dom, need = {}, {}
    local ep1, ep2 = {}, {}
    for i = 1, N do
        local v = clue[i]
        if v > 0 then
            dom[i], need[i] = lshift(1, v - 1), 1
            if ep1[v] then ep2[v] = i else ep1[v] = i end
        else
            dom[i], need[i] = ALL, 2
        end
    end
    for c = 1, k do
        if not (ep1[c] and ep2[c]) then return false, { waves = 0, t2 = 0 } end
    end
    -- es[e]: 0 unknown, 1 on, 2 off
    local es = {}
    for e = 1, 2 * N do es[e] = 0 end
    local uf = {}
    for i = 1, N do uf[i] = i end
    local function find(x)
        while uf[x] ~= x do uf[x] = uf[uf[x]]; x = uf[x] end
        return x
    end

    local bad = false
    local dirty, cdirty = {}, 0     -- cdirty: mask of colours to re-walk
    for i = 1, N do dirty[i] = true end
    cdirty = ALL
    local any_dirty = true

    local function markAround(i)
        dirty[i] = true
        local l = nbr[i]
        for w = 1, #l do dirty[l[w]] = true end
        any_dirty = true
    end
    -- keep only the colours in `mask` for cell i
    local function restrict(i, mask)
        local d = dom[i]
        local nd = band(d, mask)
        if nd ~= d then
            dom[i] = nd
            if nd == 0 then bad = true end
            cdirty = bor(cdirty, band(d, bnot(nd)))
            markAround(i)
        end
    end
    local function setEdge(e, a, b, v)
        local st = es[e]
        if st == 0 then
            es[e] = v
            if v == 1 then
                uf[find(a)] = find(b)
            else
                cdirty = bor(cdirty, band(dom[a], dom[b]))
            end
            markAround(a)
            markAround(b)
        elseif st ~= v then
            bad = true
        end
    end

    local function cellRules(i)
        local l, le = nbr[i], nedge[i]
        -- links: same colours across an on link; no link without a shared
        -- colour, nor one that closes a loop
        for w = 1, #l do
            local j, e = l[w], le[w]
            local st = es[e]
            if st == 1 then
                local m = band(dom[i], dom[j])
                restrict(i, m)
                restrict(j, m)
            elseif st == 0 then
                if band(dom[i], dom[j]) == 0 or find(i) == find(j) then setEdge(e, i, j, 2) end
            end
            if bad then return end
        end
        -- degree
        local on, unk = 0, 0
        for w = 1, #le do
            local st = es[le[w]]
            if st == 1 then on = on + 1 elseif st == 0 then unk = unk + 1 end
        end
        local nd = need[i]
        if on > nd or on + unk < nd then bad = true; return end
        if unk > 0 and (on == nd or on + unk == nd) then
            local v = (on == nd) and 2 or 1
            for w = 1, #le do
                if es[le[w]] == 0 then setEdge(le[w], i, l[w], v) end
            end
            if bad then return end
        end
        -- dead-end pockets: colours fewer than `need` open neighbours can carry
        local d = dom[i]
        if band(d, d - 1) ~= 0 then
            local m1, m2 = 0, 0
            for w = 1, #l do
                if es[le[w]] ~= 2 then
                    local x = dom[l[w]]
                    m2 = bor(m2, band(m1, x))
                    m1 = bor(m1, x)
                end
            end
            restrict(i, nd == 1 and m1 or m2)
        end
    end

    local seen, queue, par, stamp = {}, {}, {}, 0
    for i = 1, N do seen[i] = 0 end
    -- Breadth-first walk of colour bit cb from a, not through cell `bc`
    -- nor link `be`. Returns whether b was reached.
    local function walk(cb, a, b, bc, be)
        stamp = stamp + 1
        seen[a] = stamp; queue[1] = a; par[a] = 0
        local h, t = 1, 1
        local found = false
        while h <= t do
            local x = queue[h]; h = h + 1
            if x == b then found = true end
            local l, le = nbr[x], nedge[x]
            for w = 1, #l do
                local y, e = l[w], le[w]
                if seen[y] ~= stamp and y ~= bc and e ~= be and es[e] ~= 2
                        and band(dom[y], cb) ~= 0 then
                    seen[y] = stamp; par[y] = x
                    t = t + 1; queue[t] = y
                end
            end
        end
        return found
    end
    local function edgeBetween(a, b)
        local l = nbr[a]
        for w = 1, #l do if l[w] == b then return nedge[a][w] end end
    end

    -- walled-off cells: colour c only where its path can still reach
    local function reachRule(c)
        local cb = lshift(1, c - 1)
        if not walk(cb, ep1[c], ep2[c]) then bad = true; return end
        local nb = bnot(cb)
        for i = 1, N do
            if seen[i] ~= stamp and band(dom[i], cb) ~= 0 then restrict(i, nb) end
        end
    end

    -- tier 2: bottleneck cells and links of colour c. One depth-first
    -- walk from one number (low-link numbering): on the walk's way to the
    -- other number, a cell whose further part cannot get back above it
    -- without it is a cell every route crosses; same for a link.
    local disc, low, counter = {}, {}, 0
    local cbit, cbmark = 0, 0
    local function dfs(v, pe)
        counter = counter + 1
        disc[v], low[v] = counter, counter
        seen[v] = cbmark
        local l, le = nbr[v], nedge[v]
        for w = 1, #l do
            local y, e = l[w], le[w]
            if e ~= pe and es[e] ~= 2 and band(dom[y], cbit) ~= 0 then
                if seen[y] ~= cbmark then
                    par[y] = v
                    dfs(y, e)
                    if low[y] < low[v] then low[v] = low[y] end
                elseif disc[y] < low[v] then
                    low[v] = disc[y]
                end
            end
        end
    end
    local function bottleneck(c)
        local cb = lshift(1, c - 1)
        local a, b = ep1[c], ep2[c]
        if find(a) == find(b) then return false end   -- already drawn
        stamp = stamp + 1
        cbit, cbmark, counter = cb, stamp, 0
        par[a] = 0
        dfs(a, nil)
        if seen[b] ~= stamp then bad = true; return true end
        local found = false
        local y = b
        while y ~= a do
            local v = par[y]
            if low[y] >= disc[v] then
                if v ~= a and dom[v] ~= cb then
                    restrict(v, cb)
                    found = true
                end
                if low[y] > disc[v] then
                    local e = edgeBetween(v, y)
                    if es[e] == 0 then
                        setEdge(e, v, y, 1)
                        found = true
                    end
                end
            end
            y = v
        end
        return found
    end

    local stats = { waves = 0, t2 = 0 }
    while true do
        while any_dirty or cdirty ~= 0 do
            any_dirty = false
            stats.waves = stats.waves + 1
            for i = 1, N do
                if dirty[i] then
                    dirty[i] = false
                    cellRules(i)
                    if bad then return false, stats end
                end
            end
            local cd = cdirty
            cdirty = 0
            for c = 1, k do
                if band(cd, lshift(1, c - 1)) ~= 0 then
                    reachRule(c)
                    if bad then return false, stats end
                end
            end
        end
        local open = false
        for i = 1, N do
            local d = dom[i]
            if band(d, d - 1) ~= 0 then open = true; break end
        end
        if not open or max_tier < 2 then break end
        local progress = false
        for c = 1, k do
            if bottleneck(c) then progress = true; break end
        end
        if bad then return false, stats end
        if not progress then break end
        stats.t2 = stats.t2 + 1
    end
    local owner = {}
    for i = 1, N do
        local d = dom[i]
        if band(d, d - 1) ~= 0 then return false, stats end
        for c = 1, k do
            if d == lshift(1, c - 1) then owner[i] = c end
        end
    end
    return true, stats, owner
end

-- ---------------------------------------------------------------------------
-- Exhaustive solution counter (search, not reasoning). Since 1.6.0 the
-- generator no longer needs it -- logicSolve finishing a puzzle proves it
-- has one solution -- but the specs use it to cross-check the solver:
-- every puzzle logicSolve finishes must count exactly 1 here.
--
-- Grows each colour's path from one number to the other, one free cell at
-- a time, colours in ascending endpoint-distance order, pruning branches
-- where a remaining pair can no longer connect, a free cell is left with
-- too few free neighbours (dead end), or a free cell can no longer be
-- reached by any remaining path (stranded cell).
-- ---------------------------------------------------------------------------
local function countSolutions(clues, n, k, limit, node_budget)
    local N = n * n
    local owner, clue = {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            owner[i] = 0
            clue[i] = clues[r][c]
        end
    end
    -- Neighbours of each cell in DIRS order (up, down, left, right).
    local nbr = {}
    for r = 1, n do
        for c = 1, n do
            local list = {}
            for _, d in ipairs(DIRS) do
                local nr, nc = r + d[1], c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                    list[#list + 1] = (nr - 1) * n + nc
                end
            end
            nbr[(r - 1) * n + c] = list
        end
    end

    local endpoints = {}
    for col = 1, k do
        local ep = {}
        for r = 1, n do for c = 1, n do if clues[r][c] == col then ep[#ep + 1] = { r, c } end end end
        endpoints[col] = ep
    end

    local order = {}
    for col = 1, k do order[col] = col end
    table.sort(order, function(a, b)
        local ea, eb = endpoints[a], endpoints[b]
        local da = math.abs(ea[1][1] - ea[2][1]) + math.abs(ea[1][2] - ea[2][2])
        local db = math.abs(eb[1][1] - eb[2][1]) + math.abs(eb[1][2] - eb[2][2])
        return da < db
    end)
    -- Flat endpoint indices, by color.
    local ep1, ep2 = {}, {}
    for col = 1, k do
        local ep = endpoints[col]
        if ep[1] then ep1[col] = (ep[1][1] - 1) * n + ep[1][2] end
        if ep[2] then ep2[col] = (ep[2][1] - 1) * n + ep[2][2] end
    end

    local solutions, nodes, exhausted = 0, 0, false
    local claimed = 0

    local seen, stamp, queue = {}, 0, {}
    for i = 1, N do seen[i] = 0 end
    -- A cell is usable for `col`'s path if it's unclaimed AND not another
    -- color's reserved clue endpoint (a clue cell belongs exclusively to
    -- its own color -- letting a DIFFERENT color's path walk through it
    -- corrupts the search: that other color's endpoint gets silently
    -- consumed, which can make the search wrongly conclude a valid
    -- completion is impossible when it isn't, undercounting solutions).
    local function reachable(from, to, col)
        stamp = stamp + 1
        local qh, qt = 1, 1
        queue[1] = from
        seen[from] = stamp
        while qh <= qt do
            local i = queue[qh]; qh = qh + 1
            if i == to then return true end
            local list = nbr[i]
            for q = 1, #list do
                local j = list[q]
                if seen[j] ~= stamp and (j == to or (owner[j] == 0 and (clue[j] == 0 or clue[j] == col))) then
                    seen[j] = stamp
                    qt = qt + 1; queue[qt] = j
                end
            end
        end
        return false
    end

    -- Every free cell must still be reachable, through free cells, from an
    -- endpoint of a color not drawn yet.
    local function noStrandedCell(from_idx)
        stamp = stamp + 1
        local qt = 0
        for oi = from_idx + 1, k do
            local col = order[oi]
            local e = ep1[col]
            if e and seen[e] ~= stamp then
                seen[e] = stamp
                qt = qt + 1; queue[qt] = e
            end
        end
        local qh = 1
        while qh <= qt do
            local i = queue[qh]; qh = qh + 1
            local list = nbr[i]
            for q = 1, #list do
                local j = list[q]
                if seen[j] ~= stamp and owner[j] == 0 then
                    seen[j] = stamp
                    qt = qt + 1; queue[qt] = j
                end
            end
        end
        for i = 1, N do
            if owner[i] == 0 and seen[i] ~= stamp then return false end
        end
        return true
    end

    -- Every free cell ends up inside some path still to draw: a plain cell
    -- needs two path neighbours, a clue cell one. Those can only be free
    -- cells or the tip of the path being drawn (`head`). After the tip
    -- moves off `prev`, only prev's neighbours lost a possible neighbour.
    local function deadEndAround(prev, head)
        local list = nbr[prev]
        for q = 1, #list do
            local i = list[q]
            if owner[i] == 0 then
                local free = 0
                local l2 = nbr[i]
                for w = 1, #l2 do
                    local j = l2[w]
                    if owner[j] == 0 or j == head then free = free + 1 end
                end
                if free < (clue[i] == 0 and 2 or 1) then return true end
            end
        end
        return false
    end

    local function otherColorsStillFeasible(from_idx)
        for oi = from_idx + 1, k do
            local col = order[oi]
            local a, b = ep1[col], ep2[col]
            if a and b then
                if not reachable(a, b, col) then return false end
            end
        end
        return noStrandedCell(from_idx)
    end

    local function growPath(col, cur, target, idx, onComplete)
        if solutions >= limit or exhausted then return false end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return false end
        if cur == target then
            if deadEndAround(target, nil) then return true end
            if not otherColorsStillFeasible(idx) then return true end
            return onComplete()
        end
        if not reachable(cur, target, col) then return true end
        local list = nbr[cur]
        for q = 1, #list do
            local j = list[q]
            if owner[j] == 0 and (clue[j] == 0 or clue[j] == col) then
                owner[j] = col
                claimed = claimed + 1
                local keep_going = true
                if j == target or not deadEndAround(cur, j) then
                    keep_going = growPath(col, j, target, idx, onComplete)
                end
                owner[j] = 0
                claimed = claimed - 1
                if not keep_going then return false end
            end
        end
        return true
    end

    local function solveColor(idx)
        if solutions >= limit or exhausted then return false end
        if idx > k then
            if claimed == N then solutions = solutions + 1 end
            return true
        end
        local col = order[idx]
        if not (ep1[col] and ep2[col]) or #endpoints[col] ~= 2 then return true end
        local a, b = ep1[col], ep2[col]
        owner[a] = col
        claimed = claimed + 1
        local keep_going = growPath(col, a, b, idx, function() return solveColor(idx + 1) end)
        owner[a] = 0
        claimed = claimed - 1
        return keep_going
    end

    solveColor(1)
    return solutions, exhausted
end

-- ---------------------------------------------------------------------------
-- NumberlinkBoard
-- ---------------------------------------------------------------------------

local NumberlinkBoard = {}
NumberlinkBoard.__index = NumberlinkBoard
NumberlinkBoard._countSolutions = countSolutions   -- for the specs

function NumberlinkBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    return setmetatable({
        n            = n,
        difficulty   = opts.difficulty or DEFAULT_DIFFICULTY,
        clues        = emptyGrid(n, n, 0),
        solution     = emptyGrid(n, n, 0),
        paths        = emptyGrid(n, n, 0),
        -- path_cells[c] = {head, ..., tail} (ordered cell list per color)
        path_cells   = {},
        active_color = nil,
        active_end   = nil,  -- {r, c} of the tip being extended
        wrong_marks  = emptyGrid(n, n, false),
        reveal       = false,
        n_colors     = 0,
        undo         = UndoStack:new{ max_size = 500 },
    }, self)
end

NumberlinkBoard._logicSolve      = logicSolve       -- for the specs
NumberlinkBoard._levelFor        = levelFor
NumberlinkBoard._randomPartition = randomPartition
NumberlinkBoard._gridLinks       = gridLinks
NumberlinkBoard.ATTEMPTS, NumberlinkBoard.RESCUE_ATTEMPTS = 60, 2000

-- logicSolve's work score: tier-1 passes, a tier-2 step counting as four.
local function workOf(stats) return stats.waves + 4 * stats.t2 end
NumberlinkBoard._workOf = workOf

-- Turns a list of paths into clue and solution grids. Colours are numbered
-- in reading order of their first number.
local function toGrids(n, paths)
    local first = {}
    for q, p in ipairs(paths) do first[q] = math.min(p[1], p[#p]) end
    local order = {}
    for q = 1, #paths do order[q] = q end
    table.sort(order, function(x, y) return first[x] < first[y] end)
    local clue, flat = {}, {}
    for i = 1, n * n do clue[i] = 0 end
    for colour, q in ipairs(order) do
        local p = paths[q]
        clue[p[1]], clue[p[#p]] = colour, colour
        for _, i in ipairs(p) do flat[i] = colour end
    end
    return clue, flat
end

local function toGrid2D(n, flat)
    local g = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do g[r][c] = flat[(r - 1) * n + c] end
    end
    return g
end

-- on_progress(fraction), optional: called after every candidate
-- (screen.lua wires it to the shared "Generating puzzle..." bar).
--
-- Candidates are random partitions of the grid into the level's number of
-- paths (randomPartition). One is kept only when logicSolve, limited to
-- the level's tier, colours every cell (so it has exactly one solution and
-- needs no trial and error) with a work score in the level's range; after
-- ATTEMPTS candidates, the solved one closest to that range. All work is
-- bounded by attempt counts, never the clock: a seed builds the same
-- puzzle on every device (the Daily Challenge relies on that).
function NumberlinkBoard:generate(difficulty, on_progress)
    self.difficulty  = difficulty or self.difficulty
    self.reveal      = false
    self.active_color = nil
    self.active_end  = nil
    self.undo:clear()

    local n = self.n
    local level = levelFor(n, self.difficulty)
    local nbr, nedge = gridLinks(n)
    local ATTEMPTS = NumberlinkBoard.ATTEMPTS

    local function try(lv, check_work)
        local paths = randomPartition(n, lv.min_colours, nbr)
        if not paths or #paths < lv.min_colours or #paths > lv.max_colours then return nil end
        local clue, flat = toGrids(n, paths)
        local ok, stats = logicSolve(clue, n, #paths, lv.tier, nbr, nedge)
        if not ok then return nil end
        local w = workOf(stats)
        local off = 0
        if check_work then
            off = w < lv.min_work and lv.min_work - w or (w > lv.max_work and w - lv.max_work or 0)
        end
        return { clue = clue, flat = flat, k = #paths, stats = stats, off = off }
    end

    local best, attempts = nil, 0
    for _ = 1, ATTEMPTS do
        attempts = attempts + 1
        local cand = try(level, true)
        if cand and (not best or cand.off < best.off) then best = cand end
        if on_progress then on_progress(attempts / ATTEMPTS) end
        if best and best.off == 0 then break end
    end
    local rescued = false
    if not best then
        -- Never seen in the specs' seeds: the Easy colour range, any work.
        rescued = true
        local easy = levelFor(n, "easy")
        for _ = 1, NumberlinkBoard.RESCUE_ATTEMPTS do
            attempts = attempts + 1
            best = try(easy, false)
            if best then break end
        end
        assert(best, "numberlink: no puzzle found")
    end

    self.n_colors = best.k
    self.clues    = toGrid2D(n, best.clue)
    self.solution = toGrid2D(n, best.flat)
    self.gen_info = { attempts = attempts, work = workOf(best.stats), waves = best.stats.waves,
                      t2 = best.stats.t2, in_range = best.off == 0, rescued = rescued }
    self.paths      = emptyGrid(n, n, 0)
    self.path_cells = {}
    for c = 1, best.k do self.path_cells[c] = {} end
    self.wrong_marks = emptyGrid(n, n, false)
end

-- ---------------------------------------------------------------------------
-- Path operations
-- ---------------------------------------------------------------------------

-- Get the ordered path for a color (ordered from one endpoint outward)
function NumberlinkBoard:getPath(color)
    return self.path_cells[color] or {}
end

-- Returns the color's two clue endpoints
function NumberlinkBoard:getEndpoints(color)
    local n = self.n
    local ep = {}
    for r = 1, n do
        for c = 1, n do
            if self.clues[r][c] == color then ep[#ep+1] = {r, c} end
        end
    end
    return ep[1], ep[2]
end

-- Tap a cell: extend/retract/start path
function NumberlinkBoard:tapCell(r, c)
    if r < 1 or r > self.n or c < 1 or c > self.n then return false, "oob" end

    local color = self.clues[r][c]  -- is this a fixed endpoint?

    if color > 0 then
        -- If this endpoint is adjacent to the active path's tip (same
        -- color), treat it like any other adjacent cell: extend onto it
        -- (completing the path if it's the far endpoint) or retract back
        -- to it. Without this, tapping the endpoint that closes the loop
        -- would fall through to _startFromEndpoint below, which only
        -- repositions active_end without ever adding the cell to the
        -- path -- the two numbers would never actually connect.
        if self.active_color == color and self.active_end then
            local ae_r, ae_c = self.active_end[1], self.active_end[2]
            local is_adjacent = (math.abs(r - ae_r) + math.abs(c - ae_c)) == 1
            if is_adjacent and not (ae_r == r and ae_c == c) then
                if self.paths[r][c] == 0 then
                    self:_extendPath(r, c)
                    return true, "extend"
                elseif self.paths[r][c] == color then
                    self:_retractToCell(r, c)
                    return true, "retract"
                end
            end
        end
        -- Tapped an endpoint: start (or switch) drawing from it
        self:_startFromEndpoint(r, c, color)
        return true, "start"
    end

    local cell_color = self.paths[r][c]

    if self.active_color and self.active_end then
        local ae_r, ae_c = self.active_end[1], self.active_end[2]
        local is_adjacent = (math.abs(r - ae_r) + math.abs(c - ae_c)) == 1

        if is_adjacent then
            -- Try to extend active path to this cell
            if cell_color == 0 then
                self:_extendPath(r, c)
                return true, "extend"
            elseif cell_color == self.active_color then
                -- Retract if this is the previous cell in the path
                self:_retractToCell(r, c)
                return true, "retract"
            else
                -- Occupied by another color: cannot extend here
                return false, "blocked"
            end
        else
            -- Not adjacent: deselect or start new path
            if cell_color > 0 then
                self:_startFromPathCell(r, c, cell_color)
                return true, "select"
            else
                self.active_color = nil
                self.active_end   = nil
                return false, "deselect"
            end
        end
    else
        -- No active path: select if cell has a path
        if cell_color > 0 then
            self:_startFromPathCell(r, c, cell_color)
            return true, "select"
        end
        return false, "empty"
    end
end

function NumberlinkBoard:_startFromEndpoint(r, c, color)
    -- If this color has a path, extend from this endpoint end
    local pc = self.path_cells[color]
    if #pc > 0 then
        -- Determine which end this endpoint is on
        local head = pc[1]
        local tail = pc[#pc]
        if head[1] == r and head[2] == c then
            -- This endpoint is head: reverse path so we extend from tail
            -- Actually, let's just set active_end to head and draw from there
            -- But we need to reverse the path so extension happens at [#pc+1]
            self:_reversePath(color)
        end
        -- Now tail is this endpoint (after possible reversal)
    else
        -- Empty path: initialize with this endpoint
        pc[1] = {r, c}
        self.paths[r][c] = color
    end
    self.active_color = color
    self.active_end   = {r, c}
    -- Make sure active_end is the last cell in the path
    local pc2 = self.path_cells[color]
    if #pc2 > 0 then
        local tail = pc2[#pc2]
        if tail[1] ~= r or tail[2] ~= c then
            -- Head is this endpoint; reverse to put it at tail
            self:_reversePath(color)
        end
    end
end

function NumberlinkBoard:_reversePath(color)
    local pc = self.path_cells[color]
    local i, j = 1, #pc
    while i < j do
        pc[i], pc[j] = pc[j], pc[i]
        i = i + 1
        j = j - 1
    end
end

function NumberlinkBoard:_startFromPathCell(r, c, color)
    -- Set the active path end to the nearer endpoint of this color
    local pc = self.path_cells[color]
    if #pc == 0 then return end
    local head = pc[1]
    local tail = pc[#pc]
    -- Is (r,c) closer to head or tail?
    local d_head = math.abs(r-head[1]) + math.abs(c-head[2])
    local d_tail = math.abs(r-tail[1]) + math.abs(c-tail[2])
    if d_head < d_tail then
        -- Reverse so we extend from head
        self:_reversePath(color)
    end
    self.active_color = color
    local pc2 = self.path_cells[color]
    self.active_end = {pc2[#pc2][1], pc2[#pc2][2]}
end

function NumberlinkBoard:_extendPath(r, c)
    local color = self.active_color
    local pc    = self.path_cells[color]

    -- Save undo entry: {color, action=extend, r, c}
    self.undo:push{ color=color, action="extend", r=r, c=c }

    -- Erase any existing path on this cell's color
    local existing = self.paths[r][c]
    if existing ~= 0 and existing ~= color then
        self:_clearColorPath(existing)
    end

    pc[#pc+1] = {r, c}
    self.paths[r][c] = color
    self.active_end  = {r, c}

    -- Check if we've reached the other endpoint
    local ep1, ep2 = self:getEndpoints(color)
    if ep1 and ep2 then
        local head = pc[1]
        if (head[1] == ep1[1] and head[2] == ep1[2]) or
           (head[1] == ep2[1] and head[2] == ep2[2]) then
            local tail = {r, c}
            local other_ep = (head[1] == ep1[1] and head[2] == ep1[2]) and ep2 or ep1
            if tail[1] == other_ep[1] and tail[2] == other_ep[2] then
                -- Path is complete!
                self.active_color = nil
                self.active_end   = nil
            end
        end
    end
end

function NumberlinkBoard:_retractToCell(r, c)
    local color = self.active_color
    local pc    = self.path_cells[color]

    -- Find (r,c) in the path and remove everything after it
    for i = #pc, 1, -1 do
        local cell = pc[i]
        if cell[1] ~= r or cell[2] ~= c then
            -- Clear this cell
            if self.clues[cell[1]][cell[2]] == 0 then
                self.paths[cell[1]][cell[2]] = 0
            end
            self.undo:push{ color=color, action="retract", r=cell[1], c=cell[2] }
            table.remove(pc, i)
        else
            break
        end
    end
    self.active_end = {r, c}
end

function NumberlinkBoard:_clearColorPath(color)
    local pc = self.path_cells[color]
    for _, cell in ipairs(pc) do
        if self.clues[cell[1]][cell[2]] == 0 then
            self.paths[cell[1]][cell[2]] = 0
        end
    end
    self.path_cells[color] = {}
end

function NumberlinkBoard:clearColorPath(color)
    self.undo:push{ color=color, action="clear_all", cells=self.path_cells[color] }
    self:_clearColorPath(color)
    if self.active_color == color then
        self.active_color = nil
        self.active_end   = nil
    end
end

function NumberlinkBoard:holdCell(r, c)
    local color = self.paths[r][c]
    if color > 0 then
        self:clearColorPath(color)
        return true
    end
    return false
end

function NumberlinkBoard:canUndo()
    return self.undo:canUndo()
end

function NumberlinkBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end

    if entry.action == "extend" then
        local pc = self.path_cells[entry.color]
        if #pc > 0 then
            local last = pc[#pc]
            if last[1] == entry.r and last[2] == entry.c then
                if self.clues[last[1]][last[2]] == 0 then
                    self.paths[last[1]][last[2]] = 0
                end
                table.remove(pc, #pc)
                if #pc > 0 then
                    self.active_color = entry.color
                    local prev = pc[#pc]
                    self.active_end = {prev[1], prev[2]}
                else
                    self.active_color = nil
                    self.active_end   = nil
                end
            end
        end
    elseif entry.action == "retract" then
        local pc = self.path_cells[entry.color]
        pc[#pc+1] = {entry.r, entry.c}
        self.paths[entry.r][entry.c] = entry.color
        self.active_color = entry.color
        self.active_end   = {entry.r, entry.c}
    elseif entry.action == "clear_all" then
        local pc = entry.cells or {}
        self.path_cells[entry.color] = pc
        for _, cell in ipairs(pc) do
            self.paths[cell[1]][cell[2]] = entry.color
        end
    end
    return true
end

function NumberlinkBoard:checkProgress()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local p = self.paths[r][c]
            local s = self.solution[r][c]
            self.wrong_marks[r][c] = (p ~= 0 and p ~= s)
        end
    end
end

-- Solved when the paths keep the rules, whatever the stored solution says
-- (1.6.0; before, the grid had to match the solution cell for cell): every
-- cell covered, and each colour's cells form one unbroken path from its
-- number to its other number.
function NumberlinkBoard:_colourIsLinked(color)
    local n = self.n
    local a, b = self:getEndpoints(color)
    if not (a and b) then return false end
    local cells = 0
    for r = 1, n do
        for c = 1, n do
            if self.paths[r][c] == color then cells = cells + 1 end
        end
    end
    -- The drawn route, in walking order.
    local pc = self.path_cells[color]
    if pc and #pc == cells and cells >= 2 then
        local head, tail = pc[1], pc[#pc]
        local ok = ((head[1] == a[1] and head[2] == a[2] and tail[1] == b[1] and tail[2] == b[2])
                 or (head[1] == b[1] and head[2] == b[2] and tail[1] == a[1] and tail[2] == a[2]))
        local seen = {}
        for i = 1, #pc do
            if not ok then break end
            local r, c = pc[i][1], pc[i][2]
            local key = (r - 1) * n + c
            if seen[key] or self.paths[r][c] ~= color then ok = false; break end
            seen[key] = true
            if i > 1 and math.abs(r - pc[i - 1][1]) + math.abs(c - pc[i - 1][2]) ~= 1 then
                ok = false
            end
        end
        if ok then return true end
    end
    -- No usable route list (e.g. the grid was filled directly): the
    -- colour's cells must themselves form a simple path between its numbers.
    local ends, from = 0, nil
    for r = 1, n do
        for c = 1, n do
            if self.paths[r][c] == color then
                local deg = 0
                for _, d in ipairs(DIRS) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and self.paths[nr][nc] == color then
                        deg = deg + 1
                    end
                end
                local is_end = (r == a[1] and c == a[2]) or (r == b[1] and c == b[2])
                if deg ~= (is_end and 1 or 2) then return false end
                if is_end then ends = ends + 1; from = from or { r, c } end
            end
        end
    end
    if ends ~= 2 then return false end
    -- one piece, not a path plus separate loops
    local seen, stack, count = { [(from[1] - 1) * n + from[2]] = true }, { from }, 1
    while #stack > 0 do
        local cur = table.remove(stack)
        for _, d in ipairs(DIRS) do
            local nr, nc = cur[1] + d[1], cur[2] + d[2]
            local key = (nr - 1) * n + nc
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and self.paths[nr][nc] == color
                    and not seen[key] then
                seen[key] = true
                count = count + 1
                stack[#stack + 1] = { nr, nc }
            end
        end
    end
    return count == cells
end

function NumberlinkBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self.paths[r][c]
            if v == 0 or v > self.n_colors then return false end
        end
    end
    for color = 1, self.n_colors do
        if not self:_colourIsLinked(color) then return false end
    end
    return true
end

function NumberlinkBoard:getCompletedPairs()
    local completed = 0
    for color = 1, self.n_colors do
        local ep1, ep2 = self:getEndpoints(color)
        if ep1 and ep2 then
            local pc = self.path_cells[color]
            if #pc >= 2 then
                local head = pc[1]
                local tail = pc[#pc]
                local head_is_ep = (head[1] == ep1[1] and head[2] == ep1[2])
                    or (head[1] == ep2[1] and head[2] == ep2[2])
                local tail_is_ep = (tail[1] == ep1[1] and tail[2] == ep1[2])
                    or (tail[1] == ep2[1] and tail[2] == ep2[2])
                if head_is_ep and tail_is_ep then completed = completed + 1 end
            end
        end
    end
    return completed
end

function NumberlinkBoard:getRemainingCells()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.paths[r][c] == 0 then count = count + 1 end
        end
    end
    return count
end

function NumberlinkBoard:toggleSolution()
    self.reveal = not self.reveal
end

function NumberlinkBoard:isShowingSolution()
    return self.reveal
end

-- ---------------------------------------------------------------------------
-- Serialize / Load
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Hints
--
-- `solution` is a grid of colour ids, so a single cell could technically be
-- revealed -- but path_cells[] holds each colour's route in walking order, and
-- writing isolated cells would desynchronise it from `paths`. The unit that
-- keeps both consistent, and the one the player actually thinks in, is a whole
-- coloured path.
local DIRS4_HINT = { {0,1}, {0,-1}, {1,0}, {-1,0} }

-- Walks the solution's cells for one colour from an endpoint, so the rebuilt
-- path_cells entry is in the same order the player's own drawing would be.
function NumberlinkBoard:_solutionRoute(color)
    local n = self.n
    local start
    for r = 1, n do
        for c = 1, n do
            if self.clues[r][c] == color then start = { r, c } break end
        end
        if start then break end
    end
    if not start then return {} end

    local seen = {}
    local function key(r, c) return (r - 1) * n + c end
    local route = { start }
    seen[key(start[1], start[2])] = true
    while true do
        local cur = route[#route]
        local moved = false
        for _, d in ipairs(DIRS4_HINT) do
            local nr, nc = cur[1] + d[1], cur[2] + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
               and self.solution[nr][nc] == color and not seen[key(nr, nc)] then
                seen[key(nr, nc)] = true
                route[#route + 1] = { nr, nc }
                moved = true
                break
            end
        end
        if not moved then break end
    end
    return route
end

function NumberlinkBoard:findHint()
    if self.reveal then return nil, "stuck" end
    local n = self.n
    for color = 1, self.n_colors do
        local differs = false
        for r = 1, n do
            for c = 1, n do
                local want = (self.solution[r][c] == color) and color or 0
                local have = (self.paths[r][c] == color) and color or 0
                if want ~= have then differs = true break end
            end
            if differs then break end
        end
        if differs then
            -- getEndpoints returns the two endpoints as two values, not a
            -- table of two.
            local a = self:getEndpoints(color)
            return {
                kind = "fill", color = color, tag = "c" .. color,
                r = a and a[1] or 1, c = a and a[2] or 1,
            }
        end
    end
    return nil, "complete"
end

function NumberlinkBoard:applyHint(step)
    if not step or not step.color then return false end
    local color = step.color
    self:_clearColorPath(color)
    local route = self:_solutionRoute(color)
    for _, cell in ipairs(route) do
        self.paths[cell[1]][cell[2]] = color
    end
    self.path_cells[color] = route
    self.active_color, self.active_end = nil, nil
    return true
end

function NumberlinkBoard:getHintsUsed()
    return self.hints_used or 0
end

function NumberlinkBoard:noteHintUsed()
    self.hints_used = (self.hints_used or 0) + 1
end

function NumberlinkBoard:serialize()
    local n = self.n
    local pc_out = {}
    for c = 1, self.n_colors do
        pc_out[c] = {}
        local pc = self.path_cells[c] or {}
        for i, cell in ipairs(pc) do pc_out[c][i] = {cell[1], cell[2]} end
    end
    local wm_out = {}
    for r = 1, n do
        wm_out[r] = {}
        for c = 1, n do wm_out[r][c] = self.wrong_marks[r][c] and true or false end
    end
    return {
        n            = n,
        difficulty   = self.difficulty,
        clues        = copyGrid(self.clues,    n),
        solution     = copyGrid(self.solution, n),
        paths        = copyGrid(self.paths,    n),
        path_cells   = pc_out,
        n_colors     = self.n_colors,
        active_color = self.active_color,
        active_end   = self.active_end,
        wrong_marks  = wm_out,
        reveal       = self.reveal,
        undo         = self.undo:serialize(),
    }
end

function NumberlinkBoard:load(data)
    if type(data) ~= "table" or not data.clues then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.n_colors   = data.n_colors or 0
    self.clues      = copyGrid(data.clues    or {}, n)
    self.solution   = copyGrid(data.solution or {}, n)
    self.paths      = copyGrid(data.paths    or {}, n)

    self.path_cells = {}
    if data.path_cells then
        for c = 1, self.n_colors do
            self.path_cells[c] = {}
            if data.path_cells[c] then
                for i, cell in ipairs(data.path_cells[c]) do
                    self.path_cells[c][i] = {cell[1], cell[2]}
                end
            end
        end
    else
        for c = 1, self.n_colors do self.path_cells[c] = {} end
    end

    self.active_color = data.active_color
    self.active_end   = data.active_end
    self.wrong_marks  = emptyGrid(n, n, false)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal = data.reveal or false
    self.undo   = UndoStack:new{ max_size = 500 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

return NumberlinkBoard
