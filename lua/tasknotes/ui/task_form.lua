local M = {}

local has_nui, _ = pcall(require, "nui.popup")
if not has_nui then
  return M
end

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

local task_manager = require("tasknotes.task_manager")
local config = require("tasknotes.config")

-- Create form field lines
local function create_form_fields(task)
  task = task or {}
  local opts = config.get()

  local lines = {
    "TaskNotes Form",
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    "",
    "Title: " .. (task.title or ""),
    "",
    "Status: " .. (task.status or "open"),
    "",
    "Priority: " .. (task.priority or "none"),
    "",
    "Due Date (YYYY-MM-DD): " .. (task.due or ""),
    "",
    "Scheduled (YYYY-MM-DD): " .. (task.scheduled or ""),
    "",
    "Contexts (comma-separated): " .. table.concat(task.contexts or {}, ", "),
    "",
    "Projects (comma-separated): " .. table.concat(task.projects or {}, ", "),
    "",
    "Tags (comma-separated): " .. table.concat(task.tags or {}, ", "),
    "",
    "Blocked By (comma-separated file paths): " .. table.concat(task.blockedBy or {}, ", "),
    "",
    "Time Estimate (minutes): " .. (task.timeEstimate or ""),
    "",
    "",
    "[Press <CR> on a field to edit, <C-s> to save, <Esc> to cancel]",
  }

  return lines
end

-- Parse form data from buffer lines
local function parse_form_data(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local data = {}

  for _, line in ipairs(lines) do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key and value then
      key = key:gsub("^%s+", ""):gsub("%s+$", "") -- trim
      value = value:gsub("^%s+", ""):gsub("%s+$", "")

      if key == "Title" then
        data.title = value
      elseif key == "Status" then
        data.status = value
      elseif key == "Priority" then
        data.priority = value
      elseif key:match("Due Date") then
        data.due = value ~= "" and value or nil
      elseif key:match("Scheduled") then
        data.scheduled = value ~= "" and value or nil
      elseif key:match("Contexts") then
        data.contexts = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Projects") then
        data.projects = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Tags") then
        data.tags = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Blocked By") then
        data.blockedBy = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Time Estimate") then
        data.timeEstimate = value ~= "" and tonumber(value) or nil
      end
    end
  end

  return data
end

-- Validate form data
local function validate_data(data)
  if not data.title or data.title == "" then
    return false, "Title is required"
  end

  -- Validate date format if provided
  if data.due and data.due ~= "" then
    if not data.due:match("^%d%d%d%d%-%d%d%-%d%d$") then
      return false, "Due date must be in YYYY-MM-DD format"
    end
  end

  if data.scheduled and data.scheduled ~= "" then
    if not data.scheduled:match("^%d%d%d%d%-%d%d%-%d%d$") then
      return false, "Scheduled date must be in YYYY-MM-DD format"
    end
  end

  return true
end

-- Show task form
function M.show_form(task, on_save)
  local opts = config.get()
  local is_edit = task ~= nil

  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = opts.ui.border_style,
      text = {
        top = is_edit and " Edit Task " or " New Task ",
        top_align = "center",
      },
    },
    position = "50%",
    size = {
      width = opts.ui.task_form_width,
      height = opts.ui.task_form_height,
    },
    buf_options = {
      modifiable = true,
      readonly = false,
    },
  })

  -- Set form content
  local lines = create_form_fields(task)
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)

  -- Set buffer options
  vim.api.nvim_buf_set_option(popup.bufnr, "filetype", "tasknotes-form")

  -- Keymaps
  -- Save
  popup:map("n", "<C-s>", function()
    local data = parse_form_data(popup.bufnr)
    local valid, err = validate_data(data)

    if not valid then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    popup:unmount()

    if on_save then
      on_save(data)
    end
  end, { noremap = true })

  -- Cancel
  popup:on(event.BufLeave, function()
    popup:unmount()
  end)

  popup:mount()
end

-- Create new task
function M.new_task()
  M.show_form(nil, function(data)
    local task = task_manager.create_task(data)
    if task then
      -- Optionally open the new task file
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Open new task file?",
      }, function(choice)
        if choice == "Yes" then
          vim.cmd("edit " .. task.path)
          local hooks = require("tasknotes.hooks")
          local ctx = {
            operation = "open",
            task = task,
            path = task.path,
            opts = require("tasknotes.config").get(),
            metadata = { source = "create" },
          }
          hooks.run_callback("on_task_open", ctx)
          hooks.emit(hooks.events.TASK_OPEN, ctx)
        end
      end)
    end
  end)
end

-- Edit existing task
function M.edit_task(task)
  M.show_form(task, function(data)
    local success = task_manager.update_task(task.path, data)
    if success then
      vim.notify("Task updated", vim.log.levels.INFO)

      -- Refresh current buffer if it's the task file
      local current_buf = vim.api.nvim_get_current_buf()
      local current_file = vim.api.nvim_buf_get_name(current_buf)
      if current_file == task.path then
        vim.cmd("edit!")
      end
    end
  end)
end

-- Edit current buffer as task
function M.edit_current_buffer()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  M.edit_task(task)
end

return M
