local Context = require('render-markdown.request.context')
local compat = require('render-markdown.lib.compat')
local env = require('render-markdown.lib.env')
local iter = require('render-markdown.lib.iter')
local log = require('render-markdown.core.log')
local state = require('render-markdown.state')

---@class render.md.Ui
local M = {}

M.ns = vim.api.nvim_create_namespace('render-markdown.nvim')

---cursor row per buffer as of the last parse
---@type table<integer, integer>
M.parsed = {}

---@param buf integer
---@param row? integer
---@return boolean
function M.table_row(buf, row)
    if not row then
        return false
    end
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return line ~= nil and line:match('^%s*|') ~= nil
end

---@private
---@type table<integer, render.md.Decorator>
M.cache = {}

---called from state on setup
function M.setup()
    -- clear marks and reset cache
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
    M.cache = {}
end

---@param buf integer
---@return render.md.Decorator
function M.get(buf)
    local result = M.cache[buf]
    if not result then
        result = require('render-markdown.lib.decorator').new(buf)
        M.cache[buf] = result
    end
    return result
end

---@param buf integer
---@param win integer
---@param event string
---@param force boolean
function M.update(buf, win, event, force)
    log.buf('info', 'Update', buf, event, ('force %s'):format(force))
    M.updater.new(buf, win, force):start()
end

---@class render.md.ui.Updater
---@field private buf integer
---@field private win integer
---@field private force boolean
---@field private decorator render.md.Decorator
---@field private config render.md.buf.Config
---@field private mode string
local Updater = {}
Updater.__index = Updater

---@param buf integer
---@param win integer
---@param force boolean
---@return render.md.ui.Updater
function Updater.new(buf, win, force)
    local self = setmetatable({}, Updater)
    self.buf = buf
    self.win = win
    self.force = force
    self.decorator = M.get(buf)
    self.config = state.get(buf)
    return self
end

function Updater:start()
    if not env.valid(self.buf, self.win) then
        return
    end
    self.decorator:schedule(
        self:changed() and not env.buf.empty(self.buf),
        self.config.debounce,
        log.runtime('update', function()
            self:run()
        end)
    )
end

---@private
---@return boolean
function Updater:changed()
    -- force or buffer has changed or we have not handled the visible range yet
    return self.force
        or self.decorator:changed()
        or not Context.contains(self.buf, self.win)
        or self:moved()
end

---A wrapped table row shows its source while the cursor is on it, so its marks
---depend on the cursor row and not only on the buffer and the visible range.
---@private
---@return boolean
function Updater:moved()
    if self.config.pipe_table.cell ~= 'wrapped' then
        return false
    end
    -- no state change: changed() runs twice per update, once to schedule and
    -- once to decide on a re-parse
    local row = env.row.get(self.buf, self.win)
    local was = M.parsed[self.buf]
    if row == was then
        return false
    end
    -- only when a table row is involved, moving through prose changes nothing
    return M.table_row(self.buf, row) or M.table_row(self.buf, was)
end

---@private
function Updater:run()
    if not env.valid(self.buf, self.win) then
        return
    end
    self.mode = env.mode.get() -- mode is only available after this point
    local render = self.config.enabled
        and self.config.resolved:render(self.mode)
        and (self.config.render.scrolled or env.win.view(self.win).leftcol == 0)
        and (self.config.render.diff or not env.win.get(self.win, 'diff'))
    log.buf('info', 'Render', self.buf, render)
    local next_state = render and 'rendered' or 'default'
    for _, win in ipairs(env.buf.wins(self.buf)) do
        for name, value in pairs(self.config.win_options) do
            env.win.set(win, name, value[next_state])
        end
    end
    if not render then
        self:clear()
    else
        self:render()
    end
end

---@private
function Updater:clear()
    local extmarks = self.decorator:get()
    for _, extmark in ipairs(extmarks) do
        extmark:hide(M.ns, self.buf)
    end
    vim.api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
    state.on.clear({ buf = self.buf, win = self.win })
end

---@private
function Updater:render()
    if self:changed() then
        self:parse(function(extmarks)
            if not extmarks then
                return
            end
            local initial = self.decorator:initial()
            self:clear()
            self.decorator:set(extmarks)
            if initial then
                compat.fix_lsp_window(self.buf, self.win, extmarks)
                state.on.initial({ buf = self.buf, win = self.win })
            end
            self:display()
        end)
    else
        self:display()
    end
end

---@private
---@param callback fun(extmarks: render.md.Extmark[]|nil)
function Updater:parse(callback)
    M.parsed[self.buf] = env.row.get(self.buf, self.win)
    local ok, parser = pcall(vim.treesitter.get_parser, self.buf)
    if ok and parser then
        -- reset buffer context
        local context = Context.new(self.buf, self.win, self.config)
        if context then
            -- make sure injections are processed
            context.view:parse(parser, function()
                local Extmark = require('render-markdown.lib.extmark')
                local handlers = require('render-markdown.core.handlers')
                local marks = handlers.run(context, parser)
                callback(iter.list.map(marks, Extmark.new))
            end)
        else
            log.buf('debug', 'Skip', self.buf, 'in progress')
            callback(nil)
        end
    else
        log.buf('error', 'Fail', self.buf, 'no treesitter parser found')
        callback(nil)
    end
end

---@private
function Updater:display()
    local range = self:hidden()
    local extmarks = self.decorator:get()
    for _, extmark in ipairs(extmarks) do
        if self:hide(extmark, range) then
            extmark:hide(M.ns, self.buf)
        else
            extmark:show(M.ns, self.buf)
        end
    end
    self:clamp()
    state.on.render({ buf = self.buf, win = self.win })
end

---A wrapped row shows its whole source while the cursor is on it, the tail on
---virtual lines below. A column past the window edge therefore has nothing to
---reveal, and reaching it would scroll the window horizontally, taking every
---other line on screen with it. Hold the cursor at the edge instead.
---@private
function Updater:clamp()
    local config = self.config.pipe_table
    if config.cell ~= 'wrapped' or not config.clamp_cursor then
        return
    end
    if self.win ~= vim.api.nvim_get_current_win() then
        return
    end
    -- editing needs the cursor exactly where it was put
    if vim.startswith(self.mode, 'i') or vim.startswith(self.mode, 'R') then
        return
    end
    local row = env.row.get(self.buf, self.win)
    if not row then
        return
    end
    local width = env.win.width(self.win)
    if vim.fn.virtcol('.') <= width then
        return
    end
    -- only on a table row, never on long prose
    if not M.table_row(self.buf, row) then
        return
    end
    local col = vim.fn.virtcol2col(self.win, row + 1, width)
    vim.api.nvim_win_set_cursor(self.win, { row + 1, math.max(col - 1, 0) })
    -- neovim scrolls to reach a column but not back once it fits again
    vim.fn.winrestview({ leftcol = 0 })
end

---@private
---@return render.md.Range?
function Updater:hidden()
    -- anti-conceal is not enabled -> hide nothing
    -- in disabled mode -> hide nothing
    local config = self.config.anti_conceal
    if not config.enabled or env.mode.is(self.mode, config.disabled_modes) then
        return nil
    end
    -- row is not known -> buffer is not active -> hide nothing
    local row = env.row.get(self.buf, self.win)
    if not row then
        return nil
    end
    if env.mode.is(self.mode, { 'v', 'V', '\22' }) then
        local start = vim.fn.getpos('v')[2] - 1
        ---@type render.md.Range
        return { math.min(row, start), math.max(row, start) }
    else
        ---@type render.md.Range
        return { row - config.above, row + config.below }
    end
end

---@private
---@param extmark render.md.Extmark
---@param range? render.md.Range
---@return boolean
function Updater:hide(extmark, range)
    local mark = extmark:get()

    -- not in top level or mark level modes -> hide
    local show = env.mode.join(self.config.render_modes, mark.modes)
    if not env.mode.is(self.mode, show) then
        return true
    end

    -- does not overlap with hidden range -> show
    if not extmark:overlaps(range) then
        return false
    end

    local conceal = mark.conceal
    if type(conceal) == 'boolean' then
        -- mark has conceal value -> respect
        return conceal
    else
        -- mark has conceal element -> show if anti-conceal is ignored
        local ignore = self.config.anti_conceal.ignore[conceal]
        return not (ignore and env.mode.is(self.mode, ignore))
    end
end

---@private
M.updater = Updater

return M
