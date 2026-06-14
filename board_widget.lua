local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local gwb            = lrequire_common("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- Gray shades for up to 20 colors (cycling)
local COLORS = {
    Blitbuffer.COLOR_BLACK,
    Blitbuffer.COLOR_GRAY_4,
    Blitbuffer.COLOR_GRAY_6,
    Blitbuffer.COLOR_GRAY_8,
    Blitbuffer.COLOR_GRAY_A,
    Blitbuffer.COLOR_GRAY_C,
}

local C_BG        = Blitbuffer.COLOR_WHITE
local C_ACTIVE    = Blitbuffer.COLOR_GRAY_E   -- active-color highlight
local C_WRONG     = Blitbuffer.COLOR_GRAY_A
local C_GRID      = Blitbuffer.COLOR_GRAY_6
local C_TEXT_DARK = Blitbuffer.COLOR_BLACK
local C_TEXT_WITE = Blitbuffer.COLOR_WHITE

local function colorFor(c)
    return COLORS[((c-1) % #COLORS) + 1]
end

local NumberlinkBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function NumberlinkBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)

end

function NumberlinkBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function NumberlinkBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

function NumberlinkBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local n    = self.board.n
    local cell = self.dimen.w / n
    local show = self.board:isShowingSolution()

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    local function cx(c_idx) return x + math.floor((c_idx - 0.5) * cell) end
    local function cy(r_idx) return y + math.floor((r_idx - 0.5) * cell) end

    -- Draw path connections (thick lines between adjacent same-color cells)
    local lw_path = math.max(3, math.floor(cell * 0.35))
    for r = 1, n do
        for c = 1, n do
            local color_id = show and self.board.solution[r][c] or self.board.paths[r][c]
            if color_id > 0 then
                local col = colorFor(color_id)
                local mx  = cx(c)
                local my  = cy(r)

                -- Draw to right neighbor
                if c < n then
                    local nb = show and self.board.solution[r][c+1] or self.board.paths[r][c+1]
                    if nb == color_id then
                        local nx = cx(c+1)
                        bb:paintRect(mx, my - math.floor(lw_path/2),
                            nx - mx + math.ceil(lw_path/2), lw_path, col)
                    end
                end
                -- Draw to bottom neighbor
                if r < n then
                    local nb = show and self.board.solution[r+1][c] or self.board.paths[r+1][c]
                    if nb == color_id then
                        local ny = cy(r+1)
                        bb:paintRect(mx - math.floor(lw_path/2), my,
                            lw_path, ny - my + math.ceil(lw_path/2), col)
                    end
                end

                -- Dot at cell center
                local dot_r = math.max(3, math.floor(cell * 0.18))
                bb:paintCircle(mx, my, dot_r, col)
            end
        end
    end

    -- Draw grid lines (thin, on top of paths)
    local thin = Size.line.thin or 1
    for i = 0, n do
        drawLine(bb, x + math.floor(i*cell), y, thin, self.dimen.h, C_GRID)
        drawLine(bb, x, y + math.floor(i*cell), self.dimen.w, thin, C_GRID)
    end

    -- Draw wrong marks overlay
    if not show then
        for r = 1, n do
            for c = 1, n do
                if self.board.wrong_marks[r][c] then
                    local cellx = x + math.floor((c-1)*cell)
                    local celly = y + math.floor((r-1)*cell)
                    -- Draw thin border around wrong cells
                    local bw = math.max(2, math.floor(cell * 0.06))
                    drawLine(bb, cellx, celly, math.ceil(cell), bw, C_WRONG)
                    drawLine(bb, cellx, celly, bw, math.ceil(cell), C_WRONG)
                    drawLine(bb, cellx, celly + math.ceil(cell) - bw, math.ceil(cell), bw, C_WRONG)
                    drawLine(bb, cellx + math.ceil(cell) - bw, celly, bw, math.ceil(cell), C_WRONG)
                end
            end
        end
    end

    -- Draw endpoint numbers and active highlight
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2*pad))
    local active_color = not show and self.board.active_color

    for r = 1, n do
        for c = 1, n do
            local clue = self.board.clues[r][c]
            if clue > 0 then
                local cellx  = x + math.floor((c-1)*cell)
                local celly  = y + math.floor((r-1)*cell)
                local cw     = math.ceil(cell)
                local ch     = math.ceil(cell)
                local col_id = clue
                local bg_col = colorFor(col_id)

                -- Fill endpoint background
                bb:paintRect(cellx, celly, cw, ch, bg_col)

                -- Highlight active endpoint
                if active_color == col_id then
                    local hl = math.max(2, math.floor(cell * 0.07))
                    drawLine(bb, cellx, celly, cw, hl, C_ACTIVE)
                    drawLine(bb, cellx, celly, hl, ch, C_ACTIVE)
                    drawLine(bb, cellx, celly + ch - hl, cw, hl, C_ACTIVE)
                    drawLine(bb, cellx + cw - hl, celly, hl, ch, C_ACTIVE)
                end

                -- Draw number
                local text   = tostring(clue)
                local is_dark = col_id <= 2
                local tc     = is_dark and C_TEXT_WITE or C_TEXT_DARK
                local m      = RenderText:sizeUtf8Text(0, inner, self.number_face, text, true, false)
                local base_y = celly + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                local base_x = cellx + pad + math.floor((inner - m.x) / 2)
                RenderText:renderUtf8Text(bb, base_x, base_y, self.number_face, text, true, false, tc)
            end
        end
    end
end

return NumberlinkBoardWidget
