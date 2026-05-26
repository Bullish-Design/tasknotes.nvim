-- Tests for tasknotes.parser module
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[Parser = require('tasknotes.parser')]])
    end,
    post_once = child.stop,
  },
})

-- Test YAML frontmatter splitting
T['split_frontmatter'] = new_set()

T['split_frontmatter']['works with valid frontmatter'] = function()
  local content = [[---
title: Test Task
status: open
---
Body content here]]

  child.lua([[_G.test_result = {Parser.split_frontmatter(...)}]], { content })
  local frontmatter = child.lua_get("_G.test_result[1]")
  local body = child.lua_get("_G.test_result[2]")
  eq(frontmatter ~= nil and frontmatter ~= vim.NIL, true) -- frontmatter exists
  eq(body:match('Body content'), 'Body content')
end

T['split_frontmatter']['handles missing frontmatter'] = function()
  local content = 'Just body content'
  child.lua([[_G.test_result = {Parser.split_frontmatter(...)}]], { content })
  local frontmatter = child.lua_get("_G.test_result[1]")
  local body = child.lua_get("_G.test_result[2]")
  eq(frontmatter == nil or frontmatter == vim.NIL, true) -- no frontmatter
  eq(body, 'Just body content')
end

T['split_frontmatter']['handles empty frontmatter'] = function()
  local content = [[---
---
Body only]]

  child.lua([[_G.test_result = {Parser.split_frontmatter(...)}]], { content })
  local frontmatter = child.lua_get("_G.test_result[1]")
  local body = child.lua_get("_G.test_result[2]")
  eq(frontmatter ~= nil and frontmatter ~= vim.NIL, true)
  eq(body:match('Body only'), 'Body only')
end

-- Test YAML parsing
T['parse_yaml'] = new_set()

T['parse_yaml']['handles null values'] = function()
  local yaml = [[title: Test Task
status: open
due: null]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(result.title, 'Test Task')
  eq(result.status, 'open')
  -- due should be nil or vim.NIL
  eq(result.due == nil or result.due == vim.NIL, true)
end

T['parse_yaml']['handles empty values'] = function()
  local yaml = [[title: Test Task
status:
due:]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(result.title, 'Test Task')
  -- Empty values should become nil or empty string
  local status_ok = result.status == nil or result.status == vim.NIL or result.status == ''
  eq(status_ok, true)
end

T['parse_yaml']['parses arrays correctly'] = function()
  local yaml = [[tags:
  - task
  - work
contexts:
  - "@home"]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(#result.tags, 2)
  eq(result.tags[1], 'task')
  eq(result.contexts[1], '@home')
end

T['parse_yaml']['parses nested objects'] = function()
  local yaml = [[timeEntries:
  - startTime: "2025-01-15T10:00:00Z"
    endTime: "2025-01-15T11:00:00Z"
    duration: 60]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(type(result.timeEntries), 'table')
  eq(#result.timeEntries, 1)
  eq(result.timeEntries[1].duration, 60)
end

-- Test YAML serialization
T['serialize_yaml'] = new_set()

T['serialize_yaml']['serializes simple values'] = function()
  local data = {
    title = 'Test Task',
    status = 'open',
    priority = 'high',
  }

  local result = child.lua_get([[Parser.serialize_yaml(...)]], { data })
  eq(result:match('title: Test Task') ~= nil, true)
  eq(result:match('status: open') ~= nil, true)
end

T['serialize_yaml']['serializes arrays'] = function()
  local data = {
    tags = { 'task', 'work' },
    contexts = { '@home' },
  }

  local result = child.lua_get([[Parser.serialize_yaml(...)]], { data })
  eq(result:match('tags:') ~= nil, true)
  eq(result:match('- task') ~= nil, true)
  eq(result:match('- work') ~= nil, true)
end

-- Test full file parsing
T['parse_file'] = new_set()

T['parse_file']['parses complete task file'] = function()
  local vault_path = helpers.create_test_vault(child)
  local filepath = helpers.create_test_task(child, vault_path, {
    title = 'Test Task',
    status = 'open',
    priority = 'high',
    tags = { 'task' },
  }, 'Task description here')

  local result = child.lua_get([[Parser.parse_file(...)]], { filepath })

  eq(result.frontmatter.title, 'Test Task')
  eq(result.frontmatter.status, 'open')
  eq(result.body:match('Task description'), 'Task description')

  helpers.cleanup_vault(child, vault_path)
end

T['parse_file']['handles missing file'] = function()
  local result = child.lua_get([[Parser.parse_file('/nonexistent/file.md')]])
  eq(result, vim.NIL)
end

return T
