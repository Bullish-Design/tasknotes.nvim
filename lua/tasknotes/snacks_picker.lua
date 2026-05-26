-- Snacks.nvim picker integration for tasknotes.nvim
local M = {}

local has_snacks, snacks = pcall(require, "snacks")
if not has_snacks then
  vim.notify("Snacks.nvim not found. Please install it for TaskNotes picker.", vim.log.levels.ERROR)
  return M
end

local task_manager = require("tasknotes.task_manager")
local config = require("tasknotes.config")
local bases = require("bases")

-- Helper function to safely convert values to strings (handles vim.NIL)
local function safe_string(value)
  if value == nil or value == vim.NIL then
    return ""
  end
  return tostring(value)
end

-- Format task for display in Snacks picker
local function format_task(task)
  local opts = config.get()

  -- Get status and priority info
  local status_info = config.get_status(task.status)
  local priority_info = config.get_priority(task.priority)

  -- Check if task is completed
  local is_completed = status_info.is_completed

  -- Determine dependency indicator
  local dep_indicator = " "
  local ok, is_blocked = pcall(task_manager.is_task_blocked, task)
  if ok and is_blocked then
    dep_indicator = "⛔"
  else
    local ok2, blocked_tasks = pcall(task_manager.get_blocked_tasks, task)
    if ok2 and blocked_tasks and #blocked_tasks > 0 then
      dep_indicator = "🔒"
    end
  end

  -- Format urgency score
  local urgency_str = string.format("%4.1f", task.urgency or 0)

  -- Format due date
  local due_str = safe_string(task.due)
  if #due_str > 10 then
    due_str = due_str:sub(1, 10)  -- Trim to date only
  end

  -- Format contexts
  local contexts_str = table.concat(task.contexts or {}, ", ")

  -- Build display line with fixed-width columns
  local line = string.format(
    "%s %s  %-35s %-12s %-10s %-12s %s",
    dep_indicator,
    urgency_str,
    safe_string(task.title):sub(1, 35),  -- Truncate long titles
    status_info.display,
    priority_info.display,
    due_str,
    contexts_str
  )

  return {
    text = line,
    -- Store task data for actions
    task = task,
    urgency = task.urgency or 0,
    -- Searchable text
    search = safe_string(task.title) .. " " .. safe_string(task.status) .. " " .. safe_string(task.due),
    -- File path for preview
    file = task.path,
    -- Metadata for highlighting
    is_completed = is_completed,
  }
end

-- Browse all tasks
function M.browse_tasks(opts)
  opts = opts or {}

  -- Ensure tasks are loaded before browsing
  if not task_manager.is_loaded then
    task_manager.scan_vault()
  end

  -- Get tasks (optionally filtered)
  local tasks = task_manager.get_tasks(opts.filter)

  if #tasks == 0 then
    vim.notify("No tasks found", vim.log.levels.WARN)
    return
  end

  -- Pre-sort tasks by urgency (descending)
  local urgency_module = require("tasknotes.urgency")
  tasks = urgency_module.sort_by_urgency(tasks)

  -- Format tasks for Snacks picker
  local items = {}
  for _, task in ipairs(tasks) do
    table.insert(items, format_task(task))
  end

  -- Determine prompt text
  local prompt_text = "TaskNotes"
  if opts.view_name then
    prompt_text = "TaskNotes [" .. opts.view_name .. "]"
  end

  -- Create Snacks picker
  snacks.picker.pick({
    prompt = prompt_text,
    items = items,

    -- Layout with preview support (telescope-style)
    layout = {
      preset = "telescope",
    },

    -- Format with proper highlighting
    format = function(item, picker)
      local ret = {}

      if item.is_completed then
        local hl_group = "TaskNotesCompletedTitle"
        -- Fallback if highlight group doesn't exist
        if vim.fn.hlexists(hl_group) == 0 then
          hl_group = "SnacksPickerComment"  -- Snacks' dimmed style
        end
        ret[#ret + 1] = { item.text, hl_group }
      else
        ret[#ret + 1] = { item.text, "SnacksPickerNormal" }
      end

      return ret
    end,

    -- Custom sort: urgency descending (Snacks handles fuzzy matching automatically)
    sort = function(a, b)
      -- Primary sort: urgency (higher urgency first)
      if a.urgency ~= b.urgency then
        return a.urgency > b.urgency
      end
      -- Secondary sort: alphabetical by title
      return (a.task.title or "") < (b.task.title or "")
    end,

    -- Preview configuration - use built-in file previewer
    preview = function(ctx)
      if ctx.item.file then
        return snacks.picker.preview.file(ctx)
      end
    end,

    -- Actions
    actions = {
      -- Default action: open file (Enter key)
      confirm = function(item)
        if item and item.file then
          vim.cmd("edit " .. item.file)
          local hooks = require("tasknotes.hooks")
          local task = require("tasknotes.task_manager").get_task_by_path(item.file)
          if task then
            local ctx = { operation = "open", task = task, path = item.file, opts = require("tasknotes.config").get(), metadata = {} }
            hooks.run_callback("on_task_open", ctx)
            hooks.emit(hooks.events.TASK_OPEN, ctx)
          end
        end
      end,

      -- Mark as done (Ctrl-d)
      ["<C-d>"] = function(item, picker)
        if not item or not item.task then return end

        -- Check if this task blocks other tasks
        local ok, blocked_tasks = pcall(task_manager.get_blocked_tasks, item.task)
        if ok and blocked_tasks and #blocked_tasks > 0 then
          local task_titles = {}
          for _, t in ipairs(blocked_tasks) do
            table.insert(task_titles, t.title)
          end
          vim.notify(
            string.format(
              "Warning: This task blocks %d other task(s): %s",
              #blocked_tasks,
              table.concat(task_titles, ", ")
            ),
            vim.log.levels.WARN
          )
        end

        -- Update task status
        task_manager.update_task(item.file, {
          status = "done",
          completedDate = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
        vim.notify("Marked task as done", vim.log.levels.INFO)

        -- Refresh picker
        vim.schedule(function()
          picker:close()
          M.browse_tasks(opts)
        end)
      end,

      -- Edit metadata (Ctrl-e)
      ["<C-e>"] = function(item, picker)
        if not item or not item.task then return end

        picker:close()
        local has_form, task_form = pcall(require, "tasknotes.ui.task_form")
        if has_form then
          task_form.edit_task(item.task)
        else
          vim.notify("Task form not available", vim.log.levels.ERROR)
        end
      end,

      -- Delete task (Ctrl-x)
      ["<C-x>"] = function(item, picker)
        if not item or not item.task then return end

        -- Confirm deletion
        vim.ui.select({ "Yes", "No" }, {
          prompt = "Delete task: " .. item.task.title .. "?",
        }, function(choice)
          if choice == "Yes" then
            task_manager.delete_task(item.file)
            vim.notify("Task deleted", vim.log.levels.INFO)

            -- Refresh picker
            vim.schedule(function()
              picker:close()
              M.browse_tasks(opts)
            end)
          end
        end)
      end,

      -- Toggle timer (Ctrl-t)
      ["<C-t>"] = function(item, picker)
        if not item or not item.task then return end

        local has_tracker, time_tracker = pcall(require, "tasknotes.ui.time_tracker")
        if has_tracker then
          time_tracker.toggle_timer(item.task)
        else
          vim.notify("Time tracker not available", vim.log.levels.ERROR)
        end
      end,

      -- View selector (Ctrl-v)
      ["<C-v>"] = function(item, picker)
        picker:close()
        vim.schedule(function()
          M.show_view_selector()
        end)
      end,
    },
  })
end

-- Filter by status
function M.browse_by_status(status)
  M.browse_tasks({ filter = { status = status } })
end

-- Filter by priority
function M.browse_by_priority(priority)
  M.browse_tasks({ filter = { priority = priority } })
end

-- Filter by context
function M.browse_by_context(context)
  M.browse_tasks({ filter = { context = context } })
end

-- Browse by view
function M.browse_by_view(view_id)
  vim.notify("DEBUG: browse_by_view called with: " .. view_id, vim.log.levels.INFO)

  local opts = config.get()
  local views_dir = vim.fn.expand(opts.vault_path) .. "/TaskNotes/Views"
  vim.notify("DEBUG: views_dir = " .. views_dir, vim.log.levels.INFO)

  local view, err = bases.get_view(view_id, views_dir, { view_type = "tasknotesTaskList" })
  if not view then
    vim.notify("View not found: " .. view_id .. (err and (" - " .. err) or ""), vim.log.levels.ERROR)
    return
  end

  vim.notify("DEBUG: View loaded: " .. view.name, vim.log.levels.INFO)

  -- Combine base filters and view-specific filters
  local combined_filters = nil
  if view.base_filters and view.view_filters then
    combined_filters = {
      ['and'] = {
        view.base_filters,
        view.view_filters,
      }
    }
  elseif view.base_filters then
    combined_filters = view.base_filters
  elseif view.view_filters then
    combined_filters = view.view_filters
  end

  vim.notify("DEBUG: Calling browse_tasks...", vim.log.levels.INFO)
  M.browse_tasks({
    filter = combined_filters and { bases_filters = combined_filters } or nil,
    view_name = view.name,
  })
end

-- Show view selector
function M.show_view_selector()
  local opts = config.get()
  local views_dir = vim.fn.expand(opts.vault_path) .. "/TaskNotes/Views"

  local all_views, err = bases.list_views(views_dir, { view_type = "tasknotesTaskList" })
  if err then
    vim.notify("Failed to load views: " .. err, vim.log.levels.ERROR)
    return
  end

  -- Convert views to picker items
  local items = {}
  for view_id, view in pairs(all_views) do
    table.insert(items, {
      text = string.format("%-30s [%s]", view.name, view.description or ""),
      view_id = view_id,
      search = view.name .. " " .. (view.description or ""),
    })
  end

  -- Sort items alphabetically by name
  table.sort(items, function(a, b)
    return a.text < b.text
  end)

  if #items == 0 then
    vim.notify("No Bases views found in " .. views_dir, vim.log.levels.WARN)
    return
  end

  snacks.picker.pick({
    prompt = "Select TaskNotes View",
    items = items,
    format = function(item)
      return { { item.text, "SnacksPickerNormal" } }
    end,
    preview = function(ctx)
      -- No preview for view selector items (they don't have files)
      return nil
    end,
    actions = {
      confirm = function(picker)
        -- Use picker:selected() to get the selected items (Snacks picker API)
        local items = picker:selected({ fallback = true })
        vim.notify("DEBUG: Selected items count: " .. #items, vim.log.levels.INFO)

        if #items > 0 then
          local item = items[1]
          vim.notify("DEBUG: First item: " .. vim.inspect({ view_id = item.view_id, text = item.text }), vim.log.levels.INFO)

          if item.view_id then
            vim.notify("DEBUG: Calling browse_by_view with: " .. item.view_id, vim.log.levels.INFO)
            picker:close()
            M.browse_by_view(item.view_id)
          else
            vim.notify("DEBUG: No view_id in selected item!", vim.log.levels.WARN)
          end
        else
          vim.notify("DEBUG: No items selected!", vim.log.levels.WARN)
        end
      end,
    },
  })
end

-- Setup function (no-op for Snacks, but kept for compatibility)
function M.setup()
  -- Snacks doesn't require explicit extension registration
  return true
end

return M
