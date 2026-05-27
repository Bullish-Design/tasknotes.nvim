local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function() child.setup() end,
    post_once = child.stop,
  },
})

local function setup_cfg(vault)
  child.lua(string.format([[
    Config=require('tasknotes.config')
    Config.setup({ vault_path='%s' })
    TM=require('tasknotes.task_manager')
    TM.tasks = {
      { contexts={'home'}, projects={'proj1'}, tags={'alpha'} },
      { contexts={'work'}, projects={'proj2'}, tags={'beta'} },
    }
    FF=require('tasknotes.ui.form_fields')
  ]], vault))
end

T['create_task_fields returns expected field names'] = function()
  local vault = helpers.create_test_vault(child)
  setup_cfg(vault)
  child.lua([[
    local fields = FF.create_task_fields({}, { mode='create' })
    local out = {}
    for _, f in ipairs(fields) do
      if f.name then
        table.insert(out, f.name)
      end
    end
    _G._form_field_names = out
  ]])
  local names = child.lua_get([[_G._form_field_names]])
  eq(names, { 'title', 'status', 'priority', 'due', 'scheduled', 'contexts', 'projects', 'tags', 'blockedBy', 'timeEstimate', 'body' })
  helpers.cleanup_vault(child, vault)
end

T['create_task_fields uses select and multiline types with defaults and features'] = function()
  local vault = helpers.create_test_vault(child)
  setup_cfg(vault)
  child.lua([[
    local fields = FF.create_task_fields({
      title = 'T', status = 'open', priority = 'high', body = 'note', contexts = { 'home' }
    }, { mode = 'edit' })
    local by = {}
    for _, f in ipairs(fields) do
      if f.name then
        by[f.name] = f
      end
    end
    _G._form_field_summary = {
      status_type = by.status.type,
      priority_type = by.priority.type,
      body_type = by.body.type,
      body_default = by.body.default,
      due_has_keymaps = by.due.keymaps ~= nil,
      contexts_has_complete = by.contexts.complete ~= nil,
    }
  ]])
  local result = child.lua_get([[_G._form_field_summary]])
  eq(result.status_type, 'select')
  eq(result.priority_type, 'select')
  eq(result.body_type, 'multiline')
  eq(result.body_default, 'note')
  eq(result.due_has_keymaps, true)
  eq(result.contexts_has_complete, true)
  helpers.cleanup_vault(child, vault)
end

T['form_values_to_task_data normalizes values and returns body separately'] = function()
  local vault = helpers.create_test_vault(child)
  setup_cfg(vault)
  child.lua([[
    local data, body = FF.form_values_to_task_data({
      title = 'T', status = 'open', priority = 'none', due = '', scheduled = '',
      contexts = 'a, b', projects = 'p1, p2', tags = 'x, y', blockedBy = '',
      timeEstimate = '45', body = 'details'
    })
    _G._form_values_result = { data = data, body = body, has_body = data.body ~= nil }
  ]])
  local out = child.lua_get([[_G._form_values_result]])
  eq(out.data.due, nil)
  eq(out.data.scheduled, nil)
  eq(out.data.contexts, { 'a', 'b' })
  eq(out.data.projects, { 'p1', 'p2' })
  eq(out.data.tags, { 'x', 'y' })
  eq(out.data.timeEstimate, 45)
  eq(out.body, 'details')
  eq(out.has_body, false)
  helpers.cleanup_vault(child, vault)
end

return T
