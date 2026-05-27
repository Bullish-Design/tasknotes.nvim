local M = {}

local config = require("tasknotes.config")
local task_manager = require("tasknotes.task_manager")
local hooks = require("tasknotes.hooks")

local function open_task_file(filepath)
  vim.cmd("edit " .. filepath)
  local task = task_manager.get_task_by_path(filepath)
  if task then
    local ctx = { operation = "open", task = task, path = filepath, opts = config.get(), metadata = {} }
    hooks.run_callback("on_task_open", ctx)
    hooks.emit(hooks.events.TASK_OPEN, ctx)
  end
end

-- Check dependencies
local function check_dependencies(user_config)
  local errors = {}
  local warnings = {}

  -- Check for bases.nvim (REQUIRED)
  local has_bases, bases = pcall(require, "bases")
  if not has_bases then
    table.insert(errors, "bases.nvim not found - This is a required dependency!")
    table.insert(errors, "  Install: https://github.com/emiller/bases.nvim")
  else
    -- Validate bases.nvim has required API
    local required_api = {"get_view", "list_views", "evaluate", "query"}
    local missing_api = {}
    for _, func_name in ipairs(required_api) do
      if type(bases[func_name]) ~= "function" then
        table.insert(missing_api, func_name)
      end
    end
    if #missing_api > 0 then
      table.insert(errors, "bases.nvim found but missing required API functions:")
      for _, func_name in ipairs(missing_api) do
        table.insert(errors, "  - bases." .. func_name .. "()")
      end
      table.insert(errors, "  Please update bases.nvim to the latest version")
    end
  end

  local defaults = require("tasknotes.config").defaults or {}
  local preview = vim.tbl_deep_extend("force", defaults, user_config or {})

  -- snacks.nvim (optional warning)
  local has_snacks = pcall(require, "snacks")
  if not has_snacks then
    table.insert(warnings, "snacks.nvim not found - task picker will be unavailable")
  end

  local form_backend = preview.ui and preview.ui.form_backend or "input-form"
  local fallback_to_nui = preview.ui and preview.ui.fallback_to_nui

  if form_backend == "input-form" then
    local has_input_form = pcall(require, "input-form")
    if not has_input_form then
      local has_nui = pcall(require, "nui.popup")
      if fallback_to_nui ~= false and has_nui then
        table.insert(warnings, "input-form.nvim not found - falling back to NUI form")
      elseif fallback_to_nui == false then
        table.insert(warnings, "input-form.nvim not found and NUI fallback disabled - task form unavailable")
      else
        table.insert(warnings, "input-form.nvim not found - install it or nui.nvim for task forms")
      end
    end
  elseif form_backend == "nui" then
    local has_nui = pcall(require, "nui.popup")
    if not has_nui then
      table.insert(warnings, "nui.nvim not found - task form will be unavailable")
    end
  end

  local dp = preview.ui and preview.ui.date_picker
  if dp and dp.enabled ~= false and dp.backend == "datepicker.nvim" then
    local has_datepicker = pcall(require, "datepicker")
    if not has_datepicker then
      table.insert(warnings, "datepicker.nvim not found - date fields will use text input fallback")
    end
  end

  return errors, warnings
end

-- Setup highlight groups for completed tasks
local function setup_highlights()
  -- Create dimmed/greyed out highlight group for completed tasks
  vim.api.nvim_set_hl(0, "TaskNotesCompletedTitle", {
    fg = "#6c6c6c",        -- Dim gray color that works on both light/dark backgrounds
    strikethrough = true,  -- Clear visual indication that task is done
    italic = true,         -- Additional subtle cue
  })
end

-- Setup function
function M.setup(user_config)
  user_config = user_config or {}

  -- Check dependencies FIRST
  local errors, warnings = check_dependencies(user_config)

  -- Fail hard if critical dependencies are missing
  if #errors > 0 then
    vim.notify("TaskNotes:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    return
  end

  -- Show warnings for optional dependencies
  for _, warning in ipairs(warnings) do
    vim.notify("TaskNotes: " .. warning, vim.log.levels.WARN)
  end

  -- Import from Obsidian if enabled
  if user_config.obsidian and user_config.obsidian.enabled then
    local importer = require("tasknotes.obsidian_importer")
    local imported_config, err = importer.import_from_obsidian(user_config.obsidian.vault_path)

    if imported_config then
      -- Merge imported config with user config (user config takes precedence)
      user_config = vim.tbl_deep_extend("force", imported_config, user_config)
      vim.notify("Imported settings from Obsidian TaskNotes", vim.log.levels.INFO)
    else
      vim.notify("Could not import Obsidian settings: " .. (err or "unknown error"), vim.log.levels.WARN)
    end
  end

  -- Setup configuration
  config.setup(user_config)

  -- Setup highlight groups
  setup_highlights()

  local opts = config.get()

  -- Initial vault scan
  task_manager.scan_vault()

  -- Setup keymaps if configured
  if opts.keymaps.browse then
    vim.keymap.set("n", opts.keymaps.browse, function()
      M.browse_tasks()
    end, { desc = "Browse TaskNotes" })
  end

  if opts.keymaps.new_task then
    vim.keymap.set("n", opts.keymaps.new_task, function()
      M.new_task()
    end, { desc = "Create new TaskNote" })
  end

  if opts.keymaps.edit_task then
    vim.keymap.set("n", opts.keymaps.edit_task, function()
      M.edit_task()
    end, { desc = "Edit current TaskNote" })
  end

  if opts.keymaps.toggle_timer then
    vim.keymap.set("n", opts.keymaps.toggle_timer, function()
      M.toggle_timer()
    end, { desc = "Toggle TaskNote timer" })
  end

  if opts.keymaps.view_selector then
    vim.keymap.set("n", opts.keymaps.view_selector, function()
      M.show_view_selector()
    end, { desc = "Open TaskNotes view selector" })
  end

  -- Auto-save timer state periodically
  if opts.time_tracking.enabled then
    local timer = vim.loop.new_timer()
    timer:start(
      opts.time_tracking.auto_save_interval * 1000,
      opts.time_tracking.auto_save_interval * 1000,
      vim.schedule_wrap(function()
        local time_tracker = require("tasknotes.ui.time_tracker")
        if time_tracker.active_timer then
          -- Update in-memory task data
          task_manager.refresh_task(time_tracker.active_timer.task.path)
        end
      end)
    )
  end

  hooks.run_callback("after_setup", { operation = "setup", opts = opts, metadata = {} })
  hooks.emit(hooks.events.SETUP_POST, { operation = "setup", opts = opts, metadata = {} })
  vim.notify("TaskNotes loaded", vim.log.levels.INFO)
end

-- Browse tasks
function M.browse_tasks(filter)
  local has_snacks = pcall(require, "snacks")
  if has_snacks then
    local picker = require("tasknotes.snacks_picker")
    picker.browse_tasks({ filter = filter })
  else
    vim.notify("Snacks.nvim not available", vim.log.levels.ERROR)
  end
end

-- Browse tasks by view
function M.browse_by_view(view_name)
  local has_snacks = pcall(require, "snacks")
  if has_snacks then
    local picker = require("tasknotes.snacks_picker")
    picker.browse_by_view(view_name)
  else
    vim.notify("Snacks.nvim not available", vim.log.levels.ERROR)
  end
end

-- Show view selector
function M.show_view_selector()
  local has_snacks = pcall(require, "snacks")
  if has_snacks then
    local picker = require("tasknotes.snacks_picker")
    picker.show_view_selector()
  else
    vim.notify("Snacks.nvim not available", vim.log.levels.ERROR)
  end
end

-- List all views (shows picker)
function M.list_views()
  M.show_view_selector()
end

-- Create new task
function M.new_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.new_task()
end

-- Edit current buffer task
function M.edit_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.edit_current_buffer()
end

-- Toggle timer for current task
function M.toggle_timer()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  local has_nui = pcall(require, "nui.popup")
  if has_nui then
    local time_tracker = require("tasknotes.ui.time_tracker")
    time_tracker.toggle_timer(task)
  else
    vim.notify("NUI not available - cannot use time tracker", vim.log.levels.ERROR)
  end
end

-- Show timer status
function M.timer_status()
  local has_nui = pcall(require, "nui.popup")
  if has_nui then
    local time_tracker = require("tasknotes.ui.time_tracker")
    time_tracker.show_status()
  else
    vim.notify("NUI not available", vim.log.levels.ERROR)
  end
end

-- View time entries for current task
function M.view_time_entries()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  local has_nui = pcall(require, "nui.popup")
  if has_nui then
    local time_tracker = require("tasknotes.ui.time_tracker")
    time_tracker.view_time_entries(task)
  else
    vim.notify("NUI not available", vim.log.levels.ERROR)
  end
end

-- Rescan vault
function M.rescan()
  task_manager.scan_vault()
end

-- Clear cache and force fresh vault scan
function M.clear_cache()
  task_manager.clear_cache()
end

-- Get statusline component
function M.statusline()
  local time_tracker = require("tasknotes.ui.time_tracker")
  local status = time_tracker.get_status()

  if status then
    return string.format(" %s (%s)", status.task, status.duration)
  end

  return ""
end

-- Import settings from Obsidian TaskNotes plugin
function M.import_obsidian_settings(obsidian_vault_path)
  local importer = require("tasknotes.obsidian_importer")

  local nvim_config, err = importer.import_from_obsidian(obsidian_vault_path)
  if not nvim_config then
    vim.notify("Failed to import Obsidian settings: " .. err, vim.log.levels.ERROR)
    return nil
  end

  -- Apply imported config
  config.setup(nvim_config)

  -- Rescan vault with new settings
  task_manager.scan_vault()

  vim.notify("Successfully imported settings from Obsidian", vim.log.levels.INFO)
  return nvim_config
end

-- Show dependencies for current task
function M.show_dependencies()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  local blocking_tasks = task_manager.get_blocking_tasks(task)
  local blocked_tasks = task_manager.get_blocked_tasks(task)

  local lines = {}
  table.insert(lines, "Dependencies for: " .. task.title)
  table.insert(lines, "")

  if #blocking_tasks > 0 then
    table.insert(lines, "Blocked by:")
    for _, t in ipairs(blocking_tasks) do
      local status = config.get_status(t.status)
      local status_str = status.is_completed and "[✓]" or "[ ]"
      table.insert(lines, string.format("  %s %s (%s)", status_str, t.title, t.path))
    end
  else
    table.insert(lines, "Not blocked by any tasks")
  end

  table.insert(lines, "")

  if #blocked_tasks > 0 then
    table.insert(lines, "Blocking:")
    for _, t in ipairs(blocked_tasks) do
      table.insert(lines, string.format("  - %s (%s)", t.title, t.path))
    end
  else
    table.insert(lines, "Not blocking any tasks")
  end

  -- Create a new buffer to display dependencies
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_name(bufnr, "Task Dependencies")
end

-- Navigate to blocking tasks
function M.goto_blocking_tasks()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  local blocking_tasks = task_manager.get_blocking_tasks(task)

  if #blocking_tasks == 0 then
    vim.notify("No blocking tasks", vim.log.levels.INFO)
    return
  end

  if #blocking_tasks == 1 then
    open_task_file(blocking_tasks[1].path)
    return
  end

  -- Multiple blocking tasks - show selector
  local task_labels = {}
  for _, t in ipairs(blocking_tasks) do
    table.insert(task_labels, t.title)
  end

  vim.ui.select(task_labels, {
    prompt = "Select blocking task:",
  }, function(choice, idx)
    if idx then
      open_task_file(blocking_tasks[idx].path)
    end
  end)
end

-- Navigate to blocked tasks
function M.goto_blocked_tasks()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  local blocked_tasks = task_manager.get_blocked_tasks(task)

  if #blocked_tasks == 0 then
    vim.notify("No blocked tasks", vim.log.levels.INFO)
    return
  end

  if #blocked_tasks == 1 then
    open_task_file(blocked_tasks[1].path)
    return
  end

  -- Multiple blocked tasks - show selector
  local task_labels = {}
  for _, t in ipairs(blocked_tasks) do
    table.insert(task_labels, t.title)
  end

  vim.ui.select(task_labels, {
    prompt = "Select blocked task:",
  }, function(choice, idx)
    if idx then
      open_task_file(blocked_tasks[idx].path)
    end
  end)
end

-- Export public API
M.task_manager = task_manager
M.config = config

function M.create_task_programmatic(task_data) return task_manager.create_task(task_data) end
function M.update_task(ref, updates, update_opts)
  local task = task_manager.resolve_task(ref)
  if not task then vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR); return false end
  return task_manager.update_task(task.path, updates, update_opts)
end
function M.delete_task(ref)
  local task = task_manager.resolve_task(ref)
  if not task then vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR); return false end
  return task_manager.delete_task(task.path)
end
function M.get_task(ref) return task_manager.resolve_task(ref) end
function M.get_task_by_id(id) return task_manager.get_task_by_id(id) end
function M.get_task_by_path(path) return task_manager.get_task_by_path(path) end
function M.get_all_tasks(filter) return task_manager.get_tasks(filter) end

return M
