local os = require("os")
local string = require("string")
local table = require("table")

local log = require("sofa.log")
local pickers = require("sofa.pickers")
local utils = require("sofa.utils")

local fuzzel = {}

local NUL_SEPARATOR = "\0"
local FIELD_SEPARATOR = "\x1f"
local COMMAND_SEPARATOR = " > "

---@class Fuzzel: AbstractPicker
---@field private default_options string
local Fuzzel = pickers.AbstractPicker:new({})

---create a new fuzzel picker based on configuration
---@param config table
---@return Fuzzel
function Fuzzel:new(config)
  -- local o = {}
  local o = config.pickers.fuzzel
  setmetatable(o, self)
  self.__index = self
  return o
end

local function add_options(cmd, options)
  local cmd_parts = { cmd }
  if options.mesg then
    local mesg = utils.escape_quotes(options.mesg)
    -- cmd_parts[#cmd_parts + 1] = string.format("-mesg '%s'", mesg)
    cmd_parts[#cmd_parts + 1] = string.format("--placeholder='%s'", mesg)
    -- cmd_parts[#cmd_parts + 1] = string.format("'%s '", mesg)
  end
  -- if options.case_insensitive then
  --   cmd_parts[#cmd_parts + 1] = "-i"
  -- end
  -- if options.no_custom then
  --   cmd_parts[#cmd_parts + 1] = "-no-custom"
  -- end
  -- if options.markup then
  --   cmd_parts[#cmd_parts + 1] = "-markup-rows"
  -- end
  if options.default then
    local default = utils.escape_quotes(options.default)
    cmd_parts[#cmd_parts + 1] = string.format("--select '%s'", default)
  end
  return table.concat(cmd_parts, " ")
end

function Fuzzel:_pick_from_cmd(prompt, choices_cmd, options)
  prompt = utils.escape_quotes(prompt)
  local cmd = string.format("%s | fuzzel %s --dmenu -p '%s '", choices_cmd, self.default_options, prompt)
  local command = add_options(cmd, options)
  local status_code, response = utils.run(command)
  if status_code ~= 0 then
    log:log("fuzzel: abort triggered")
    os.exit(1)
  end
  return utils.trim_whitespace(response)
end

function Fuzzel:_pick(prompt, choices, options)
  local content = table.concat(choices, "\n")
  local filename, delete = utils.write_to_tmp(content)
  prompt = utils.escape_quotes(prompt)
  local cmd = string.format("fuzzel %s --dmenu < '%s' -p '%s '", self.default_options, filename, prompt)
  local command = add_options(cmd, options)
  local status_code, response = utils.run(command)
  delete()
  if status_code ~= 0 then
    log:log("fuzzel: abort triggered")
    os.exit(1)
  end
  return utils.trim_whitespace(response)
end

---add options to a row
---@param row string
---@param options { [string]: any }
---@return string                                          l
function Fuzzel:_add_row_options(row, options)
  local res = {}
  for k, v in pairs(options) do
    res[#res + 1] = k .. FIELD_SEPARATOR .. tostring(v)
  end
  return row .. NUL_SEPARATOR .. table.concat(res, FIELD_SEPARATOR)
end

---return the command that the user picked
---@param namespaces { [string]: Namespace }
---@param interactive boolean
---@return Command
function Fuzzel:pick_command(namespaces, interactive)
  local choices = {}
  for ns_name, ns in pairs(namespaces) do
    for cmd_name, cmd in pairs(ns:get_commands(interactive)) do
      local tags = table.concat(cmd.tags, " ")
      local options = {}
      if tags then
        options.meta = tags
      end
      local choice = string.format("%s%s%s", ns_name, COMMAND_SEPARATOR, cmd_name)
      if cmd.description then
        choice = choice .. string.format(" < (%s)", cmd.description)
      end
      choices[#choices + 1] = self:_add_row_options(choice, options)
    end
  end
  if #choices == 0 then
    log:log("fuzzel: no commands configured")
    os.exit(1)
  end
  local pick = self:_pick("Command", choices, { no_custom = true, case_insensitive = true, markup = true })
  local namespace, command = pick:match("^(.+)" .. COMMAND_SEPARATOR .. "(.+) <")
  if not namespace then
    namespace, command = pick:match("^(.+)" .. COMMAND_SEPARATOR .. "(.+)$")
  end
  return namespaces[namespace]:get_commands(interactive)[command]
end

---returns markup defined choices for a parmaters based on `choices` field
---@param parameter Parameter
---@return string[]
function Fuzzel:_get_choices_for_param(parameter)
  local choices = parameter:get_choices()
  local markup_choices = {}
  for _, choice in ipairs(choices) do
    local substitute = parameter:get_mapped_value(choice)
    if substitute == choice then
      markup_choices[#markup_choices + 1] = choice
    else
      markup_choices[#markup_choices + 1] =
        string.format('%s <span size="small"><i>(%s)</i></span>', choice, substitute)
    end
  end
  return markup_choices
end

---return the value for a pick given a parameter
---@param parameter Parameter
---@param pick string
---@return string
function Fuzzel:_get_value_for_pick(parameter, pick)
  local default = parameter:get_default()
  local choice = pick:match("^(.+) <span") or pick
  if choice == "" and default then
    choice = default
  end
  return parameter:get_mapped_value(choice)
end

---returns the value of a parameter, is passed a list of previous parameter values if dependent on them
---@param parameter Parameter
---@param command string
---@param params { [string]: string }
---@return string
function Fuzzel:pick_parameter(parameter, command, params)
  local sub = string.format("{{ %s }}", parameter.name)
  local default = parameter:get_default()
  if default then
    sub = default
  end
  command = command:gsub(
    string.format("{{%%s*%s%%s*}}", parameter.name),
    -- string.format('<span foreground="red">%s</span>', sub)
    string.format("%s", sub)
  )
  local options = {
    markup = true,
    no_custom = parameter.exclusive,
    default = parameter:get_default(),
    case_insensitive = true,
    mesg = "Command: " .. command,
  }
  local pick = nil
  local prompt = parameter.prompt
  if parameter:is_command() then
    pick = self:_pick_from_cmd(prompt, parameter:get_command(params), options)
  else
    local choices = self:_get_choices_for_param(parameter)
    pick = self:_pick(prompt, choices, options)
  end
  return self:_get_value_for_pick(parameter, pick)
end

fuzzel.Fuzzel = Fuzzel

---builder
function fuzzel.new(config)
  return Fuzzel:new(config)
end

return fuzzel
