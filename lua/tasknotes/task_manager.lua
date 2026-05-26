local M = {}

local config = require("tasknotes.config")
local parser = require("tasknotes.parser")
local cache_module = require("tasknotes.cache")
local bases = require("bases")

-- Task cache
M.tasks = {}
M.tasks_by_path = {}
M.tasks_by_id = {}
M.is_loaded = false -- Track if initial scan completed

-- Helper to handle vim.NIL from YAML parser
local function normalize_value(value, default)
  if value == nil or value == vim.NIL then
    return default
  end
  return value
end

-- Get cache file path and ensure directory exists
local function get_cache_path()
  local opts = config.get()
  local cache_dir = vim.fn.expand(opts.cache.cache_dir)

  -- Ensure cache directory exists
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end

  return cache_dir .. "/" .. opts.cache.filename
end

-- Check if a file is a task file based on identification method
local function is_task_file(frontmatter)
  local opts = config.get()

  if opts.task_identification_method == "property" then
    -- Check if specific property matches value
    local prop_value = frontmatter[opts.task_property_name]
    return prop_value == opts.task_property_value
  else
    -- Check if tags array contains task tag
    if not frontmatter.tags then
      return false
    end

    local tags = frontmatter.tags
    if type(tags) == "string" then
      tags = { tags }
    end

    for _, tag in ipairs(tags) do
      if tag == opts.task_tag or tag:match("^" .. opts.task_tag .. "/") then
        return true
      end
    end
  end

  return false
end

-- Build find command with directory ignore patterns
local function build_find_command(vault_path, ignore_dirs)
  local cmd = string.format("find '%s'", vault_path)

  -- Add -prune for each ignored directory
  for _, dir in ipairs(ignore_dirs) do
    -- Escape single quotes in directory names
    local escaped_dir = dir:gsub("'", "'\\''")
    cmd = cmd .. string.format(" -type d -name '%s' -prune -o", escaped_dir)
  end

  -- Add final file match and print
  cmd = cmd .. " -type f -name '*.md' -print"

  return cmd
end

-- Scan vault and discover all task files
function M.scan_vault(force_validate)
  local opts = config.get()
  local vault_path = opts.vault_path

  if vim.fn.isdirectory(vault_path) == 0 then
    vim.notify("TaskNotes vault not found: " .. vault_path, vim.log.levels.ERROR)
    return
  end

  M.tasks = {}
  M.tasks_by_path = {}
  M.tasks_by_id = {}

  -- Try to load cache if enabled
  local cache_path = get_cache_path()
  local persistent_cache = nil

  if opts.cache.enabled then
    persistent_cache = cache_module.load(cache_path)

    -- Validate vault path if cache was loaded successfully
    if persistent_cache then
      local valid, message = cache_module.validate_vault_path(persistent_cache, vault_path)
      if not valid then
        vim.notify(
          string.format("Cache invalidated: %s. Rebuilding cache...", message),
          vim.log.levels.WARN
        )
        persistent_cache = nil -- Invalidate cache to trigger full scan
      end
    end
  end

  -- Fast path: trust cache without validation
  if persistent_cache and not force_validate and not opts.cache.validate_on_startup then
    -- Load all tasks from cache without any validation
    for filepath, cached_entry in pairs(persistent_cache.tasks) do
      local task = cached_entry.task
      if task then
        -- Normalize blockedBy field to handle vim.NIL from JSON deserialization
        task.blockedBy = normalize_value(task.blockedBy, {})
        if type(task.blockedBy) == "string" then
          task.blockedBy = { task.blockedBy }
        end

        table.insert(M.tasks, task)
        M.tasks_by_path[filepath] = task
        if task.id then
          M.tasks_by_id[task.id] = task
        end
      end
    end

    -- Recalculate urgency for all cached tasks with current coefficients
    if opts.urgency and opts.urgency.enabled then
      local urgency = require("tasknotes.urgency")
      for _, task in ipairs(M.tasks) do
        task.urgency = urgency.calculate_urgency(task, opts, nil, false)
        M.tasks_by_path[task.path] = task
        if task.id then
          M.tasks_by_id[task.id] = task
        end
      end
    end

    vim.notify(
      string.format("Loaded %d tasks from cache (instant mode)", #M.tasks),
      vim.log.levels.INFO
    )

    -- Schedule background validation if needed
    if cache_module.needs_validation(persistent_cache, opts.cache.validation_interval) then
      vim.defer_fn(function()
        M.validate_cache_async()
      end, opts.cache.background_validation_delay)
    end

    M.is_loaded = true
    return
  end

  -- Slow path: full validation or no cache
  local files = {}
  if force_validate or not persistent_cache or not persistent_cache.file_list then
    -- Need to run find command
    local ignore_dirs = config.get_ignore_dirs()
    local find_cmd = build_find_command(vault_path, ignore_dirs)
    files = vim.fn.systemlist(find_cmd)
  else
    -- Use cached file list
    files = persistent_cache.file_list or {}
  end

  -- Create a set of all current files for quick lookup
  local current_files = {}
  for _, filepath in ipairs(files) do
    current_files[filepath] = true
  end

  if not persistent_cache then
    persistent_cache = cache_module.new(vault_path)
  end

  local files_parsed = 0
  local files_from_cache = 0

  -- Process all files
  for _, filepath in ipairs(files) do
    local cached_entry = persistent_cache.tasks[filepath]
    local current_mtime = cache_module.get_mtime(filepath)

    -- Check if we can use cached data
    if cached_entry and cached_entry.mtime == current_mtime then
      -- File hasn't changed, use cached task object
      local task = cached_entry.task
      if task then
        -- Normalize blockedBy field to handle vim.NIL from JSON deserialization
        task.blockedBy = normalize_value(task.blockedBy, {})
        if type(task.blockedBy) == "string" then
          task.blockedBy = { task.blockedBy }
        end

        table.insert(M.tasks, task)
        M.tasks_by_path[filepath] = task
        if task.id then
          M.tasks_by_id[task.id] = task
        end
        files_from_cache = files_from_cache + 1
      end
    else
      -- File is new or changed, parse it
      local parsed = parser.parse_file(filepath)
      if parsed and parsed.frontmatter then
        if is_task_file(parsed.frontmatter) then
          local task = M.create_task_object(filepath, parsed.frontmatter, parsed.body)
          table.insert(M.tasks, task)
          M.tasks_by_path[filepath] = task
          if task.id then
            M.tasks_by_id[task.id] = task
          end

          -- Update cache
          persistent_cache.tasks[filepath] = {
            mtime = current_mtime,
            task = task,
          }
          files_parsed = files_parsed + 1
        else
          -- Not a task file, remove from cache if present
          persistent_cache.tasks[filepath] = nil
        end
      else
        -- Failed to parse, remove from cache if present
        persistent_cache.tasks[filepath] = nil
      end
    end
  end

  -- Remove deleted files from cache
  for cached_filepath, _ in pairs(persistent_cache.tasks) do
    if not current_files[cached_filepath] then
      persistent_cache.tasks[cached_filepath] = nil
    end
  end

  -- Update cache metadata
  persistent_cache.file_list = files
  persistent_cache.last_validated = os.time()

  -- Save updated cache
  if opts.cache.enabled then
    local success, err = cache_module.save(cache_path, persistent_cache, vault_path)
    if not success then
      vim.notify("Failed to save cache: " .. (err or "unknown error"), vim.log.levels.WARN)
    end
  end

  if files_from_cache > 0 then
    vim.notify(
      string.format("Found %d tasks (%d from cache, %d parsed)", #M.tasks, files_from_cache, files_parsed),
      vim.log.levels.INFO
    )
  else
    vim.notify(string.format("Found %d tasks", #M.tasks), vim.log.levels.INFO)
  end

  -- Recalculate urgency for all tasks with dependency factors
  -- Now that all tasks are loaded, dependency checks will work correctly
  if opts.urgency and opts.urgency.enabled then
    local urgency = require("tasknotes.urgency")
    for _, task in ipairs(M.tasks) do
      -- Recalculate with dependencies (skip_dependencies = false)
      task.urgency = urgency.calculate_urgency(task, opts, nil, false)
      -- Update in tasks_by_path as well
      M.tasks_by_path[task.path] = task
      if task.id then
        M.tasks_by_id[task.id] = task
      end
    end
  end

  M.is_loaded = true
end

-- Create a task object from frontmatter
function M.create_task_object(filepath, frontmatter, body)
  local opts = config.get()
  local fm = opts.field_mapping

  -- Extract mapped fields with proper vim.NIL handling
  local task = {
    path = filepath,
    id = normalize_value(frontmatter[fm.id], nil),
    title = normalize_value(frontmatter[fm.title], ""),
    status = normalize_value(frontmatter[fm.status], "open"),
    priority = normalize_value(frontmatter[fm.priority], "none"),
    due = normalize_value(frontmatter[fm.due], nil),
    scheduled = normalize_value(frontmatter[fm.scheduled], nil),
    contexts = normalize_value(frontmatter[fm.contexts], {}),
    projects = normalize_value(frontmatter[fm.projects], {}),
    tags = normalize_value(frontmatter[fm.tags], {}),
    timeEstimate = normalize_value(frontmatter[fm.timeEstimate], nil),
    timeEntries = normalize_value(frontmatter[fm.timeEntries], {}),
    completedDate = normalize_value(frontmatter[fm.completedDate], nil),
    dateCreated = normalize_value(frontmatter[fm.dateCreated], nil),
    dateModified = normalize_value(frontmatter[fm.dateModified], nil),
    blockedBy = normalize_value(frontmatter[fm.blockedBy], {}),
    body = body or "",
  }

  -- Ensure arrays are arrays
  if type(task.contexts) == "string" then
    task.contexts = { task.contexts }
  end
  if type(task.projects) == "string" then
    task.projects = { task.projects }
  end
  if type(task.tags) == "string" then
    task.tags = { task.tags }
  end
  if type(task.blockedBy) == "string" then
    task.blockedBy = { task.blockedBy }
  end

  -- Calculate total tracked time
  task.totalTrackedTime = M.calculate_total_time(task.timeEntries)

  -- Calculate urgency score (skip dependencies during initial load)
  local urgency_config = config.get()
  if urgency_config.urgency and urgency_config.urgency.enabled then
    local urgency = require("tasknotes.urgency")
    -- Skip dependency calculations during task creation to avoid circular dependency
    -- Urgency will be recalculated with dependencies after all tasks are loaded
    task.urgency = urgency.calculate_urgency(task, urgency_config, nil, true)
  else
    task.urgency = 0
  end

  return task
end

-- Calculate total tracked time from time entries
function M.calculate_total_time(time_entries)
  if not time_entries or #time_entries == 0 then
    return 0
  end

  local total = 0
  for _, entry in ipairs(time_entries) do
    if entry.duration then
      total = total + entry.duration
    elseif entry.startTime and entry.endTime then
      -- Parse ISO timestamps and calculate duration
      local start_time = M.parse_iso_timestamp(entry.startTime)
      local end_time = M.parse_iso_timestamp(entry.endTime)
      if start_time and end_time then
        total = total + math.floor((end_time - start_time) / 60)
      end
    end
  end

  return total
end

-- Parse ISO 8601 timestamp to Unix time
function M.parse_iso_timestamp(iso_str)
  -- Basic ISO parser (handles YYYY-MM-DDTHH:MM:SSZ format)
  local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
  local year, month, day, hour, min, sec = iso_str:match(pattern)

  if year then
    return os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(min),
      sec = tonumber(sec),
    })
  end

  return nil
end

-- Get all tasks (optionally filtered)
function M.get_tasks(filter)
  local opts = config.get()
  local hide_completed = opts.picker and opts.picker.hide_completed

  local filtered = {}
  for _, task in ipairs(M.tasks) do
    local matches = true

    -- Filter out completed tasks if hide_completed is enabled
    -- BUT: Don't filter if user explicitly requested a completed status
    local status_is_completed_filter = false
    if filter and filter.status then
      local status_def = config.get_status(filter.status)
      if status_def.is_completed then
        status_is_completed_filter = true
      end
    end

    if hide_completed and not status_is_completed_filter then
      local status_def = config.get_status(task.status)
      if status_def.is_completed then
        matches = false
      end
    end

    -- Filter out archived tasks
    if task.archived == true then
      matches = false
    end

    -- Apply additional filters if provided
    if filter then
      -- Bases filter expressions (from .base files)
      if filter.bases_filters then
        if not bases.evaluate(filter.bases_filters, task) then
          matches = false
        end
      end

      if filter.status and task.status ~= filter.status then
        matches = false
      end

      if filter.priority and task.priority ~= filter.priority then
        matches = false
      end

      if filter.context then
        local has_context = false
        for _, ctx in ipairs(task.contexts) do
          if ctx == filter.context then
            has_context = true
            break
          end
        end
        if not has_context then
          matches = false
        end
      end

      if filter.project then
        local has_project = false
        for _, proj in ipairs(task.projects) do
          if proj:match(filter.project) then
            has_project = true
            break
          end
        end
        if not has_project then
          matches = false
        end
      end
    end

    if matches then
      table.insert(filtered, task)
    end
  end

  return filtered
end

function M.generate_task_id(title)
  local slug = (title or "task")
    :lower()
    :gsub("%s+", "-")
    :gsub("[^%w%-]", "")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")

  if #slug > 40 then
    slug = slug:sub(1, 40):gsub("%-$", "")
  end

  return "task-" .. os.date("!%Y%m%d%H%M%S") .. "-" .. slug
end

-- Get task by filepath
function M.get_task_by_path(filepath)
  return M.tasks_by_path[filepath]
end

function M.get_task_by_id(id)
  return M.tasks_by_id[id]
end

function M.resolve_task(ref)
  if not ref then
    return nil
  end

  if M.tasks_by_path[ref] then
    return M.tasks_by_path[ref]
  end

  if M.tasks_by_id[ref] then
    return M.tasks_by_id[ref]
  end

  return nil
end

-- Create a new task
function M.create_task(task_data)
  local opts = config.get()
  local fm = opts.field_mapping

  -- Generate filename from title
  local filename = task_data.title:gsub("%s+", "-"):gsub("[^%w%-]", ""):lower() .. ".md"
  local filepath = opts.vault_path .. "/" .. filename

  -- Check if file already exists
  if vim.fn.filereadable(filepath) == 1 then
    vim.notify("Task file already exists: " .. filename, vim.log.levels.ERROR)
    return nil
  end

  -- Build frontmatter
  local frontmatter = {}
  frontmatter[fm.title] = task_data.title
  frontmatter[fm.status] = task_data.status or "open"
  frontmatter[fm.priority] = task_data.priority or "none"
  frontmatter[fm.due] = task_data.due
  frontmatter[fm.scheduled] = task_data.scheduled
  frontmatter[fm.contexts] = task_data.contexts or {}
  frontmatter[fm.projects] = task_data.projects or {}
  frontmatter[fm.tags] = task_data.tags or { opts.task_tag }
  frontmatter[fm.timeEstimate] = task_data.timeEstimate
  frontmatter[fm.blockedBy] = task_data.blockedBy or {}
  frontmatter[fm.dateCreated] = os.date("!%Y-%m-%dT%H:%M:%SZ")
  frontmatter[fm.dateModified] = frontmatter[fm.dateCreated]

  -- Validate dependencies if provided
  if task_data.blockedBy and #task_data.blockedBy > 0 then
    -- Create temporary task object for validation
    local temp_task = { path = filepath, blockedBy = task_data.blockedBy }
    local valid, err = M.validate_dependencies(temp_task)
    if not valid then
      vim.notify("Invalid dependencies: " .. err, vim.log.levels.ERROR)
      return nil
    end
  end

  -- Write file
  local success, err = parser.write_file(filepath, frontmatter, task_data.body or "")
  if not success then
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end

  -- Add to cache
  local task = M.create_task_object(filepath, frontmatter, task_data.body)
              table.insert(M.tasks, task)
              M.tasks_by_path[filepath] = task
              if task.id then
                M.tasks_by_id[task.id] = task
              end

  vim.notify("Created task: " .. filename, vim.log.levels.INFO)
  return task
end

-- Helper function to update cache file
local function update_cache_file(filepath, task)
  local opts = config.get()
  if not opts.cache.enabled then
    return
  end

  local vault_path = opts.vault_path
  local cache_path = get_cache_path()

  -- Load existing cache
  local persistent_cache = cache_module.load(cache_path)
  if not persistent_cache then
    persistent_cache = cache_module.new(vault_path)
  end

  -- Update cache entry
  if task then
    local mtime = cache_module.get_mtime(filepath)
    persistent_cache.tasks[filepath] = {
      mtime = mtime,
      task = task,
    }
  else
    -- Remove from cache
    persistent_cache.tasks[filepath] = nil
  end

  -- Save cache
  cache_module.save(cache_path, persistent_cache, vault_path)
end

-- Update an existing task
function M.update_task(filepath, updates)
  local parsed = parser.parse_file(filepath)
  if not parsed then
    vim.notify("Could not read task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  local opts = config.get()
  local fm = opts.field_mapping

  -- Validate dependencies if being updated
  if updates.blockedBy then
    local temp_task = { path = filepath, blockedBy = updates.blockedBy }
    local valid, err = M.validate_dependencies(temp_task)
    if not valid then
      vim.notify("Invalid dependencies: " .. err, vim.log.levels.ERROR)
      return false
    end
  end

  -- Update frontmatter fields
  for key, value in pairs(updates) do
    local fm_key = fm[key] or key
    parsed.frontmatter[fm_key] = value
  end

  -- Update modification date
  parsed.frontmatter[fm.dateModified] = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Write back to file
  local success, err = parser.write_file(filepath, parsed.frontmatter, parsed.body)
  if not success then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  -- Update in-memory cache
  local task = M.create_task_object(filepath, parsed.frontmatter, parsed.body)
  M.tasks_by_path[filepath] = task

  -- Update in tasks array
  for i, t in ipairs(M.tasks) do
    if t.path == filepath then
      M.tasks[i] = task
      break
    end
  end

  -- Update persistent cache
  update_cache_file(filepath, task)

  return true
end

-- Delete a task
function M.delete_task(filepath)
  -- Remove file
  local success = os.remove(filepath)
  if not success then
    vim.notify("Could not delete task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  -- Remove from in-memory cache
  M.tasks_by_path[filepath] = nil
  for i, task in ipairs(M.tasks) do
    if task.path == filepath then
      table.remove(M.tasks, i)
      break
    end
  end

  -- Remove from persistent cache
  update_cache_file(filepath, nil)

  vim.notify("Deleted task", vim.log.levels.INFO)
  return true
end

-- Refresh a single task from disk
function M.refresh_task(filepath)
  local parsed = parser.parse_file(filepath)
  if not parsed or not parsed.frontmatter then
    return false
  end

  if not is_task_file(parsed.frontmatter) then
    return false
  end

  local task = M.create_task_object(filepath, parsed.frontmatter, parsed.body)
  M.tasks_by_path[filepath] = task

  -- Update in tasks array
  local found = false
  for i, t in ipairs(M.tasks) do
    if t.path == filepath then
      M.tasks[i] = task
      found = true
      break
    end
  end

  if not found then
    table.insert(M.tasks, task)
  end

  -- Update cache
  update_cache_file(filepath, task)

  return true
end

-- Validate cache in background (async)
function M.validate_cache_async()
  local opts = config.get()
  local vault_path = opts.vault_path

  -- Run find command asynchronously
  local ignore_dirs = config.get_ignore_dirs()
  local find_cmd = build_find_command(vault_path, ignore_dirs)
  vim.fn.jobstart(find_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data, _)
      if not data then
        return
      end

      -- Filter out empty strings
      local files = vim.tbl_filter(function(line)
        return line ~= ""
      end, data)

      -- Process the file list in the background
      vim.schedule(function()
        local cache_path = get_cache_path()
        local persistent_cache = cache_module.load(cache_path)

        if not persistent_cache then
          -- No cache to validate, trigger full scan
          M.scan_vault(true)
          return
        end

        -- Create a set of current files
        local current_files = {}
        for _, filepath in ipairs(files) do
          current_files[filepath] = true
        end

        local updates_needed = false

        -- Check for new or changed files
        for _, filepath in ipairs(files) do
          local cached_entry = persistent_cache.tasks[filepath]
          local current_mtime = cache_module.get_mtime(filepath)

          if not cached_entry or cached_entry.mtime ~= current_mtime then
            -- File is new or changed, need to update
            local parsed = parser.parse_file(filepath)
            if parsed and parsed.frontmatter and is_task_file(parsed.frontmatter) then
              local task = M.create_task_object(filepath, parsed.frontmatter, parsed.body)

              -- Update in-memory cache
              M.tasks_by_path[filepath] = task
              local found = false
              for i, t in ipairs(M.tasks) do
                if t.path == filepath then
                  M.tasks[i] = task
                  found = true
                  break
                end
              end
              if not found then
                table.insert(M.tasks, task)
              end

              -- Update persistent cache
              persistent_cache.tasks[filepath] = {
                mtime = current_mtime,
                task = task,
              }
              updates_needed = true
            end
          end
        end

        -- Check for deleted files
        for cached_filepath, _ in pairs(persistent_cache.tasks) do
          if not current_files[cached_filepath] then
            persistent_cache.tasks[cached_filepath] = nil

            -- Remove from in-memory cache
            M.tasks_by_path[cached_filepath] = nil
            for i, t in ipairs(M.tasks) do
              if t.path == cached_filepath then
                table.remove(M.tasks, i)
                break
              end
            end

            updates_needed = true
          end
        end

        -- Update cache metadata
        persistent_cache.file_list = files
        persistent_cache.last_validated = os.time()

        -- Save cache
        if updates_needed or cache_module.needs_validation(persistent_cache, opts.cache.validation_interval) then
          cache_module.save(cache_path, persistent_cache, vault_path)
          if updates_needed then
            vim.notify("Task cache updated in background", vim.log.levels.INFO)
          end
        end

        -- Recalculate urgency for all tasks with dependency factors
        -- This runs in the background after cache validation is complete
        if opts.urgency and opts.urgency.enabled then
          local urgency = require("tasknotes.urgency")
          for _, task in ipairs(M.tasks) do
            -- Recalculate with dependencies (skip_dependencies = false)
            task.urgency = urgency.calculate_urgency(task, opts, nil, false)
            -- Update in tasks_by_path as well
            M.tasks_by_path[task.path] = task
          end
        end
      end)
    end,
    on_stderr = function(_, data, _)
      if data and #data > 0 and data[1] ~= "" then
        vim.schedule(function()
          vim.notify("Background cache validation error: " .. table.concat(data, "\n"), vim.log.levels.WARN)
        end)
      end
    end,
  })
end

-- Get tasks that block the given task
-- Returns array of task objects
function M.get_blocking_tasks(task)
  -- Normalize blockedBy to handle vim.NIL from cache
  local blockedBy = normalize_value(task.blockedBy, {})

  if type(blockedBy) ~= "table" or #blockedBy == 0 then
    return {}
  end

  local blocking_tasks = {}
  for _, blocking_path in ipairs(blockedBy) do
    -- blockedBy can contain file paths or task IDs
    -- For now, assume they are file paths
    local blocking_task = M.tasks_by_path[blocking_path]
    if blocking_task then
      table.insert(blocking_tasks, blocking_task)
    else
      -- Try to find by matching filename
      for _, t in ipairs(M.tasks) do
        -- Safely match patterns
        local path_match = pcall(function()
          return t.path:match(blocking_path .. "$") or t.path:match("/" .. blocking_path .. "$")
        end)
        if path_match then
          table.insert(blocking_tasks, t)
          break
        end
      end
    end
  end

  return blocking_tasks
end

-- Get tasks that are blocked by the given task
-- Returns array of task objects
function M.get_blocked_tasks(task)
  local blocked_tasks = {}

  for _, t in ipairs(M.tasks) do
    -- Normalize blockedBy to handle vim.NIL from cache
    local blockedBy = normalize_value(t.blockedBy, {})

    if type(blockedBy) == "table" and #blockedBy > 0 then
      for _, blocking_path in ipairs(blockedBy) do
        -- Check if this task's path matches any of the blockedBy entries
        -- Safely match patterns
        local matches = false
        pcall(function()
          matches = blocking_path == task.path or
                    task.path:match(blocking_path .. "$") or
                    task.path:match("/" .. blocking_path .. "$")
        end)

        if matches then
          table.insert(blocked_tasks, t)
          break
        end
      end
    end
  end

  return blocked_tasks
end

-- Check if a task is blocked (any blocking tasks are not completed)
function M.is_task_blocked(task)
  local blocking_tasks = M.get_blocking_tasks(task)

  for _, blocking_task in ipairs(blocking_tasks) do
    local status_def = config.get_status(blocking_task.status)
    if not status_def.is_completed then
      return true
    end
  end

  return false
end

-- Validate dependencies for circular references
-- Returns true if valid, false + error message if circular dependency detected
function M.validate_dependencies(task, new_dependencies)
  local dependencies = new_dependencies or task.blockedBy or {}

  -- Build dependency graph starting from this task
  local visited = {}
  local rec_stack = {}

  local function has_cycle(current_task_path, deps)
    if rec_stack[current_task_path] then
      return true, "Circular dependency detected"
    end

    if visited[current_task_path] then
      return false
    end

    visited[current_task_path] = true
    rec_stack[current_task_path] = true

    -- Check all dependencies of current task
    for _, dep_path in ipairs(deps or {}) do
      local dep_task = M.tasks_by_path[dep_path]
      if not dep_task then
        -- Try to find by filename match
        for _, t in ipairs(M.tasks) do
          if t.path:match(dep_path .. "$") or t.path:match("/" .. dep_path .. "$") then
            dep_task = t
            break
          end
        end
      end

      if dep_task then
        local has_circular, err = has_cycle(dep_task.path, dep_task.blockedBy or {})
        if has_circular then
          return true, err  -- Propagate cycle detection up the call stack
        end
      end
    end

    rec_stack[current_task_path] = nil
    return false
  end

  local has_circular, err = has_cycle(task.path, dependencies)
  if has_circular then
    return false, err
  end

  return true
end

-- Clear the persistent cache file and force a fresh vault scan
function M.clear_cache()
  local cache_path = get_cache_path()

  -- Delete cache file if it exists
  if vim.fn.filereadable(cache_path) == 1 then
    local success = os.remove(cache_path)
    if success then
      vim.notify("Cache cleared successfully", vim.log.levels.INFO)
      -- Clear in-memory cache and trigger fresh scan
      M.tasks = {}
      M.tasks_by_path = {}
      M.is_loaded = false
      M.scan_vault(true)
    else
      vim.notify("Failed to delete cache file", vim.log.levels.ERROR)
      return false
    end
  else
    vim.notify("No cache file found", vim.log.levels.WARN)
  end

  return true
end

return M
