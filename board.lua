local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack  = lrequire_common("undo_stack")
local grid_utils = lrequire_common("grid_utils")

local emptyGrid = grid_utils.emptyGrid
local copyGrid  = grid_utils.copyGrid
local shuffle   = grid_utils.shuffle

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

-- Number of colors per 100 cells
local N_COLORS_PER_100 = { easy = 8, medium = 12, hard = 16 }

-- ---------------------------------------------------------------------------
-- Generator: serpentine Hamiltonian path split into N color paths
-- ---------------------------------------------------------------------------

local function makeSerpentine(n, start_corner, horizontal)
    -- start_corner: 1=TL, 2=TR, 3=BL, 4=BR
    -- horizontal: sweep rows first (true) or columns first (false)
    local path = {}
    if horizontal then
        local row_start = (start_corner == 3 or start_corner == 4) and n or 1
        local row_end   = (start_corner == 3 or start_corner == 4) and 1 or n
        local row_step  = (row_start <= row_end) and 1 or -1
        local even_rev  = (start_corner == 2 or start_corner == 4)
        local i = 0
        local r = row_start
        while (row_step > 0 and r <= row_end) or (row_step < 0 and r >= row_end) do
            local rev = (i % 2 == 0) ~= even_rev  -- XOR for alternating + corner flip
            -- Actually just alternate: even rows go forward, odd rows go backward
            -- (adjusted for start_corner)
            local fwd = (i % 2 == 0)
            if even_rev then fwd = not fwd end
            if fwd then
                for c = 1, n do path[#path+1] = {r, c} end
            else
                for c = n, 1, -1 do path[#path+1] = {r, c} end
            end
            r = r + row_step
            i = i + 1
        end
    else
        local col_start = (start_corner == 2 or start_corner == 4) and n or 1
        local col_end   = (start_corner == 2 or start_corner == 4) and 1 or n
        local col_step  = (col_start <= col_end) and 1 or -1
        local even_rev  = (start_corner == 3 or start_corner == 4)
        local i = 0
        local c = col_start
        while (col_step > 0 and c <= col_end) or (col_step < 0 and c >= col_end) do
            local fwd = (i % 2 == 0)
            if even_rev then fwd = not fwd end
            if fwd then
                for r = 1, n do path[#path+1] = {r, c} end
            else
                for r = n, 1, -1 do path[#path+1] = {r, c} end
            end
            c = c + col_step
            i = i + 1
        end
    end
    return path
end

local function generateNumberlink(n, n_colors)
    -- Build a clean serpentine path
    local corner = math.random(1, 4)
    local horiz  = (math.random() > 0.5)
    local path   = makeSerpentine(n, corner, horiz)

    -- Ensure path covers all n*n cells
    if #path ~= n*n then
        -- Fallback: standard top-left serpentine
        path = {}
        for r = 1, n do
            if r % 2 == 1 then
                for c = 1, n do path[#path+1] = {r, c} end
            else
                for c = n, 1, -1 do path[#path+1] = {r, c} end
            end
        end
    end

    -- Split into n_colors segments
    local seg_base = math.floor(n*n / n_colors)
    local seg_rem  = (n*n) - seg_base * n_colors  -- last few colors get +1

    local clues    = emptyGrid(n, n, 0)
    local solution = emptyGrid(n, n, 0)

    local idx = 1
    for color = 1, n_colors do
        local seg_len = seg_base + (color > n_colors - seg_rem and 1 or 0)
        local start_i = idx
        local end_i   = idx + seg_len - 1
        idx = end_i + 1

        for i = start_i, end_i do
            if path[i] then
                local r, c = path[i][1], path[i][2]
                solution[r][c] = color
            end
        end

        -- Mark endpoints as clues
        if path[start_i] and path[end_i] then
            local r1, c1 = path[start_i][1], path[start_i][2]
            local r2, c2 = path[end_i][1],   path[end_i][2]
            clues[r1][c1] = color
            clues[r2][c2] = color
        end
    end

    return clues, solution
end

-- ---------------------------------------------------------------------------
-- NumberlinkBoard
-- ---------------------------------------------------------------------------

local NumberlinkBoard = {}
NumberlinkBoard.__index = NumberlinkBoard

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

function NumberlinkBoard:generate(difficulty)
    self.difficulty  = difficulty or self.difficulty
    self.reveal      = false
    self.active_color = nil
    self.active_end  = nil
    self.undo:clear()

    local n        = self.n
    local cfg      = N_COLORS_PER_100[self.difficulty] or N_COLORS_PER_100.easy
    local n_colors = math.max(2, math.floor(n*n * cfg / 100))

    self.n_colors       = n_colors
    self.clues, self.solution = generateNumberlink(n, n_colors)
    self.paths      = emptyGrid(n, n, 0)
    self.path_cells = {}
    for c = 1, n_colors do self.path_cells[c] = {} end
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

function NumberlinkBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self.paths[r][c] == 0 then return false end
            if self.paths[r][c] ~= self.solution[r][c] then return false end
        end
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
