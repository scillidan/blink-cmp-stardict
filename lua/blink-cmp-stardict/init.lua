--- StarDict / sdcv completion source for blink.cmp.
--- Completion: instant case-insensitive prefix search over local .idx files.
--- Resolve: read .dict directly (no external sdcv dependency).
--- @module blink-cmp-stardict

local dict = require("blink-cmp-stardict.dict")
local format = require("blink-cmp-stardict.format")

--- @class blink-cmp-stardict.Options
--- @field dict_dirs? string[] Directories scanned recursively for stardict dictionaries (default: ~/.stardict/dic, /usr/share/stardict/dic)
--- @field include_dictionaries? string[] Only enable these booknames (default: all discovered)
--- @field exclude_dictionaries? string[] Disable these booknames (wins over include)
--- @field dictionaries? string[] Deprecated alias of include_dictionaries
--- @field max_items? integer Maximum completion items per query (default: 100)
--- @field min_chars? integer Minimum prefix length in bytes — 1 CJK char (3 bytes in UTF-8) already satisfies 3; overridden by the provider's min_keyword_length (default: 3)
--- @field ansi_colors? boolean Render ANSI colors as highlights in documentation (default: true)

--- @class blink.cmp.Source
local source = {}

-- Hoisted at module load: accessing vim.lsp.protocol lazily inside a
-- vim.system fast-event callback can trigger a failing require (E5560)
local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

--- @param opts blink-cmp-stardict.Options Configuration options
--- @param config? blink.cmp.SourceProviderConfig
--- @return blink.cmp.Source
function source.new(opts, config)
	local self = setmetatable({}, { __index = source })
	self.opts = vim.tbl_deep_extend("keep", opts or {}, {
		dict_dirs = nil,
		include_dictionaries = nil,
		exclude_dictionaries = nil,
		dictionaries = nil,
		max_items = 100,
		min_chars = 3,
		ansi_colors = true,
	})
	self._provider_config = config or {}

	local dirs = self.opts.dict_dirs or { "~/.stardict/dic", "/usr/share/stardict/dic" }
	self._dicts = dict.discover(dirs, {
		include = self.opts.include_dictionaries or self.opts.dictionaries,
		exclude = self.opts.exclude_dictionaries,
	})

	-- Load indexes in scheduled chunks; completion requests made while
	-- loading are deferred until every dictionary is ready (or failed)
	self._ready_listeners = {}
	local remaining = #self._dicts
	for _, d in ipairs(self._dicts) do
		dict.load_async(d, function()
			remaining = remaining - 1
			if remaining == 0 then
				local listeners = self._ready_listeners
				self._ready_listeners = {}
				for _, cb in ipairs(listeners) do
					cb()
				end
			end
		end)
	end

	return self
end

--- @return boolean true when no dictionary is still loading
local function all_loaded(self)
	for _, d in ipairs(self._dicts) do
		if d.status ~= "ready" and d.status ~= "failed" then
			return false
		end
	end
	return true
end

--- @return boolean
function source:enabled()
	return #self._dicts > 0
end

--- Rely on blink.cmp's keyword triggering; no extra trigger characters needed.
--- @return string[]
function source:get_trigger_characters()
	return {}
end

--- Collect prefix matches from every ready dictionary, round-robin merged
--- so one huge dictionary can't crowd out the others
--- @param self blink.cmp.Source
--- @param prefix string
--- @return blink.cmp.CompletionItem[]
local function build_items(self, prefix)
	local per_dict = {}
	for _, d in ipairs(self._dicts) do
		if d.status == "ready" then
			per_dict[#per_dict + 1] = dict.prefix_search(d, prefix, self.opts.max_items)
		end
	end

	local items = {}
	local seen = {}
	local i = 1
	local added = true
	while added and #items < self.opts.max_items do
		added = false
		for _, words in ipairs(per_dict) do
			local word = words[i]
			if word then
				added = true
				if not seen[word] then
					seen[word] = true
					table.insert(items, {
						label = word,
						kind = CompletionItemKind.Text,
						insertText = word,
						data = { word = word },
					})
					if #items >= self.opts.max_items then
						break
					end
				end
			end
		end
		i = i + 1
	end
	return items
end

--- @param ctx blink.cmp.Context
--- @param callback fun(response: blink.cmp.CompletionResponse)
function source:get_completions(ctx, callback)
	local prefix = ctx:get_keyword()
	local min_chars = self.opts.min_chars
	local provider_min = self._provider_config.min_keyword_length
	if type(provider_min) == "function" then
		provider_min = provider_min(ctx)
	end
	if type(provider_min) == "number" then
		min_chars = provider_min
	end

	if not prefix or #prefix < min_chars then
		-- must stay "incomplete": a complete empty response here would be
		-- cached by blink.cmp for the rest of this keyword session
		callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
		return
	end

	local function respond()
		-- always incomplete: results are truncated at max_items, so blink.cmp
		-- must re-ask as the keyword changes instead of filtering a stale cache
		callback({
			items = build_items(self, prefix),
			is_incomplete_forward = true,
			is_incomplete_backward = true,
		})
	end

	-- Answering with a "complete" empty list while dictionaries are still
	-- loading would make blink.cmp cache it and never re-ask this source
	if all_loaded(self) then
		respond()
	else
		table.insert(self._ready_listeners, respond)
	end
end

--- @param item blink.cmp.CompletionItem
--- @param callback fun(resolved_item?: blink.cmp.CompletionItem)
function source:resolve(item, callback)
	if not item.data or not item.data.word then
		callback(item)
		return
	end

	local word = item.data.word

	local entries = {}
	for _, d in ipairs(self._dicts) do
		if d.status == "ready" then
			local data = dict.get_definition(d, word)
			if data then
				local md, spans = format.to_markdown(data, d.sametypesequence, {
					ansi_colors = self.opts.ansi_colors,
				})
				table.insert(entries, { name = d.name, definition = md, spans = spans })
			end
		end
	end

	if #entries > 0 then
		local text, spans = format.combine(entries)
		item.documentation = {
			kind = "markdown",
			value = text,
		}
		if spans and #spans > 0 then
			-- blink.cmp per-item draw override: render normally, then colorize
			item.documentation.draw = function(o)
				o.default_implementation()
				format.apply_ansi_spans(o.window:get_buf(), spans)
			end
		end
	end

	callback(item)
end

--- @param ctx blink.cmp.Context
--- @param item blink.cmp.CompletionItem
--- @param callback fun()
--- @param default_implementation fun()
function source:execute(ctx, item, callback, default_implementation)
	default_implementation()
	callback()
end

return source
