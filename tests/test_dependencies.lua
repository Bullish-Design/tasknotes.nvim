-- Tests for task dependencies functionality
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[
        Config = require('tasknotes.config')
        Config.setup({
          task_identification_method = 'property',  -- Use property-based identification for tests
        })
        TaskManager = require('tasknotes.task_manager')
        Parser = require('tasknotes.parser')
      ]])
    end,
    post_once = child.stop,
  },
})

-- Test parsing blockedBy field
T['parse_blockedBy'] = new_set()

T['parse_blockedBy']['parses single blocking task'] = function()
  local yaml = [[title: Task B
status: open
blockedBy:
  - /path/to/task-a.md]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(type(result.blockedBy), 'table')
  eq(#result.blockedBy, 1)
  eq(result.blockedBy[1], '/path/to/task-a.md')
end

T['parse_blockedBy']['parses multiple blocking tasks'] = function()
  local yaml = [[title: Task C
status: open
blockedBy:
  - /path/to/task-a.md
  - /path/to/task-b.md]]

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(type(result.blockedBy), 'table')
  eq(#result.blockedBy, 2)
  eq(result.blockedBy[1], '/path/to/task-a.md')
  eq(result.blockedBy[2], '/path/to/task-b.md')
end

T['parse_blockedBy']['handles empty blockedBy'] = function()
  local yaml = 'title: Task A\nstatus: open\nblockedBy: []'

  local result = child.lua_get([[Parser.parse_yaml(...)]], { yaml })
  eq(type(result.blockedBy), 'table')
  eq(#result.blockedBy, 0)
end

-- Test task object creation with blockedBy
T['create_task_object'] = new_set()

T['create_task_object']['includes blockedBy field'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task',
    status = 'open',
    blockedBy = { vault_path .. '/blocking-task.md' },
  })

  child.lua([[TaskManager.scan_vault(true)]])

  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  eq(type(task.blockedBy), 'table')
  eq(#task.blockedBy, 1)

  helpers.cleanup_vault(child, vault_path)
end

T['create_task_object']['normalizes blockedBy to array'] = function()
  local frontmatter = {
    title = 'Test Task',
    status = 'open',
    blockedBy = '/path/to/task.md',  -- String instead of array
  }

  local task = child.lua_get([[TaskManager.create_task_object('/test.md', ..., '')]], { frontmatter })

  eq(type(task.blockedBy), 'table')
  eq(#task.blockedBy, 1)
  eq(task.blockedBy[1], '/path/to/task.md')
end

-- Test dependency helper functions
T['get_blocking_tasks'] = new_set()

T['get_blocking_tasks']['returns empty array when not blocked'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Independent Task',
    status = 'open',
  })

  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local blocking = child.lua_get([[TaskManager.get_blocking_tasks(...)]], { task })

  eq(#blocking, 0)

  helpers.cleanup_vault(child, vault_path)
end

T['get_blocking_tasks']['finds blocking tasks'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  -- Create blocking task first
  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'open',
  })

  -- Create blocked task
  local blocked_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task',
    status = 'open',
    blockedBy = { blocking_path },
  })

  child.lua([[TaskManager.scan_vault()]])
  local blocked_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocked_path })
  local blocking_tasks = child.lua_get([[TaskManager.get_blocking_tasks(...)]], { blocked_task })

  eq(#blocking_tasks, 1)
  eq(blocking_tasks[1].title, 'Blocking Task')

  helpers.cleanup_vault(child, vault_path)
end

-- Test get_blocked_tasks
T['get_blocked_tasks'] = new_set()

T['get_blocked_tasks']['finds tasks that this task blocks'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  -- Create blocking task
  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'open',
  })

  -- Create multiple blocked tasks
  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task 1',
    status = 'open',
    blockedBy = { blocking_path },
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task 2',
    status = 'open',
    blockedBy = { blocking_path },
  })

  child.lua([[TaskManager.scan_vault()]])
  local blocking_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocking_path })
  local blocked_tasks = child.lua_get([[TaskManager.get_blocked_tasks(...)]], { blocking_task })

  eq(#blocked_tasks, 2)

  helpers.cleanup_vault(child, vault_path)
end

-- Test is_task_blocked
T['is_task_blocked'] = new_set()

T['is_task_blocked']['returns false for independent task'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Independent Task',
    status = 'open',
  })

  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local is_blocked = child.lua_get([[TaskManager.is_task_blocked(...)]], { task })

  eq(is_blocked, false)

  helpers.cleanup_vault(child, vault_path)
end

T['is_task_blocked']['returns true when blocked by incomplete task'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'open',  -- Not completed
  })

  local blocked_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task',
    status = 'open',
    blockedBy = { blocking_path },
  })

  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocked_path })
  local is_blocked = child.lua_get([[TaskManager.is_task_blocked(...)]], { task })

  eq(is_blocked, true)

  helpers.cleanup_vault(child, vault_path)
end

T['is_task_blocked']['returns false when blocked by completed task'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'done',  -- Completed
  })

  local blocked_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task',
    status = 'open',
    blockedBy = { blocking_path },
  })

  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocked_path })
  local is_blocked = child.lua_get([[TaskManager.is_task_blocked(...)]], { task })

  eq(is_blocked, false)

  helpers.cleanup_vault(child, vault_path)
end

-- Test circular dependency detection
T['validate_dependencies'] = new_set()

T['validate_dependencies']['accepts valid dependencies'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  local task_a_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task A',
    status = 'open',
  })

  local task_b_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task B',
    status = 'open',
    blockedBy = { task_a_path },
  })

  child.lua([[TaskManager.scan_vault()]])
  local task_b = child.lua_get([[TaskManager.get_task_by_path(...)]], { task_b_path })
  local is_valid = child.lua_get([[TaskManager.validate_dependencies(...)]], { task_b })

  eq(is_valid, true)

  helpers.cleanup_vault(child, vault_path)
end

T['validate_dependencies']['detects direct circular dependency'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  -- Create task A blocked by task B
  local task_a_path = vault_path .. '/task-a.md'
  local task_b_path = vault_path .. '/task-b.md'

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task A',
    status = 'open',
    blockedBy = { task_b_path },
  }, '', 'task-a.md')

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task B',
    status = 'open',
    blockedBy = { task_a_path },
  }, '', 'task-b.md')

  child.lua([[TaskManager.scan_vault()]])

  -- Try to validate task B (which would create circular dependency)
  local task_b = child.lua_get([[TaskManager.get_task_by_path(...)]], { task_b_path })
  local result = child.lua_get([[{TaskManager.validate_dependencies(...)}]], { task_b })

  eq(result[1], false)  -- Should be invalid

  helpers.cleanup_vault(child, vault_path)
end

T['validate_dependencies']['detects indirect circular dependency'] = function()
  local vault_path = helpers.create_test_vault(child)
  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))

  -- Create A -> B -> C -> A circular chain
  local task_a_path = vault_path .. '/task-a.md'
  local task_b_path = vault_path .. '/task-b.md'
  local task_c_path = vault_path .. '/task-c.md'

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task A',
    status = 'open',
    blockedBy = { task_c_path },
  }, '', 'task-a.md')

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task B',
    status = 'open',
    blockedBy = { task_a_path },
  }, '', 'task-b.md')

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Task C',
    status = 'open',
    blockedBy = { task_b_path },
  }, '', 'task-c.md')

  child.lua([[TaskManager.scan_vault()]])

  -- Validate task C (part of circular chain)
  local task_c = child.lua_get([[TaskManager.get_task_by_path(...)]], { task_c_path })
  local result = child.lua_get([[{TaskManager.validate_dependencies(...)}]], { task_c })

  eq(result[1], false)  -- Should detect circular dependency

  helpers.cleanup_vault(child, vault_path)
end

return T
