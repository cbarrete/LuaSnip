local tNode = require 'nodes.textNode'
local iNode = require 'nodes.insertNode'
local fNode = require 'nodes.functionNode'
local cNode = require 'nodes.choiceNode'
local dNode = require 'nodes.dynamicNode'
local snipNode = require 'nodes.snippet'
local functions = require 'util.functions'

local function is_escaped(text, indx)
	local count = 0
	for i = indx-1, 1, -1 do
		if string.sub(text, i, i) == '\\' then
			count = count + 1
		else
			break
		end
	end
	return count % 2 == 1
end

local function brckt_lst(text)
	local bracket_stack = {n=0}
	-- will contain key-value pairs, where key and value are indices of matching
	-- brackets.
	local final_list = {}
	for i = 1, #text do
		if string.sub(text, i, i) == "{" and not is_escaped(text, i) then
			bracket_stack.n = bracket_stack.n + 1
			bracket_stack[bracket_stack.n] = i
		elseif string.sub(text, i, i) == "}" and not is_escaped(text, i) then
			final_list[bracket_stack[bracket_stack.n]] = i
			bracket_stack.n = bracket_stack.n - 1
		end
	end

	return final_list
end

local function parse_text(text)
	-- Works for now, maybe a bit naive, but gsub behaviour shouldn't change I
	-- think...
	text = string.gsub(text, '\\\\', '\\')
	text = string.gsub(text, '\\{', '{')
	text = string.gsub(text, '\\}', '}')
	text = string.gsub(text, '\\,', ',')
	text = string.gsub(text, '\\|', '|')

	local text_table = {}
	for line in vim.gsplit(text, "\n", true) do
		text_table[#text_table+1] = line
	end
	return tNode.T(text_table)
end

local function simple_tabstop(text, tab_stops)
	local num = tonumber(text)
	if not num then return nil end
	if not tab_stops[num] then
		tab_stops[num] = iNode.I(num)
		return tab_stops[num]
	else
		local node = fNode.F(functions.copy, {tab_stops[num]})
		tab_stops[num].dependents[#tab_stops[num].dependents+1] = node
		return node
	end
end

-- Needed for eg. nested Placeholders, internal snippets don't have the first
-- num tabstops.
local function decrease_tabstops(snip, num)
	-- contains node with highest pos,
	local highest = {pos = 0}
	for i, node in ipairs(snip.nodes) do
		if node.pos then
			-- Remove automatically-inserted 0-ins. IF there is no other insert.
			if node.pos ~= 0 then
				node.pos = node.pos - num
			end

			if node.pos > highest.pos then
				highest = node
			end
		end
	end
	if highest.pos ~= 0 then
		highest.pos = 0
	end
end

local function brackets_offset(list, offset)
	local l_new = {}
	for k,v in pairs(list) do
		l_new[k+offset] = v + offset
	end
	return l_new
end

local parse_snippet

function parse_placeholder(text, tab_stops, brackets)
	local start, stop, match = string.find(text, "(%d+):")
	if start == 1 then
		local pos = tonumber(match)
		local snip = parse_snippet(nil, string.sub(text, stop+1, #text), tab_stops, brackets_offset(brackets, -stop))
		if snip then
			decrease_tabstops(snip, pos)
			tab_stops[pos] = cNode.C(pos, {snip, tNode.T({""})})
			return tab_stops[pos]
		end
	end
	return nil
end

local parse_functions={simple_tabstop, parse_placeholder, parse_choice, parse_variable, error}

parse_snippet = function(trigger, body, tab_stops, brackets)
	if not brackets then brackets = brckt_lst(body) end
	if not tab_stops then tab_stops = {} end

	local nodes = {}
	local indx = 1
	local text_start = 1

	while true do
		local next_node = string.find(body, "$", indx, true)
		if next_node then
			if not is_escaped(body, next_node) then
				-- insert text so far as textNode.
				local plain_text = string.sub(body, text_start, next_node - 1)
				if plain_text ~= "" then
					nodes[#nodes+1] = parse_text(plain_text)
				end

				-- potentially find matching bracket.
				local match_bracket = brackets[next_node+1]
				-- anything except text
				if match_bracket then
					-- nodestring excludes brackets.
					local nodestring = string.sub(body, next_node+2, match_bracket-1)
					local node
					for _, fn in ipairs(parse_functions) do
						node = fn(nodestring, tab_stops, brackets_offset(brackets, -(next_node+1)))
						if node then break end
					end
					nodes[#nodes+1] = node
					indx = match_bracket+1
				-- char after '$' is a number -> tabstop.
				elseif string.find(body, "%d", next_node+1) == next_node+1 then
					local _, last_char, match = string.find(body, "(%d+)", next_node+1)
					-- Add insert- or copy-function-node.
					nodes[#nodes+1] = simple_tabstop(match, tab_stops)
					indx = last_char+1
				elseif string.find(body, "%w", next_node+1) == next_node+1 then
					local _, last_char, match = string.find(body, "(%w+)", next_node+1)
					-- Add var-node
					nodes[#nodes+1] = simple_var(match, tab_stops)
					indx = last_char+1
				else
					error("Invalid text after $ at"..tostring(next_node+1))
				end
				text_start = indx
			else
				-- continues search at next node
				indx = next_node+1
				text_start = next_node+1
			end
		else
			-- insert text so far as textNode.
			local plain_text = string.sub(body, text_start, #body)
			if plain_text ~= "" then
				nodes[#nodes+1] = parse_text(plain_text)
			end
			-- append 0 if unspecified.
			if not tab_stops[0] then
				nodes[#nodes+1] = iNode.I(0)
			end
			return snipNode.S(trigger, nodes)
		end
	end
end

return {
	parse_snippet = parse_snippet
}