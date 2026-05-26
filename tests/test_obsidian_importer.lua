-- Tests for Obsidian settings importer
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[Importer = require('tasknotes.obsidian_importer')]])
    end,
    post_once = child.stop,
  },
})

-- Test excludedFolders parsing
T['map_to_nvim_config'] = new_set()

T['map_to_nvim_config']['parses excludedFolders as comma-separated string'] = function()
  child.lua([[
    _G.obsidian_settings = {
      tasksFolder = "Tasks",
      excludedFolders = "04_Archive,05_Attachments,06_Metadata,OLD_VAULT"
    }
    _G.result = Importer.map_to_nvim_config(_G.obsidian_settings, "/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.result.obsidian.ignore_dirs]])

  eq(#ignore_dirs, 4)
  eq(vim.tbl_contains(ignore_dirs, "04_Archive"), true)
  eq(vim.tbl_contains(ignore_dirs, "05_Attachments"), true)
  eq(vim.tbl_contains(ignore_dirs, "06_Metadata"), true)
  eq(vim.tbl_contains(ignore_dirs, "OLD_VAULT"), true)
end

T['map_to_nvim_config']['handles empty excludedFolders string'] = function()
  child.lua([[
    _G.obsidian_settings = {
      tasksFolder = "Tasks",
      excludedFolders = ""
    }
    _G.result = Importer.map_to_nvim_config(_G.obsidian_settings, "/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.result.obsidian.ignore_dirs]])

  eq(#ignore_dirs, 0)
end

T['map_to_nvim_config']['handles missing excludedFolders'] = function()
  child.lua([[
    _G.obsidian_settings = {
      tasksFolder = "Tasks"
    }
    _G.result = Importer.map_to_nvim_config(_G.obsidian_settings, "/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.result.obsidian.ignore_dirs]])

  eq(#ignore_dirs, 0)
end

T['map_to_nvim_config']['trims whitespace in folder names'] = function()
  child.lua([[
    _G.obsidian_settings = {
      tasksFolder = "Tasks",
      excludedFolders = "Archive, Templates , OLD_VAULT"
    }
    _G.result = Importer.map_to_nvim_config(_G.obsidian_settings, "/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.result.obsidian.ignore_dirs]])

  eq(#ignore_dirs, 3)
  eq(vim.tbl_contains(ignore_dirs, "Archive"), true)
  eq(vim.tbl_contains(ignore_dirs, "Templates"), true)
  eq(vim.tbl_contains(ignore_dirs, "OLD_VAULT"), true)
end

T['map_to_nvim_config']['handles single folder'] = function()
  child.lua([[
    _G.obsidian_settings = {
      tasksFolder = "Tasks",
      excludedFolders = "Archive"
    }
    _G.result = Importer.map_to_nvim_config(_G.obsidian_settings, "/vault")
  ]])

  local ignore_dirs = child.lua_get([[_G.result.obsidian.ignore_dirs]])

  eq(#ignore_dirs, 1)
  eq(vim.tbl_contains(ignore_dirs, "Archive"), true)
end

return T
