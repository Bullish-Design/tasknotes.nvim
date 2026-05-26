-- Test helpers for tasknotes.nvim
local Helpers = {}

-- Create a child Neovim instance for testing
Helpers.new_child_neovim = function()
  local child = MiniTest.new_child_neovim()

  child.setup = function()
    child.restart({ '-u', 'scripts/minimal_init.lua' })
    child.bo.readonly = false
  end

  return child
end

-- Helper to create a temporary test vault directory
Helpers.create_test_vault = function(child)
  local temp_dir = child.lua_get([[vim.fn.tempname()]])
  child.lua(string.format([[vim.fn.mkdir('%s', 'p')]], temp_dir))
  return temp_dir
end

-- Helper to create a test task file
-- @param child: MiniTest child instance
-- @param vault_path: path to vault directory
-- @param frontmatter: table of frontmatter fields
-- @param body: optional markdown body content
-- @param filename: optional custom filename (defaults to title-based)
-- @return filepath of created file
Helpers.create_test_task = function(child, vault_path, frontmatter, body, filename)
  local yaml_lines = { '---' }

  for k, v in pairs(frontmatter) do
    if type(v) == 'table' then
      table.insert(yaml_lines, k .. ':')
      for _, item in ipairs(v) do
        if type(item) == 'string' then
          table.insert(yaml_lines, '  - ' .. item)
        elseif type(item) == 'table' then
          -- Handle nested tables (like timeEntries)
          table.insert(yaml_lines, '  - ')
          for nested_k, nested_v in pairs(item) do
            table.insert(yaml_lines, '    ' .. nested_k .. ': ' .. tostring(nested_v))
          end
        end
      end
    else
      table.insert(yaml_lines, k .. ': ' .. tostring(v))
    end
  end

  table.insert(yaml_lines, '---')
  table.insert(yaml_lines, '')  -- Always add empty line after frontmatter (ensures newline)
  if body then
    table.insert(yaml_lines, body)
  end

  filename = filename or (frontmatter.title:gsub('%s+', '-'):lower() .. '.md')
  local filepath = vault_path .. '/' .. filename
  local content = table.concat(yaml_lines, '\n')

  child.lua(string.format([[
    local file = io.open('%s', 'w')
    if file then
      file:write(%q)
      file:close()
    end
  ]], filepath, content))

  return filepath
end

-- Helper to read file contents from child
Helpers.read_file = function(child, filepath)
  return child.lua_get(string.format([[
    local file = io.open('%s', 'r')
    if not file then return nil end
    local content = file:read('*all')
    file:close()
    return content
  ]], filepath))
end

-- Helper to clean up temporary vault
Helpers.cleanup_vault = function(child, vault_path)
  child.lua(string.format([[
    vim.fn.delete('%s', 'rf')
  ]], vault_path))
end

return Helpers
