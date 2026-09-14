---@module 'luassert'

local util = require('tests.util')

-- github strips the backslash from an escaped pipe before the cell is parsed,
-- so '\|' renders as a single character, even inside a code span
describe('table escape', function()
    local lines = {
        '| Heading 1  | Heading 2 |',
        '| ---------- | --------- |',
        '| a \\| b     | c         |',
        '| `x\\|y` z   | d         |',
        '| Item 1     | Item 2    |',
    }

    ---@param cell render.md.table.Cell
    local function setup(cell)
        util.setup.text(lines, { pipe_table = { cell = cell } })
    end

    it('padded', function()
        setup('padded')
        util.assert_screen({
            '│ Heading 1  │ Heading 2 │',
            '├────────────┼───────────┤',
            '│ a | b      │ c         │',
            '│ x|y z      │ d         │',
            '│ Item 1     │ Item 2    │',
            '└────────────┴───────────┘',
        })
    end)

    it('trimmed', function()
        setup('trimmed')
        util.assert_screen({
            '│ Heading 1 │ Heading 2 │',
            '├───────────┼───────────┤',
            '│ a | b     │ c         │',
            '│ x|y z     │ d         │',
            '│ Item 1    │ Item 2    │',
            '└───────────┴───────────┘',
        })
    end)

    it('overlay', function()
        -- an escaped pipe is not a border, so it is not replaced by one
        setup('overlay')
        util.assert_screen({
            '│ Heading 1  │ Heading 2 │',
            '├────────────┼───────────┤',
            '│ a \\| b     │ c         │',
            '│ `x\\|y` z   │ d         │',
            '│ Item 1     │ Item 2    │',
            '└────────────┴───────────┘',
        })
    end)

    it('wrapped', function()
        -- the cursor is on the header, which keeps its source on screen
        setup('wrapped')
        util.assert_screen({
            '| Heading 1  | Heading 2 |',
            '├───────────┼───────────┤',
            '│ a | b     │ c         │',
            '├───────────┼───────────┤',
            '│ `x|y` z   │ d         │',
            '├───────────┼───────────┤',
            '│ Item 1    │ Item 2    │',
            '└───────────┴───────────┘',
        })
    end)
end)
