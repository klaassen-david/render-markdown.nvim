local Base = require('render-markdown.render.base')
local env = require('render-markdown.lib.env')
local iter = require('render-markdown.lib.iter')
local log = require('render-markdown.core.log')
local str = require('render-markdown.lib.str')

---Greedy wrap on whitespace, hard breaking words wider than the column.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
    local lines, current = {}, ''
    for word in text:gmatch('%S+') do
        local candidate = current == '' and word or (current .. ' ' .. word)
        if str.width(candidate) <= width then
            current = candidate
        else
            if current ~= '' then
                lines[#lines + 1] = current
            end
            current = word
            while str.width(current) > width do
                lines[#lines + 1] = str.sub(current, 1, width)
                current = str.sub(current, width + 1, str.width(current))
            end
        end
    end
    if current ~= '' then
        lines[#lines + 1] = current
    end
    return #lines > 0 and lines or { '' }
end

---@class render.md.table.Data
---@field layout render.md.table.Layout
---@field delim render.md.Node
---@field cols render.md.table.Col[]
---@field rows render.md.table.Row[]

---@class render.md.table.Layout
---@field col integer
---@field valid boolean

---@class render.md.table.Col
---@field width integer
---@field alignment render.md.table.col.Alignment

---@enum render.md.table.col.Alignment
local Alignment = {
    left = 'left',
    right = 'right',
    center = 'center',
    default = 'default',
}

---@class render.md.table.Row
---@field node render.md.Node
---@field pipes render.md.Node[]
---@field cells render.md.table.row.Cell[]

---@class render.md.table.row.Cell
---@field node render.md.Node
---@field width integer
---@field space render.md.table.cell.Space

---@class render.md.table.cell.Space
---@field left integer
---@field right integer

---@class render.md.table.row.Parts
---@field pipes render.md.Node[]
---@field cells render.md.Node[]

---@class render.md.render.Table: render.md.Render
---@field private config render.md.table.Config
---@field private data render.md.table.Data
local Render = setmetatable({}, Base)
Render.__index = Render

---@protected
---@return boolean
function Render:setup()
    self.config = self.context.config.pipe_table
    if not self.config.enabled then
        return false
    end

    -- ensure delimiter and rows exist
    local delim = nil ---@type render.md.Node?
    local row_nodes = {} ---@type render.md.Node[]
    local types = {
        delim = 'pipe_table_delimiter_row',
        row = { 'pipe_table_header', 'pipe_table_row' },
        skip = { 'block_continuation' },
    }
    self.node:for_each_child(function(node)
        if node.type == types.delim then
            delim = node
        elseif self.context.view:overlaps(node:get()) then
            if vim.tbl_contains(types.row, node.type) then
                row_nodes[#row_nodes + 1] = node
            elseif not vim.tbl_contains(types.skip, node.type) then
                log.unhandled(self.context.buf, 'markdown', 'row', node.type)
            end
        end
    end)
    if not delim or #row_nodes == 0 then
        return false
    end

    ---@type render.md.table.Layout
    local layout = { col = delim:col(), valid = true }

    local cols = self:parse_cols(delim)
    if not cols then
        return false
    end

    local rows = {} ---@type render.md.table.Row[]
    table.sort(row_nodes)
    for _, row_node in ipairs(row_nodes) do
        local row = self:parse_row(row_node, #cols)
        if row then
            if row.node:col() ~= layout.col then
                layout.valid = false
            end
            rows[#rows + 1] = row
        end
    end
    if #rows == 0 then
        return false
    end

    -- store the max width in cols
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row.cells) do
            local space = cell.space.left + cell.space.right
            local available = space - (2 * self.config.padding)
            -- if we don't have enough space for padding add it to the width
            local width = cell.width
            if available < 0 then
                width = width - available
            end
            if self.config.cell == 'trimmed' then
                width = width - math.max(available, 0)
            end
            cols[i].width = math.max(cols[i].width, width)
        end
    end

    if self.config.cell == 'wrapped' then
        self:fit(cols, rows)
    end

    self.data = { layout = layout, delim = delim, cols = cols, rows = rows }

    return true
end

---Size columns to the window: natural content widths, then shave the widest
---until a row fits. Stored widths include padding, as in every other mode.
---@private
---@param cols render.md.table.Col[]
---@param rows render.md.table.Row[]
function Render:fit(cols, rows)
    local padding = 2 * self.config.padding
    local minimum = math.max(self.config.min_width, 3)
    local total = 0
    for i, col in ipairs(cols) do
        col.width = minimum
        for _, row in ipairs(rows) do
            col.width =
                math.max(col.width, str.width(vim.trim(row.cells[i].node.text)))
        end
        total = total + col.width
    end
    local budget = env.win.width(self.context.win)
        - (#cols + 1)
        - (#cols * padding)
    while total > budget do
        local widest = nil ---@type render.md.table.Col?
        for _, col in ipairs(cols) do
            if
                col.width > minimum and (not widest or col.width > widest.width)
            then
                widest = col
            end
        end
        if not widest then
            break
        end
        widest.width, total = widest.width - 1, total - 1
    end
    for _, col in ipairs(cols) do
        col.width = col.width + padding
    end
end

---@private
---@param node render.md.Node
---@return render.md.table.Col[]?
function Render:parse_cols(node)
    local parts = self:parse_row_parts(node, 'pipe_table_delimiter_cell')
    if not parts then
        return nil
    end
    local cols = {} ---@type render.md.table.Col[]
    for i, cell in ipairs(parts.cells) do
        local start_col = parts.pipes[i].end_col
        local end_col = parts.pipes[i + 1].start_col
        local width = end_col - start_col
        assert(width >= 0, 'invalid table layout')
        if self.config.cell == 'padded' then
            width = math.max(width, self.config.min_width)
        elseif self.config.cell == 'trimmed' then
            width = self.config.min_width
        end
        cols[#cols + 1] = {
            width = width,
            alignment = Render.alignment(cell),
        }
    end
    return cols
end

---@private
---@param node render.md.Node
---@return render.md.table.col.Alignment
function Render.alignment(node)
    local left = node:child('pipe_table_align_left')
    local right = node:child('pipe_table_align_right')
    if left and right then
        return Alignment.center
    elseif left then
        return Alignment.left
    elseif right then
        return Alignment.right
    else
        return Alignment.default
    end
end

---@private
---@param node render.md.Node
---@param num_cols integer
---@return render.md.table.Row?
function Render:parse_row(node, num_cols)
    local parts = self:parse_row_parts(node, 'pipe_table_cell')
    if not parts or #parts.cells ~= num_cols then
        return nil
    end
    local cells = {} ---@type render.md.table.row.Cell[]
    for i, cell in ipairs(parts.cells) do
        -- account for double width glyphs by replacing cell range with width
        local start_col = parts.pipes[i].end_col
        local end_col = parts.pipes[i + 1].start_col
        local width = (end_col - start_col)
            - (cell.end_col - cell.start_col)
            + self.context:width(cell)
            + self.config.cell_offset({ node = cell:get() })
        assert(width >= 0, 'invalid table layout')
        cells[#cells + 1] = {
            node = cell,
            width = width,
            space = {
                -- gap between the cell start and the pipe start
                left = math.max(cell.start_col - start_col, 0),
                -- attached to the end of the cell itself
                right = math.max(str.spaces('end', cell.text), 0),
            },
        }
    end
    ---@type render.md.table.Row
    return { node = node, pipes = parts.pipes, cells = cells }
end

---@private
---@param node render.md.Node
---@param cell_type string
---@return render.md.table.row.Parts?
function Render:parse_row_parts(node, cell_type)
    local pipes = {} ---@type render.md.Node[]
    local cells = {} ---@type render.md.Node[]
    node:for_each_child(function(child)
        if child.type == '|' then
            pipes[#pipes + 1] = child
        elseif child.type == cell_type then
            cells[#cells + 1] = child
        else
            log.unhandled(self.context.buf, 'markdown', 'cell', child.type)
        end
    end)
    if #pipes == 0 or #cells == 0 or #pipes ~= #cells + 1 then
        return nil
    end
    table.sort(pipes)
    table.sort(cells)
    ---@type render.md.table.row.Parts
    return { pipes = pipes, cells = cells }
end

---@protected
function Render:run()
    self:delimiter()
    for _, row in ipairs(self.data.rows) do
        self:row(row)
    end
    if self.config.border_enabled and self.data.layout.valid then
        self:border()
    end
end

---@private
function Render:delimiter()
    local delim = self.data.delim
    local border = self.config.border
    local indicator = self.config.alignment_indicator

    local icon = border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        -- must have enough space to put the alignment indicator
        -- alignment indicator must be exactly one character wide
        -- do not put an indicator for default alignment
        local add_indicator = col.width >= 3
            and str.width(indicator) == 1
            and col.alignment ~= Alignment.default
        if not add_indicator then
            return icon:rep(col.width)
        end
        if col.alignment == Alignment.left then
            return indicator .. icon:rep(col.width - 1)
        elseif col.alignment == Alignment.right then
            return icon:rep(col.width - 1) .. indicator
        else
            return indicator .. icon:rep(col.width - 2) .. indicator
        end
    end)
    local delimiter = border[4] .. table.concat(parts, border[5]) .. border[6]

    local line = self:line()
    line:pad(str.spaces('start', delim.text))
    line:text(delimiter, self.config.head)
    line:pad(str.width(delim.text) - line:width())
    if self.config.cell == 'wrapped' then
        self.marks:over(self.config, false, delim, { conceal = '' })
    end
    self.marks:over(self.config, self:element('table_border'), delim, {
        virt_text = line:get(),
        virt_text_pos = 'overlay',
    })
end

---@private
---@param row render.md.table.Row
function Render:row(row)
    local icon = self.config.border[10]
    local header = row.node.type == 'pipe_table_header'
    local highlight = header and self.config.head or self.config.row

    if vim.tbl_contains({ 'trimmed', 'padded', 'raw' }, self.config.cell) then
        for _, pipe in ipairs(row.pipes) do
            self.marks:over(self.config, 'table_border', pipe, {
                virt_text = { { icon, highlight } },
                virt_text_pos = 'overlay',
            })
        end
    end

    if vim.tbl_contains({ 'trimmed', 'padded' }, self.config.cell) then
        for i, cell in ipairs(row.cells) do
            local col = self.data.cols[i]
            local node = cell.node
            local space = cell.space
            local fill = col.width - cell.width
            -- delim(20) : --------------------
            -- col(4,7,2): ----XXXXXXX--
            -- fill(7)   :              _______
            if not self.context.conceal:enabled() then
                -- result: ----XXXXXXX--_______
                -- without concealing it is impossible to do full alignment
                self:shift(node, 'right', fill)
            elseif col.alignment == Alignment.center then
                -- (7 + 2 - 4) // 2 = 5 // 2 = 2 -> move two spaces to the right
                -- result: __----XXXXXXX--_____
                local shift = math.floor((fill + space.right - space.left) / 2)
                self:shift(node, 'left', shift)
                self:shift(node, 'right', fill - shift)
            elseif col.alignment == Alignment.right then
                -- 2 - 1 = 1 -> conceal one space on right side
                -- result: -_______----XXXXXXX-
                local shift = space.right - self.config.padding
                self:shift(node, 'left', fill + shift)
                self:shift(node, 'right', -shift)
            else
                -- 4 - 1 = 3 -> conceal three spaces on left side
                -- result: -XXXXXXX--_______---
                local shift = space.left - self.config.padding
                self:shift(node, 'left', -shift)
                self:shift(node, 'right', fill + shift)
            end
        end
    elseif self.config.cell == 'overlay' then
        self.marks:over(self.config, 'table_border', row.node, {
            virt_text = { { row.node.text:gsub('|', icon), highlight } },
            virt_text_pos = 'overlay',
        })
    elseif self.config.cell == 'wrapped' then
        self:wrapped(row, highlight)
    end
end

---Replace the row with a grid of its wrapped cells: the source text is
---concealed, the first rendered line goes over it, the rest below as virtual
---lines. Motions still see one line per row.
---@private
---@param row render.md.table.Row
---@param highlight string
function Render:wrapped(row, highlight)
    if not self.context.conceal:enabled() then
        return
    end
    local cols = self.data.cols
    local padding = self.config.padding
    local icon = self.config.border[10]

    local cells, height = {}, 1
    for i, cell in ipairs(row.cells) do
        cells[i] = wrap(vim.trim(cell.node.text), cols[i].width - (2 * padding))
        height = math.max(height, #cells[i])
    end

    local lines = {} ---@type render.md.Line[]
    for h = 1, height do
        local line = self:line():text(icon, highlight)
        for i, col in ipairs(cols) do
            local text = cells[i][h] or ''
            local fill = col.width - (2 * padding) - str.width(text)
            local left = 0
            if col.alignment == Alignment.right then
                left = fill
            elseif col.alignment == Alignment.center then
                left = math.floor(fill / 2)
            end
            line:pad(padding + left)
            line:text(text, highlight)
            line:pad(padding + fill - left)
            line:text(icon, highlight)
        end
        lines[h] = line
    end

    if
        env.row.get(self.context.buf, self.context.win) == row.node.start_row
    then
        self:source(row, height)
    else
        self:place(row, lines)
    end
end

---The row under the cursor keeps its source on screen: the real line is left
---alone, so it carries its own highlighting and a cursor that sits where it
---actually is, and whatever runs past the window edge is continued below as
---virtual lines. The block is padded to the height the rendered row would have
---taken, so hovering a row never moves the rows around it.
---@private
---@param row render.md.table.Row
---@param height integer
function Render:source(row, height)
    local width = env.win.width(self.context.win)
    local text = row.node.text
    local total = str.width(text)
    local rest = {} ---@type render.md.mark.Line[]
    local col = width + 1
    while col <= total do
        local chunk = str.sub(text, col, col + width - 1)
        local line = self:line():text(chunk, self.config.row)
        rest[#rest + 1] = self:indent():line(true):extend(line):get()
        col = col + width
    end
    while #rest < height - 1 do
        rest[#rest + 1] = self:indent():line(true):pad(1):get()
    end
    self:separator(row, rest)
    if #rest > 0 then
        self.marks:add(self.config, false, row.node.start_row, 0, {
            virt_lines = rest,
        })
    end
end

---Conceal the source row, put the first rendered line over it and the rest
---below as virtual lines, keeping the grid around it intact.
---@private
---@param row render.md.table.Row
---@param lines render.md.Line[]
function Render:place(row, lines)
    self.marks:over(self.config, false, row.node, { conceal = '' })
    self.marks:over(self.config, false, row.node, {
        virt_text = lines[1]:get(),
        virt_text_pos = 'overlay',
    })

    local rest = {} ---@type render.md.mark.Line[]
    for h = 2, #lines do
        rest[#rest + 1] = self:indent():line(true):extend(lines[h]):get()
    end
    self:separator(row, rest)
    if #rest > 0 then
        self.marks:add(self.config, false, row.node.start_row, 0, {
            virt_lines = rest,
        })
    end
end

---Wrapped mode draws the source of the row under the cursor itself, so none of
---its marks should be hidden by anti-conceal.
---@private
---@param element render.md.Element
---@return render.md.mark.Conceal
function Render:element(element)
    if self.config.cell == 'wrapped' then
        return false
    end
    return element
end

---The delimiter row already separates the header, the bottom border closes the
---last row.
---@private
---@param row render.md.table.Row
---@param rest render.md.mark.Line[]
function Render:separator(row, rest)
    local rows = self.data.rows
    local skip = row.node.type == 'pipe_table_header' or rows[#rows] == row
    if not self.config.border_enabled or skip then
        return
    end
    local border = self.config.border
    local separator = self:grid({ border[4], border[5], border[6] })
    rest[#rest + 1] = self:indent():line(true):extend(separator):get()
end

---@private
---@param chars [string, string, string]
---@return render.md.Line
function Render:grid(chars)
    local icon = self.config.border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        return icon:rep(col.width)
    end)
    local text = chars[1] .. table.concat(parts, chars[2]) .. chars[3]
    return self:line():text(text, self.config.row)
end

---Use low priority to include pipe marks
---@private
---@param node render.md.Node
---@param side 'left'|'right'
---@param amount integer
function Render:shift(node, side, amount)
    local col = side == 'left' and node.start_col or node.end_col
    if amount > 0 then
        self.marks:add(self.config, true, node.start_row, col, {
            priority = 0,
            virt_text = self:line():pad(amount):get(),
            virt_text_pos = 'inline',
        })
    elseif amount < 0 then
        amount = amount - self.context.conceal:width('', 1)
        self.marks:add(self.config, true, node.start_row, col + amount, {
            priority = 0,
            end_col = col,
            conceal = '',
        })
    end
end

---@private
function Render:border()
    local rows = self.data.rows
    local border = self.config.border

    ---@param row render.md.table.Row
    ---@return boolean
    local function width_equal(row)
        if
            vim.tbl_contains(
                { 'trimmed', 'padded', 'wrapped' },
                self.config.cell
            )
        then
            -- assume table was modified to match
            return true
        elseif self.config.cell == 'raw' then
            -- want the computed widths to match
            for i, cell in ipairs(row.cells) do
                if cell.width ~= self.data.cols[i].width then
                    return false
                end
            end
            return true
        elseif self.config.cell == 'overlay' then
            -- want the underlying text widths to match
            return str.width(row.node.text) == str.width(self.data.delim.text)
        else
            return false
        end
    end

    local first = rows[1]
    local last = rows[#rows]
    if not width_equal(first) or not width_equal(last) then
        return
    end

    local icon = border[11]
    local parts = iter.list.map(self.data.cols, function(col)
        return icon:rep(col.width)
    end)

    ---@param node render.md.Node
    ---@param above boolean
    ---@param chars [string, string, string]
    local function table_border(node, above, chars)
        local text = chars[1] .. table.concat(parts, chars[2]) .. chars[3]
        local highlight = above and self.config.head or self.config.row
        local line = self:line():pad(self.data.layout.col):text(text, highlight)

        local virtual = self.config.border_virtual
        local row, target = node:line(above and 'above' or 'below', 1)
        local available = target and str.width(target) == 0

        if not virtual and available and self.context.used:take(row) then
            self.marks:add(self.config, self:element('table_border'), row, 0, {
                virt_text = line:get(),
                virt_text_pos = 'overlay',
            })
        else
            self.marks:add(
                self.config,
                self:element('virtual_lines'),
                node.start_row,
                0,
                {
                    virt_lines = { self:indent():line(true):extend(line):get() },
                    virt_lines_above = above,
                }
            )
        end
    end

    table_border(first.node, true, { border[1], border[2], border[3] })
    if #rows > 1 then
        table_border(last.node, false, { border[7], border[8], border[9] })
    end
end

return Render
