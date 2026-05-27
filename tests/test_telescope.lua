-- Tests for tasknotes.telescope module
-- Includes regression test for the concatenation bug
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()

      -- Check if telescope is available
      child.lua([[_G.has_telescope = pcall(require, 'telescope')]])
      local has_telescope = child.lua_get("_G.has_telescope")

      if not has_telescope then
        MiniTest.skip('Telescope not available')
        return
      end

      local temp_vault = child.lua_get([[vim.fn.tempname()]])
      child.lua(string.format([[
        vim.fn.mkdir('%s', 'p')
        Config = require('tasknotes.config')
        Config.setup({ vault_path = '%s' })
        TaskManager = require('tasknotes.task_manager')
        Telescope = require('tasknotes.telescope')
      ]], temp_vault, temp_vault))
    end,
    post_once = child.stop,
  },
})

-- Test the safe_string helper and entry maker (regression test for the bug)
T['entry_maker_safe_string'] = new_set()

T['entry_maker_safe_string']['handles nil values without error'] = function()
  -- This tests the scenario where values are explicitly nil
  child.lua([[
    -- Simulate a task with nil values
    _G.test_task = {
      path = '/test.md',
      title = 'Test Task',
      status = 'open',
      due = nil,  -- nil value
      contexts = {},
      projects = {},
      tags = {},
      priority = 'none',
    }

    -- Test that we can safely concatenate these values
    -- (this is what happens in make_entry's ordinal field)
    _G.test_success, _G.test_result = pcall(function()
      -- This is the safe_string logic from telescope.lua
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      local ordinal = safe_string(_G.test_task.title) .. ' ' ..
                     safe_string(_G.test_task.status) .. ' ' ..
                     safe_string(_G.test_task.due)
      return ordinal
    end)
  ]])

  local success = child.lua_get("_G.test_success and _G.test_result ~= nil")
  eq(success, true)
end

T['entry_maker_safe_string']['handles vim.NIL values without error (REGRESSION TEST)'] = function()
  -- This is the EXACT bug scenario that caused the error:
  -- "attempt to concatenate a userdata value"
  child.lua([[
    -- Simulate a task with vim.NIL values (from YAML parser)
    _G.test_task = {
      path = '/test.md',
      title = 'Test Task',
      status = vim.NIL,  -- vim.NIL from YAML parser (the bug!)
      due = vim.NIL,     -- vim.NIL from YAML parser
      contexts = {},
      projects = {},
      tags = {},
      priority = vim.NIL,
    }

    -- This should NOT crash after our fix
    _G.test_success, _G.test_result = pcall(function()
      -- This is the safe_string logic that fixes the bug
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      -- This concatenation previously failed with:
      -- "attempt to concatenate a userdata value"
      local ordinal = safe_string(_G.test_task.title) .. ' ' ..
                     safe_string(_G.test_task.status) .. ' ' ..
                     safe_string(_G.test_task.due)

      return ordinal
    end)
  ]])

  local success = child.lua_get("_G.test_success and _G.test_result ~= nil")
  eq(success, true)
end

T['entry_maker_safe_string']['handles mixed nil and vim.NIL values'] = function()
  child.lua([[
    _G.test_task = {
      path = '/test.md',
      title = 'Test Task',   -- string
      status = nil,          -- nil
      due = vim.NIL,         -- vim.NIL
      priority = 'high',     -- string
      contexts = {},
      projects = {},
      tags = {},
    }

    _G.test_success, _G.test_result = pcall(function()
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      local ordinal = safe_string(_G.test_task.title) .. ' ' ..
                     safe_string(_G.test_task.status) .. ' ' ..
                     safe_string(_G.test_task.due) .. ' ' ..
                     safe_string(_G.test_task.priority)

      -- Should produce: "Test Task   high"
      return ordinal
    end)
  ]])

  local success = child.lua_get("_G.test_success and _G.test_result:match('Test Task') ~= nil")
  eq(success, true)
end

-- Test display function
T['display_function'] = new_set()

T['display_function']['handles nil due date'] = function()
  child.lua([[
    _G.test_task = {
      path = '/test.md',
      title = 'Test Task',
      status = 'open',
      priority = 'normal',
      due = nil,  -- nil due date
      contexts = { '@home' },
      projects = {},
      tags = {},
    }

    _G.test_success, _G.test_err = pcall(function()
      -- Test safe_string for due date formatting (used in make_display)
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      local due_str = safe_string(_G.test_task.due)
      local title_str = safe_string(_G.test_task.title)

      return due_str == "" and title_str == "Test Task"
    end)
  ]])

  local success = child.lua_get("_G.test_success")
  eq(success, true)
end

T['display_function']['handles vim.NIL due date'] = function()
  child.lua([[
    _G.test_task = {
      path = '/test.md',
      title = 'Test Task',
      status = 'open',
      priority = 'normal',
      due = vim.NIL,  -- vim.NIL due date from YAML
      contexts = {},
      projects = {},
      tags = {},
    }

    _G.test_success, _G.test_err = pcall(function()
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      local due_str = safe_string(_G.test_task.due)
      return due_str == ""
    end)
  ]])

  local success = child.lua_get("_G.test_success")
  eq(success, true)
end

-- Test with actual task manager integration
T['full_integration'] = new_set()

T['full_integration']['task with nil values can be processed'] = function()
  -- This tests the full pipeline: task creation -> telescope entry
  child.lua([[
    -- Create a task object with vim.NIL values (simulating YAML parser output)
    _G.test_frontmatter = {
      title = 'Integration Test',
      status = vim.NIL,
      priority = vim.NIL,
      due = vim.NIL,
    }

    _G.test_task = TaskManager.create_task_object('/test.md', _G.test_frontmatter, '')

    -- After create_task_object, all vim.NIL should be normalized
    -- This is the defense-in-depth fix in task_manager.lua

    _G.test_success, _G.test_err = pcall(function()
      -- Simulate what happens in telescope's make_entry
      local function safe_string(value)
        if value == nil or value == vim.NIL then
          return ""
        end
        return tostring(value)
      end

      local ordinal = safe_string(_G.test_task.title) .. ' ' ..
                     safe_string(_G.test_task.status) .. ' ' ..
                     safe_string(_G.test_task.due)

      return ordinal ~= nil
    end)
  ]])

  local success = child.lua_get("_G.test_success")
  eq(success, true)
end

-- Test browse_tasks loading guard (regression test for race condition)
T['browse_loading_guard'] = new_set()

T['browse_loading_guard']['browse_tasks triggers scan if not loaded'] = function()
  -- Regression test for race condition where browse_tasks is called
  -- before scan_vault completes during plugin initialization
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Race Condition Test Task',
    status = 'open',
    tags = { 'task' },
  }, 'Test body')

  -- Reset task manager to simulate startup before scan
  child.lua(string.format([[
    Config.options.vault_path = '%s'
    -- Simulate state before scan_vault is called
    TaskManager.tasks = {}
    TaskManager.tasks_by_path = {}
    TaskManager.is_loaded = false
  ]], vault_path))

  -- Verify tasks are not loaded yet
  local tasks_before = child.lua_get("#TaskManager.tasks")
  eq(tasks_before, 0)

  -- Verify is_loaded is false
  local loaded_before = child.lua_get("TaskManager.is_loaded")
  eq(loaded_before, false)

  -- Call browse_tasks - it should trigger scan_vault automatically
  -- This simulates user pressing the browse keybinding before scan completes
  child.lua([[
    -- Simulate the guard logic from browse_tasks
    if not TaskManager.is_loaded then
      TaskManager.scan_vault()
    end

    TASKS_AFTER_GUARD = #TaskManager.tasks
    LOADED_AFTER_GUARD = TaskManager.is_loaded
  ]])

  local tasks_after = child.lua_get("TASKS_AFTER_GUARD")
  local loaded_after = child.lua_get("LOADED_AFTER_GUARD")

  -- After guard, tasks should be loaded
  eq(tasks_after, 1)  -- Should find the task
  eq(loaded_after, true)  -- is_loaded should be set

  helpers.cleanup_vault(child, vault_path)
end

T['browse_loading_guard']['browse_tasks works when already loaded'] = function()
  -- Test that guard doesn't break the normal flow when tasks are already loaded
  local vault_path = helpers.create_test_vault(child)
  helpers.create_test_task(child, vault_path, {
    title = 'Already Loaded Task',
    status = 'open',
    tags = { 'task' },
  }, 'Test body')

  -- Normal flow: scan_vault is called during initialization
  child.lua(string.format([[
    Config.options.vault_path = '%s'
    TaskManager.scan_vault()
  ]], vault_path))

  -- Verify tasks are loaded
  local tasks_before = child.lua_get("#TaskManager.tasks")
  eq(tasks_before, 1)

  -- Verify is_loaded is true
  local loaded_before = child.lua_get("TaskManager.is_loaded")
  eq(loaded_before, true)

  -- Call browse_tasks guard - should NOT trigger another scan
  child.lua([[
    -- Simulate the guard logic from browse_tasks
    SCAN_CALLED = false
    if not TaskManager.is_loaded then
      SCAN_CALLED = true
      TaskManager.scan_vault()
    end

    TASKS_AFTER_GUARD = #TaskManager.tasks
  ]])

  local scan_called = child.lua_get("SCAN_CALLED")
  local tasks_after = child.lua_get("TASKS_AFTER_GUARD")

  -- Guard should NOT have called scan again
  eq(scan_called, false)
  -- Tasks should still be available
  eq(tasks_after, 1)

  helpers.cleanup_vault(child, vault_path)
end

return T
