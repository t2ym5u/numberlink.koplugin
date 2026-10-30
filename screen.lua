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

local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
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

Tap a numbered cell to start a path, then tap adjacent cells to extend it. Hold on a path cell to clear that color's path.
]])

local GAME_RULES_FR = [[
Number Link — Règles

Reliez chaque paire de chiffres identiques par un chemin continu.

Règles :
• Tracez un chemin depuis chaque chiffre jusqu'à son homologue de même valeur.
• Les chemins se déplacent horizontalement ou verticalement — pas en diagonale.
• Les chemins ne peuvent pas se croiser ni partager des cases.
• Chaque case de la grille doit être couverte par exactement un chemin.

Appuyez sur une case numérotée pour commencer un chemin, puis appuyez sur les cases adjacentes pour l'étendre. Restez appuyé sur une case du chemin pour effacer ce chemin.
]]

local NumberlinkScreen = ScreenBase:extend{}

-- The unit is a whole coloured path: revealing one cell of one would leave the
-- route half-drawn and say little, since the puzzle is about the route.
function NumberlinkScreen:describeHintStep(step, level)
    if level == 1 then
        return T(_("The path starting at R%1C%2 is not right yet. Tap Hint again to draw it."),
                 step.r, step.c)
    end
    return T(_("Drew the path starting at R%1C%2."), step.r, step.c)
end

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
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Numberlink"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    self:_updateUndoButton()
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    local frame_pad   = Size.padding.large
    local frame_extra = 2 * (frame_pad + Size.border.window)
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = NumberlinkBoardWidget:new{
        board        = self.board,
        -- Ten or more pairs means two-digit endpoints: size the font for them.
        max_value    = self.board.n_colors,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }
    local board_frame = FrameContainer:new{
        padding = frame_pad,
        margin  = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
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
        self:updateStatus(self:joinStatus(
            T(_("Pairs: %1/%2"), completed, n_colors),
            T(_("Empty: %1"), remaining)))
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

function NumberlinkScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
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
        status = self:joinStatus(
            T("%1×%1", self.board.n),
            label,
            T(_("Empty: %1"), remaining))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

-- Showing the solution can be hidden again, so only solving it ends the round.
function NumberlinkScreen:isRoundOver()
    return self.board:isSolved()
end

function NumberlinkScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function NumberlinkScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function NumberlinkScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function NumberlinkScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return NumberlinkScreen
