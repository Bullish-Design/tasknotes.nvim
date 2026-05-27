local M = {}

local config = require("tasknotes.config")

local function today()
  return os.date("%Y-%m-%d")
end

local function is_valid_ymd(value)
  if type(value) ~= "string" then
    return false
  end

  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)

  if not year or month < 1 or month > 12 or day < 1 or day > 31 then
    return false
  end

  local normalized = os.date("%Y-%m-%d", os.time({
    year = year, month = month, day = day, hour = 12,
  }))

  return normalized == value
end

local function normalize_initial(initial)
  if type(initial) == "string" and is_valid_ymd(initial) then
    return initial
  end
  return today()
end

function M.today()
  return today()
end

function M.is_valid_date(value)
  return is_valid_ymd(value)
end

function M.pick_date(opts)
  opts = opts or {}

  local tasknotes_opts = config.get()
  local dp = tasknotes_opts.ui and tasknotes_opts.ui.date_picker or {}

  if dp.enabled == false then
    return M.pick_with_text(opts)
  end

  local backend = opts.backend or dp.backend or "datepicker.nvim"

  if backend == "datepicker.nvim" then
    local ok = pcall(require, "datepicker")
    if ok then
      return M.pick_with_datepicker_nvim(opts)
    end

    if dp.fallback_backend == "text" then
      return M.pick_with_text(opts)
    end

    vim.notify("datepicker.nvim is not available", vim.log.levels.WARN)
    return
  end

  return M.pick_with_text(opts)
end

function M.pick_with_datepicker_nvim(opts)
  local datepicker = require("datepicker")
  local tasknotes_opts = config.get()
  local dp = tasknotes_opts.ui and tasknotes_opts.ui.date_picker or {}

  datepicker.open({
    title = opts.title or "Select date",
    initial_date = normalize_initial(opts.initial),
    week_start = opts.week_start or dp.week_start or "monday",
    on_select = function(date)
      if not date or not date.iso then
        return
      end
      if opts.on_select then
        opts.on_select(date.iso)
      end
    end,
  })
end

function M.pick_with_text(opts)
  vim.ui.input({
    prompt = opts.title or "Date (YYYY-MM-DD): ",
    default = normalize_initial(opts.initial),
  }, function(value)
    if not value or value == "" then
      return
    end

    if not is_valid_ymd(value) then
      vim.notify("Invalid date. Expected YYYY-MM-DD.", vim.log.levels.ERROR)
      return
    end

    if opts.on_select then
      opts.on_select(value)
    end
  end)
end

return M
