-- Tests for tasknotes.task_manager module
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      local temp_vault = child.lua_get([[vim.fn.tempname()]])
      child.lua(string.format([[
        vim.fn.mkdir('%s', 'p')
        Config = require('tasknotes.config')
        Config.setup({ vault_path = '%s' })
        TaskManager = require('tasknotes.task_manager')
      ]], temp_vault, temp_vault))
    end,
    post_once = child.stop,
  },
})

-- Test task object creation
T['create_task_object'] = new_set()

T['create_task_object']['handles vim.NIL values'] = function()
  -- This is the CRITICAL test for the bug fix
  child.lua([[
    -- Simulate frontmatter with vim.NIL values (what YAML parser returns for null)
    _G.test_frontmatter = {
      title = 'Test Task',
      status = 'open',
      due = vim.NIL,  -- This is what causes the concatenation bug
      priority = vim.NIL,
      scheduled = vim.NIL,
    }
    _G.test_result = TaskManager.create_task_object('/test.md', _G.test_frontmatter, 'body')
  ]])

  local result = child.lua_get("_G.test_result")

  eq(result.title, 'Test Task')
  eq(result.status, 'open')
  -- These should be normalized to nil (not vim.NIL)
  eq(result.due == nil or result.due == '', true)
  eq(result.priority == 'none', true) -- Default value
end

T['create_task_object']['uses correct defaults'] = function()
  child.lua([[
    _G.test_frontmatter = { title = 'Minimal Task' }
    _G.test_result = TaskManager.create_task_object('/test.md', _G.test_frontmatter, '')
  ]])

  local result = child.lua_get("_G.test_result")

  eq(result.title, 'Minimal Task')
  eq(result.status, 'open')  -- default
  eq(result.priority, 'none')  -- default
  eq(type(result.contexts), 'table')
  eq(#result.contexts, 0)
  eq(type(result.projects), 'table')
  eq(type(result.tags), 'table')
end

T['create_task_object']['converts string arrays to tables'] = function()
  child.lua([=[
    _G.frontmatter = {
      title = 'Test',
      contexts = '@home',
      projects = '[[Project]]',
    }
    _G.result = TaskManager.create_task_object('/test.md', _G.frontmatter, '')
  ]=])

  local contexts_type = child.lua_get([=[type(_G.result.contexts)]=])
  local contexts_len = child.lua_get([=[#_G.result.contexts]=])
  local contexts_val = child.lua_get([=[_G.result.contexts[1]]=])
  local projects_type = child.lua_get([=[type(_G.result.projects)]=])
  local projects_val = child.lua_get([=[_G.result.projects[1]]=])

  eq(contexts_type, 'table')
  eq(contexts_len, 1)
  eq(contexts_val, '@home')
  eq(projects_type, 'table')
  eq(projects_val, '[[Project]]')
end

T['create_task_object']['preserves all frontmatter fields'] = function()
  child.lua([=[
    _G.test_frontmatter = {
      title = 'Complete Task',
      status = 'in-progress',
      priority = 'high',
      due = '2025-12-31',
      scheduled = '2025-12-01',
      contexts = { '@office' },
      projects = { '[[Work]]' },
      tags = { 'task', 'urgent' },
      timeEstimate = 120,
      dateCreated = '2025-01-01T00:00:00Z',
    }
    _G.test_result = TaskManager.create_task_object('/test.md', _G.test_frontmatter, 'Task body')
  ]=])

  local result = child.lua_get("_G.test_result")

  eq(result.title, 'Complete Task')
  eq(result.status, 'in-progress')
  eq(result.priority, 'high')
  eq(result.due, '2025-12-31')
  eq(result.scheduled, '2025-12-01')
  eq(result.timeEstimate, 120)
  eq(result.body, 'Task body')
end

-- Test task identification methods
T['task_identification'] = new_set()

T['task_identification']['tag-based identification works'] = function()
  child.lua([[
    Config.options.task_identification_method = 'tag'
    Config.options.task_tag = 'task'
  ]])

  local vault_path = helpers.create_test_vault(child)

  -- Create a task with tag
  helpers.create_test_task(child, vault_path, {
    title = 'Tagged Task',
    tags = { 'task', 'work' },
  }, 'Body')

  -- Create a non-task (no task tag)
  helpers.create_test_task(child, vault_path, {
    title = 'Not a Task',
    tags = { 'note' },
  }, 'Body')

  child.lua(string.format([[
    Config.options.vault_path = '%s'
    TaskManager.scan_vault()
  ]], vault_path))

  local task_count = child.lua_get([[#TaskManager.tasks]])
  eq(task_count, 1) -- Only the tagged task should be found

  helpers.cleanup_vault(child, vault_path)
end

T['task_identification']['property-based identification works'] = function()
  child.lua([[
    Config.options.task_identification_method = 'property'
    Config.options.task_property_name = 'type'
    Config.options.task_property_value = 'task'
  ]])

  local vault_path = helpers.create_test_vault(child)

  -- Create a task with type property
  helpers.create_test_task(child, vault_path, {
    title = 'Property Task',
    type = 'task',
  }, 'Body')

  -- Create a non-task (different type)
  helpers.create_test_task(child, vault_path, {
    title = 'Not a Task',
    type = 'note',
  }, 'Body')

  child.lua(string.format([[
    Config.options.vault_path = '%s'
    TaskManager.scan_vault()
  ]], vault_path))

  local task_count = child.lua_get([[#TaskManager.tasks]])
  eq(task_count, 1) -- Only the property-matching task should be found

  helpers.cleanup_vault(child, vault_path)
end

-- Test time calculation
T['calculate_total_time'] = new_set()

T['calculate_total_time']['calculates total from entries'] = function()
  child.lua([[
    _G.test_entries = {
      { startTime = '2025-01-15T10:00:00Z', endTime = '2025-01-15T11:00:00Z', duration = 60 },
      { startTime = '2025-01-15T14:00:00Z', endTime = '2025-01-15T14:30:00Z', duration = 30 },
    }
    _G.test_result = TaskManager.calculate_total_time(_G.test_entries)
  ]])

  local result = child.lua_get("_G.test_result")

  eq(result, 90) -- 60 + 30 minutes
end

T['calculate_total_time']['handles empty entries'] = function()
  local result = child.lua_get("TaskManager.calculate_total_time({})")

  eq(result, 0)
end

-- Test loading state tracking (regression test for race condition bug)
T['loading_state_tracking'] = new_set()

T['loading_state_tracking']['is_loaded is false initially'] = function()
  -- Test that is_loaded starts as false before any scan
  local is_loaded = child.lua_get("TaskManager.is_loaded")

  eq(is_loaded, false)
end

T['loading_state_tracking']['is_loaded becomes true after scan_vault'] = function()
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Test Task',
    status = 'open',
    tags = { 'task' },
  }, 'Test body')

  child.lua(string.format([[
    Config.options.vault_path = '%s'
    TaskManager.scan_vault()
  ]], vault_path))

  local is_loaded = child.lua_get("TaskManager.is_loaded")
  eq(is_loaded, true)

  helpers.cleanup_vault(child, vault_path)
end

T['loading_state_tracking']['is_loaded set by fast cache path'] = function()
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Cached Task',
    status = 'open',
    tags = { 'task' },
  }, 'Body')

  -- First scan to create cache
  child.lua(string.format([[
    Config.options.vault_path = '%s'
    Config.options.cache.enabled = true
    TaskManager.scan_vault()
  ]], vault_path))

  -- Reset is_loaded flag to simulate restart
  child.lua([[
    TaskManager.is_loaded = false
    TaskManager.tasks = {}
    TaskManager.tasks_by_path = {}
  ]])

  -- Second scan should use fast cache path
  child.lua([[TaskManager.scan_vault()]])

  local is_loaded = child.lua_get("TaskManager.is_loaded")
  eq(is_loaded, true)

  helpers.cleanup_vault(child, vault_path)
end

T['loading_state_tracking']['is_loaded set by slow validation path'] = function()
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Validated Task',
    status = 'open',
    tags = { 'task' },
  }, 'Body')

  -- Scan with validation (slow path)
  child.lua(string.format([[
    Config.options.vault_path = '%s'
    Config.options.cache.validate_on_startup = true
    TaskManager.scan_vault()
  ]], vault_path))

  local is_loaded = child.lua_get("TaskManager.is_loaded")
  eq(is_loaded, true)

  helpers.cleanup_vault(child, vault_path)
end

T['loading_state_tracking']['scan_vault called multiple times maintains state'] = function()
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Multi-scan Task',
    status = 'open',
    tags = { 'task' },
  }, 'Body')

  child.lua(string.format([[
    Config.options.vault_path = '%s'
    -- First scan
    TaskManager.scan_vault()
    FIRST_LOADED = TaskManager.is_loaded

    -- Second scan
    TaskManager.scan_vault()
    SECOND_LOADED = TaskManager.is_loaded
  ]], vault_path))

  local first_loaded = child.lua_get("FIRST_LOADED")
  local second_loaded = child.lua_get("SECOND_LOADED")

  eq(first_loaded, true)
  eq(second_loaded, true)

  helpers.cleanup_vault(child, vault_path)
end

return T
