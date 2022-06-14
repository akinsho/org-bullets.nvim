local M = {}

local api = vim.api

local NAMESPACE = api.nvim_create_namespace("org-bullets")
local org_headline_hl = "OrgTSHeadlineLevel"

local list_groups = {
  ["-"] = "OrgTSHeadlineLevel1",
  ["+"] = "OrgTSHeadlineLevel2",
  ["*"] = "OrgTSHeadlineLevel3",
}

---@class BulletsConfig
---@field public show_current_line boolean
---@field public symbols string[] | function(symbols: string[]): string[]
---@field public indent boolean
local defaults = {
  show_current_line = false,
  symbols = {
    headlines = { "◉", "○", "✸", "✿" },
    checkboxes = {
      half = { "", "OrgCancelled" },
      done = { "✓", "OrgDone" },
      undone = { "˟", "OrgTSCheckbox" },
    },
    bullet = "•",
  },
  indent = true,
  -- TODO: should this read from the user's conceal settings?
  -- maybe but that option is a little complex and will make
  -- the implementation more convoluted
  concealcursor = false,
}

local config = {}

---Merge a user config with the defaults
---@param user_config BulletsConfig
local function set_config(user_config)
  local headlines = vim.tbl_get(user_config, "symbols", "headlines")
  local default_headlines = defaults.symbols.headlines
  if headlines and type(headlines) == "function" then
    user_config.symbols.headlines = user_config.symbols(default_headlines) or default_headlines
  end
  config = vim.tbl_deep_extend("keep", user_config, defaults)
end

---Add padding to the given symbol
---@param symbol string
---@param padding_spaces number
---@param padding_in_front boolean
local function add_symbol_padding(symbol, padding_spaces, padding_in_front)
  if padding_in_front then
    return string.rep(" ", padding_spaces - 1) .. symbol
  else
    return symbol .. string.rep(" ", padding_spaces)
  end
end

---Sets of pairs {pattern = handler}
---handler
---@param str string
---@param conf BulletsConfig
---@return string symbol, string highlight_group
local markers = {
  stars = function(str, conf)
    local level = #str <= 0 and 0 or #str
    local symbols = conf.symbols.headlines
    local symbol = add_symbol_padding((symbols[level] or conf.symbols[1]), level, conf.indent)
    local highlight = org_headline_hl .. level
    return { { symbol, highlight } }
  end,
  -- Checkboxes [x]
  expr = function(str, conf)
    local symbols = conf.symbols.checkboxes
    if str:match("X") then
      return { { "[", "OrgTSCheckboxChecked" }, symbols.done, { "]", "OrgTSCheckboxChecked" } }
    elseif str:match("-") then
      return {
        { "[", "OrgTSCheckboxHalfChecked" },
        symbols.half,
        { "]", "OrgTSCheckboxHalfChecked" },
      }
      --[[ elseif str:match(" ") then
      return { { "[", "OrgTSCheckbox" }, symbols.undone, { "]", "OrgTSCheckbox" } } ]]
    end
  end,
  -- List bullets *,+,-
  bullet = function(str, conf)
    local symbol = add_symbol_padding(conf.symbols.bullet, (#str - 1), true)
    return { { symbol, list_groups[vim.trim(str)] } }
  end,
}

---Set an extmark (safely)
---@param bufnr number
---@param virt_text string[][] a tuple of character and highlight
---@param lnum integer
---@param start_col integer
---@param end_col integer
---@param highlight string?
local function set_mark(bufnr, virt_text, lnum, start_col, end_col, highlight)
  local ok, result = pcall(api.nvim_buf_set_extmark, bufnr, NAMESPACE, lnum, start_col, {
    end_col = end_col,
    hl_group = highlight,
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    ephemeral = true,
  })
  if not ok then
    vim.schedule(function()
      vim.notify_once(result, "error", { title = "Org bullets" })
    end)
  end
end

--- Get the position objects for each time of item we are concealing
---@param bufnr number
---@param start_row number
---@param end_row number
---@param root table treesitter root node
---@return Position[]
local function get_ts_positions(bufnr, start_row, end_row, root)
  local positions = {}
  -- TODO: This query does not work because the grammar recognises [ ] as three expressions not one
  -- (((expr) @_todo (#eq? @_todo "[ ]")) @todo)
  local query = vim.treesitter.parse_query(
    "org",
    [[
      (stars) @stars
      (bullet) @bullet
      ((expr) @_done (#eq? @_done "[X]")) @done
      ((expr) @_half (#eq? @_half "[-]")) @half
    ]]
  )
  for _, node, metadata in query:iter_captures(root, bufnr, start_row, end_row) do
    local type = node:type()
    local row1, col1, row2, col2 = node:range()
    positions[#positions + 1] = {
      type = type,
      item = vim.treesitter.get_node_text(node, bufnr),
      start_row = row1,
      start_col = col1,
      end_row = row2,
      end_col = col2,
      metadata = metadata,
    }
  end
  return positions
end

---@class Position
---@field start_row number
---@field start_col number
---@field end_row number
---@field end_col number
---@field item string

---Set a single line extmark
---@param bufnr number
---@param positions table<string, Position[]>
---@param conf BulletsConfig
local function set_position_marks(bufnr, positions, conf)
  for _, position in ipairs(positions) do
    local str = position.item
    local start_row = position.start_row
    local start_col = position.start_col
    local end_col = position.end_col
    local handler = markers[position.type]

    -- Don't add conceal on the current cursor line if the user doesn't want it
    local is_concealed = true
    if not conf.concealcursor then
      local cursor_row = api.nvim_win_get_cursor(0)[1]
      is_concealed = start_row ~= (cursor_row - 1)
    end
    if is_concealed and start_col > -1 and end_col > -1 and handler then
      set_mark(bufnr, handler(str, conf), start_row, start_col, end_col)
    end
  end
end

local get_parser = (function()
  local parsers = {}
  return function(bufnr)
    if parsers[bufnr] then
      return parsers[bufnr]
    end
    parsers[bufnr] = vim.treesitter.get_parser(bufnr, "org", {})
    return parsers[bufnr]
  end
end)()

--- Get the position of the relevant org mode items to conceal
---@param bufnr number
---@param start_row number
---@param end_row number
---@return Position[]
local function get_mark_positions(bufnr, start_row, end_row)
  local parser = get_parser(bufnr)
  local positions = {}
  parser:for_each_tree(function(tstree, _)
    positions = get_ts_positions(bufnr, start_row, end_row, tstree:root())
  end)
  return positions
end

local ticks = {}
---Save the user config and initialise the plugin
---@param conf BulletsConfig
function M.setup(conf)
  conf = conf or {}
  set_config(conf)
  api.nvim_set_decoration_provider(NAMESPACE, {
    on_start = function(_, tick)
      local buf = api.nvim_get_current_buf()
      if ticks[buf] == tick then
        return false
      end
      ticks[buf] = tick
      return true
    end,
    on_win = function(_, _, bufnr, topline, botline)
      if vim.bo[bufnr].filetype ~= "org" then
        return false
      end
      local positions = get_mark_positions(bufnr, topline, botline)
      set_position_marks(bufnr, positions, config)
    end,
    on_line = function(_, _, bufnr, row)
      local positions = get_mark_positions(bufnr, row, row + 1)
      set_position_marks(bufnr, positions, config)
    end,
  })
end

return M
