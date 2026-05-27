-- Tests for directory ignore functionality
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[Config = require('tasknotes.config')]])
      child.lua([[Cache = require('tasknotes.cache')]])
    end,
    post_once = child.stop,
  },
})

-- Test get_ignore_dirs() function
T['get_ignore_dirs'] = new_set()

T['get_ignore_dirs']['returns defaults when nothing configured'] = function()
  child.lua([[Config.setup({})]])
  local ignore_dirs = child.lua_get([[Config.get_ignore_dirs()]])

  -- Should contain default ignores
  eq(vim.tbl_contains(ignore_dirs, ".obsidian"), true)
  eq(vim.tbl_contains(ignore_dirs, ".trash"), true)
  eq(vim.tbl_contains(ignore_dirs, ".git"), true)
  eq(vim.tbl_contains(ignore_dirs, ".claude"), true)
  eq(#ignore_dirs, 4)
end

T['get_ignore_dirs']['merges Obsidian settings with defaults'] = function()
  child.lua([[
    Config.setup({
      obsidian = {
        ignore_dirs = { "Archive", "Templates" }
      }
    })
  ]])
  local ignore_dirs = child.lua_get([[Config.get_ignore_dirs()]])

  -- Should contain defaults + Obsidian settings
  eq(vim.tbl_contains(ignore_dirs, ".obsidian"), true)
  eq(vim.tbl_contains(ignore_dirs, ".trash"), true)
  eq(vim.tbl_contains(ignore_dirs, ".git"), true)
  eq(vim.tbl_contains(ignore_dirs, ".claude"), true)
  eq(vim.tbl_contains(ignore_dirs, "Archive"), true)
  eq(vim.tbl_contains(ignore_dirs, "Templates"), true)
  eq(#ignore_dirs, 6)
end

T['get_ignore_dirs']['Neovim config completely overrides'] = function()
  child.lua([[
    Config.setup({
      obsidian = {
        ignore_dirs = { "Archive", "Templates" }
      },
      ignore_dirs = { "Custom1", "Custom2" }
    })
  ]])
  local ignore_dirs = child.lua_get([[Config.get_ignore_dirs()]])

  -- Should only contain Neovim config, NOT defaults or Obsidian
  eq(vim.tbl_contains(ignore_dirs, "Custom1"), true)
  eq(vim.tbl_contains(ignore_dirs, "Custom2"), true)
  eq(#ignore_dirs, 2)
  eq(vim.tbl_contains(ignore_dirs, ".obsidian"), false)
  eq(vim.tbl_contains(ignore_dirs, "Archive"), false)
end

T['get_ignore_dirs']['empty array disables all ignores'] = function()
  child.lua([[
    Config.setup({
      ignore_dirs = {}
    })
  ]])
  local ignore_dirs = child.lua_get([[Config.get_ignore_dirs()]])

  -- Should be empty
  eq(#ignore_dirs, 0)
end

T['get_ignore_dirs']['avoids duplicates when merging'] = function()
  child.lua([[
    Config.setup({
      obsidian = {
        ignore_dirs = { ".obsidian", "Archive" }  -- .obsidian is a duplicate
      }
    })
  ]])
  local ignore_dirs = child.lua_get([[Config.get_ignore_dirs()]])

  -- Should not have duplicate .obsidian
  local obsidian_count = 0
  for _, dir in ipairs(ignore_dirs) do
    if dir == ".obsidian" then
      obsidian_count = obsidian_count + 1
    end
  end
  eq(obsidian_count, 1)
end

-- Test build_find_command (accessed via task_manager)
T['build_find_command'] = new_set()

T['build_find_command']['generates correct prune flags'] = function()
  -- Load task_manager to access build_find_command
  child.lua([[
    TaskManager = require('tasknotes.task_manager')
    -- Expose internal function for testing
    local mt = getmetatable(TaskManager) or {}
    local env = getfenv(TaskManager.scan_vault)
    build_find_command = env.build_find_command or function(vault_path, ignore_dirs)
      local cmd = string.format("find '%s'", vault_path)
      for _, dir in ipairs(ignore_dirs) do
        local escaped_dir = dir:gsub("'", "'\\\\''")
        cmd = cmd .. string.format(" -type d -name '%s' -prune -o", escaped_dir)
      end
      cmd = cmd .. " -type f -name '*.md' -print"
      return cmd
    end
  ]])

  local cmd = child.lua_get([[
    build_find_command("/vault", { ".obsidian", "Archive" })
  ]])

  -- Check command structure
  eq(cmd:match("find '/vault'") ~= nil, true)
  eq(cmd:match("%-type d %-name '%.obsidian' %-prune") ~= nil, true)
  eq(cmd:match("%-type d %-name 'Archive' %-prune") ~= nil, true)
  eq(cmd:match("%-type f %-name '%*%.md' %-print") ~= nil, true)
end

T['build_find_command']['escapes special characters in dir names'] = function()
  child.lua([[
    TaskManager = require('tasknotes.task_manager')
    local env = getfenv(TaskManager.scan_vault)
    build_find_command = env.build_find_command or function(vault_path, ignore_dirs)
      local cmd = string.format("find '%s'", vault_path)
      for _, dir in ipairs(ignore_dirs) do
        local escaped_dir = dir:gsub("'", "'\\\\''")
        cmd = cmd .. string.format(" -type d -name '%s' -prune -o", escaped_dir)
      end
      cmd = cmd .. " -type f -name '*.md' -print"
      return cmd
    end
  ]])

  local cmd = child.lua_get([[
    build_find_command("/vault", { "Dir's Name" })
  ]])

  -- Should escape single quotes
  eq(cmd:match("Dir'\\\\''s Name") ~= nil, true)
end

-- Test cache invalidation
T['cache_invalidation'] = new_set()

T['cache_invalidation']['validates when ignore_dirs matches'] = function()
  child.lua([[
    Config.setup({ ignore_dirs = { "Archive" } })
  ]])

  child.lua([[
    _G.test_cache = {
      version = 2,
      vault_path = "/test/vault",
      ignore_dirs = { "Archive" },
      tasks = {},
      file_list = {}
    }
  ]])

  local valid = child.lua_get([[
    select(1, Cache.validate_vault_path(_G.test_cache, "/test/vault"))
  ]])

  eq(valid, true)
end

T['cache_invalidation']['invalidates when ignore_dirs changes'] = function()
  child.lua([[
    Config.setup({ ignore_dirs = { "NewDir" } })
  ]])

  child.lua([[
    _G.test_cache = {
      version = 2,
      vault_path = "/test/vault",
      ignore_dirs = { "Archive" },  -- Different from current config
      tasks = {},
      file_list = {}
    }
  ]])

  local valid = child.lua_get([[
    select(1, Cache.validate_vault_path(_G.test_cache, "/test/vault"))
  ]])
  local message = child.lua_get([[
    select(2, Cache.validate_vault_path(_G.test_cache, "/test/vault"))
  ]])

  eq(valid, false)
  eq(message:match("Ignore directories") ~= nil, true)
end

T['cache_invalidation']['invalidates when ignore_dirs added'] = function()
  child.lua([[
    Config.setup({ ignore_dirs = { "Archive", "Templates" } })
  ]])

  child.lua([[
    _G.test_cache = {
      version = 2,
      vault_path = "/test/vault",
      ignore_dirs = { "Archive" },  -- Missing "Templates"
      tasks = {},
      file_list = {}
    }
  ]])

  local valid = child.lua_get([[
    select(1, Cache.validate_vault_path(_G.test_cache, "/test/vault"))
  ]])

  eq(valid, false)
end

T['cache_invalidation']['handles missing ignore_dirs in old cache'] = function()
  child.lua([[
    Config.setup({ ignore_dirs = { "Archive" } })
  ]])

  child.lua([[
    _G.test_cache = {
      version = 2,
      vault_path = "/test/vault",
      -- No ignore_dirs field (old cache format)
      tasks = {},
      file_list = {}
    }
  ]])

  local valid = child.lua_get([[
    select(1, Cache.validate_vault_path(_G.test_cache, "/test/vault"))
  ]])

  -- Should invalidate due to missing field vs configured ignore_dirs
  eq(valid, false)
end

-- Test new() creates cache with ignore_dirs
T['cache_new'] = new_set()

T['cache_new']['includes ignore_dirs from config'] = function()
  child.lua([[
    Config.setup({ ignore_dirs = { "Archive", "Templates" } })
  ]])

  child.lua([[
    _G.new_cache = Cache.new("/test/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.new_cache.ignore_dirs]])

  eq(vim.tbl_contains(ignore_dirs, "Archive"), true)
  eq(vim.tbl_contains(ignore_dirs, "Templates"), true)
  eq(#ignore_dirs, 2)
end

T['cache_new']['includes defaults when no config'] = function()
  child.lua([[
    Config.setup({})
  ]])

  child.lua([[
    _G.new_cache = Cache.new("/test/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.new_cache.ignore_dirs]])

  eq(vim.tbl_contains(ignore_dirs, ".obsidian"), true)
  eq(vim.tbl_contains(ignore_dirs, ".trash"), true)
  eq(vim.tbl_contains(ignore_dirs, ".git"), true)
  eq(vim.tbl_contains(ignore_dirs, ".claude"), true)
end

return T
