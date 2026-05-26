-- Tests for cache vault path validation
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      -- Only load Cache module for most tests (avoid bases dependency)
      child.lua([[Cache = require('tasknotes.cache')]])
    end,
    post_once = child.stop,
  },
})

-- Test vault path validation
T['validate_vault_path'] = new_set()

T['validate_vault_path']['detects vault move to different path'] = function()
  child.lua([[_G.test_cache = {version = 2, vault_path = "/old/vault/path", tasks = {}, file_list = {}}]])
  local valid = child.lua_get([[select(1, Cache.validate_vault_path(_G.test_cache, "/new/vault/path"))]])
  local message = child.lua_get([[select(2, Cache.validate_vault_path(_G.test_cache, "/new/vault/path"))]])

  eq(valid, false)
  -- Check message contains "Vault moved"
  eq(message:match("Vault moved") ~= nil, true)
end

T['validate_vault_path']['accepts same vault path'] = function()
  local vault_path = helpers.create_test_vault(child)

  -- Include ignore_dirs to match current config defaults
  child.lua([[
    Config = require('tasknotes.config')
    Config.setup({})
    local ignore_dirs = Config.get_ignore_dirs()
    _G.test_cache = {version = 2, vault_path = ..., ignore_dirs = ignore_dirs, tasks = {}, file_list = {}}
  ]], { vault_path })
  local valid = child.lua_get([[select(1, Cache.validate_vault_path(_G.test_cache, ...))]], { vault_path })

  eq(valid, true)

  helpers.cleanup_vault(child, vault_path)
end

T['validate_vault_path']['rejects cache missing vault_path (v1 format)'] = function()
  child.lua([[_G.test_cache = {version = 1, tasks = {}, file_list = {}}]])
  local valid = child.lua_get([[select(1, Cache.validate_vault_path(_G.test_cache, "/some/vault/path"))]])
  local message = child.lua_get([[select(2, Cache.validate_vault_path(_G.test_cache, "/some/vault/path"))]])

  eq(valid, false)
  -- Check message contains "missing vault_path"
  eq(message:match("missing vault_path") ~= nil, true)
end

T['validate_vault_path']['normalizes paths with trailing slashes'] = function()
  local vault_path = helpers.create_test_vault(child)

  -- Include ignore_dirs to match current config defaults
  child.lua([[
    Config = require('tasknotes.config')
    Config.setup({})
    local ignore_dirs = Config.get_ignore_dirs()
    _G.test_cache = {version = 2, vault_path = ... .. "/", ignore_dirs = ignore_dirs, tasks = {}, file_list = {}}
  ]], { vault_path })
  local valid = child.lua_get([[select(1, Cache.validate_vault_path(_G.test_cache, ...))]], { vault_path })

  eq(valid, true)

  helpers.cleanup_vault(child, vault_path)
end

T['validate_vault_path']['handles tilde expansion'] = function()
  local expanded = child.lua_get([[vim.fn.expand("~/vault")]])
  -- Include ignore_dirs to match current config defaults
  child.lua([[
    Config = require('tasknotes.config')
    Config.setup({})
    local ignore_dirs = Config.get_ignore_dirs()
    _G.test_cache = {version = 2, vault_path = vim.fn.expand("~/vault"), ignore_dirs = ignore_dirs, tasks = {}, file_list = {}}
  ]])
  local valid = child.lua_get([[select(1, Cache.validate_vault_path(_G.test_cache, "~/vault"))]])

  eq(valid, true)
end

-- Test cache schema version 2
T['cache_schema_v2'] = new_set()

T['cache_schema_v2']['new() creates cache with vault_path'] = function()
  child.lua([[_G.new_cache = Cache.new("/test/vault/path")]])
  local version = child.lua_get([[_G.new_cache.version]])
  local has_vault_path = child.lua_get([[_G.new_cache.vault_path ~= nil]])
  local vault_path = child.lua_get([[_G.new_cache.vault_path]])

  eq(version, 2)
  eq(has_vault_path, true)
  eq(vault_path, "/test/vault/path")
end

T['cache_schema_v2']['save() accepts vault_path parameter'] = function()
  local test_vault_path = "/test/vault/path"
  local cache_dir = child.lua_get([[vim.fn.stdpath("state") .. "/tasknotes_test"]])

  -- Create test cache directory
  child.lua([[vim.fn.mkdir(..., "p")]], { cache_dir })

  local cache_path = cache_dir .. "/test_cache.json"

  -- Verify save() accepts vault_path parameter without error
  child.lua([[_G.test_cache = Cache.new(...)]], { test_vault_path })
  child.lua([[_G.test_cache.tasks = {}]])
  child.lua([[_G.test_cache.file_list = {}]])

  -- This should not throw an error (would fail the test if it did)
  local success = child.lua_get([[Cache.save(..., _G.test_cache, ...)]], { cache_path, test_vault_path })

  eq(success, true)

  -- Verify the cache file was created
  local file_exists = child.lua_get([[vim.fn.filereadable(...) == 1]], { cache_path })
  eq(file_exists, true)

  -- Cleanup
  child.lua([[vim.fn.delete(..., "rf")]], { cache_dir })
end

-- Test clear_cache function
T['clear_cache'] = new_set()

T['clear_cache']['removes cache file and rescans vault'] = function()
  -- Skip this test if bases is not available
  local has_bases = child.lua_get([[pcall(require, 'bases')]])

  if not has_bases then
    MiniTest.skip('Requires bases.nvim')
    return
  end

  -- Load required modules for this test
  child.lua([[TaskManager = require('tasknotes.task_manager')]])
  child.lua([[Config = require('tasknotes.config')]])

  local vault_path = helpers.create_test_vault(child)

  -- Create a task file
  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Test Task',
    status = 'open',
    priority = 'high',
  })

  -- Initialize config and scan vault
  child.lua([[Config.setup({vault_path = ..., task_identification_method = 'property'})]], { vault_path })
  child.lua([[TaskManager.scan_vault()]])

  -- Verify task was loaded
  local task_count_before = child.lua_get([[#TaskManager.tasks]])
  eq(task_count_before > 0, true)

  -- Clear cache
  child.lua([[TaskManager.clear_cache()]])

  -- Verify tasks are still loaded (cache was cleared and rescanned)
  local task_count_after = child.lua_get([[#TaskManager.tasks]])
  eq(task_count_after > 0, true)

  helpers.cleanup_vault(child, vault_path)
end

-- Test vault move integration
T['vault_move_integration'] = new_set()

T['vault_move_integration']['invalidates cache and rebuilds when vault moves'] = function()
  -- Skip this test if bases is not available
  local has_bases = child.lua_get([[pcall(require, 'bases')]])

  if not has_bases then
    MiniTest.skip('Requires bases.nvim')
    return
  end

  -- Load required modules for this test
  child.lua([[TaskManager = require('tasknotes.task_manager')]])
  child.lua([[Config = require('tasknotes.config')]])

  local vault_path1 = helpers.create_test_vault(child)
  local vault_path2 = helpers.create_test_vault(child)

  -- Create task in first vault
  helpers.create_test_task(child, vault_path1, {
    type = 'task',
    title = 'Task in Vault 1',
    status = 'open',
  })

  -- Initialize with first vault
  child.lua([[Config.setup({vault_path = ..., task_identification_method = 'property'})]], { vault_path1 })
  child.lua([[TaskManager.scan_vault()]])

  local task_count_vault1 = child.lua_get([[#TaskManager.tasks]])
  eq(task_count_vault1, 1)

  -- Create task in second vault
  helpers.create_test_task(child, vault_path2, {
    type = 'task',
    title = 'Task in Vault 2',
    status = 'open',
  })

  -- "Move" vault by changing config to point to second vault
  child.lua([[Config.setup({vault_path = ..., task_identification_method = 'property'})]], { vault_path2 })
  child.lua([[TaskManager.scan_vault()]])

  -- Should load tasks from new vault (cache should be invalidated)
  local task_count_vault2 = child.lua_get([[#TaskManager.tasks]])
  eq(task_count_vault2, 1)

  -- Verify it's the task from vault 2
  local task_title = child.lua_get([[TaskManager.tasks[1].title]])
  eq(task_title, 'Task in Vault 2')

  helpers.cleanup_vault(child, vault_path1)
  helpers.cleanup_vault(child, vault_path2)
end

return T
