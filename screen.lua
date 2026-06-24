local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase             = lrequire_common("screen_base")
local MenuHelper             = lrequire_common("menu_helper")
local NumberlinkBoardWidget  = lrequire("board_widget")
local NumberlinkBoard        = lrequire("board")

local DeviceScreen = Device.screen

local GRID_SIZES = { 5, 7, 9, 10 }

local GAME_RULES_EN = _([[
Number Link — Rules

Connect each pair of matching numbers with a continuous path.

Rules:
• Draw a path from each number to its matching partner.
• Paths move horizontally or vertically — no diagonal moves.
• Paths cannot cross or share cells with one another.
• Every cell in the grid must be covered by exactly one path.

Tap a numbered cell to start a path, then tap adjacent cells to extend it.
]])

local GAME_RULES_FR = [[
Number Link — Règles

Reliez chaque paire de chiffres identiques par un chemin continu.

Règles :
• Tracez un chemin depuis chaque chiffre jusqu'à son homologue de même valeur.
• Les chemins se déplacent horizontalement ou verticalement — pas en diagonale.
• Les chemins ne peuvent pas se croiser ni partager des cases.
• Chaque case de la grille doit être couverte par exactement un chemin.

Appuyez sur une case numérotée pour commencer un chemin, puis appuyez sur les cases adjacentes pour l'étendre.
]]

local NumberlinkScreen = ScreenBase:extend{}

function NumberlinkScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = NumberlinkBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.last_check_result = nil
    ScreenBase.init(self)
end

function NumberlinkScreen:serializeState()
    return self.board:serialize()
end

function NumberlinkScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = NumberlinkBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("New game"), callback = function() self:onNewGame() end },
                { id = "grid_button",  text = self:getGridButtonText(),
                  callback = function() self:openGridMenu() end },
                { id = "diff_button",  text = self:getDiffButtonText(),
                  callback = function() self:openDifficultyMenu() end },
                { id = "reveal_button", text = self:getRevealButtonText(),
                  callback = function() self:toggleSolution() end },
                self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
                self:makeCloseButtonConfig(),
            },
        },
    }
    self.grid_button   = top_buttons:getButtonById("grid_button")
    self.diff_button   = top_buttons:getButtonById("diff_button")
    self.reveal_button = top_buttons:getButtonById("reveal_button")

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("Check"), callback = function() self:onCheck() end },
                { id = "undo_button", text = _("Undo"),
                  callback = function() self:onUndo() end },
                { text = _("Rules"), callback = function() self:showRulesHint() end },
            },
        },
    }
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

function NumberlinkScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() then return end
    if is_hold then
        self.board:holdCell(r, c)
    else
        self.board:tapCell(r, c)
    end
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! All paths connected!"))
    else
        self:updateStatus()
    end
end

function NumberlinkScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = NumberlinkBoard:new{ n = n }
    self.board:generate(diff)
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function NumberlinkScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.last_check_result = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function NumberlinkScreen:onCheck()
    self.board:checkProgress()
    self.board_widget:refresh()
    local completed  = self.board:getCompletedPairs()
    local n_colors   = self.board.n_colors
    local remaining  = self.board:getRemainingCells()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! All paths connected!"))
    else
        self.last_check_result = false
        self:updateStatus(T(_("Pairs: %1/%2 \xC2\xB7 Empty cells: %3"), completed, n_colors, remaining))
    end
end

function NumberlinkScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function NumberlinkScreen:showRulesHint()
    self:showMessage(_(
        "Numberlink rules:\n" ..
        "Connect each pair of matching numbers with a path.\n" ..
        "Paths may not cross or share cells.\n" ..
        "Every cell must be covered by exactly one path.\n\n" ..
        "Tap a number: select as path start\n" ..
        "Tap adjacent cell: extend active path\n" ..
        "Hold on path: clear that color's path"
    ), 10)
end

function NumberlinkScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 5),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function NumberlinkScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function NumberlinkScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = _("Congratulations! All paths connected!")
    else
        local remaining = self.board:getRemainingCells()
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Pairs: %4 \xC2\xB7 Empty: %5"),
            self.board.n, self.board.n, label, self.board.n_colors, remaining)
    end
    ScreenBase.updateStatus(self, status)
end

function NumberlinkScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function NumberlinkScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function NumberlinkScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide") or _("Show")
end

function NumberlinkScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return NumberlinkScreen
