local source = require("blink-cmp-stardict")
local dict = require("blink-cmp-stardict.dict")
local format = require("blink-cmp-stardict.format")

local function new_source(opts, config)
	return source.new(opts or {}, config or {})
end

--- Mimic the real blink.cmp context interface used by the source
local function ctx(word)
	return {
		get_keyword = function()
			return word
		end,
	}
end

--- Wait until fn() returns true (async callbacks are scheduled)
local function await(fn)
	vim.wait(2000, fn, 10)
end

-- ── Fixture helpers ────────────────────────────────────────────

local function be32(x)
	return string.char(
		math.floor(x / 16777216) % 256,
		math.floor(x / 65536) % 256,
		math.floor(x / 256) % 256,
		x % 256
	)
end

--- Write a minimal stardict dictionary (.ifo + .idx + .dict) into dir
local function write_fixture_dict(dir, bookname, words, sametypesequence)
	vim.fn.mkdir(dir, "p")
	sametypesequence = sametypesequence or "m"
	local f = assert(io.open(dir .. "/fixture.ifo", "wb"))
	f:write(
		"StarDict's dict ifo file\nversion=3.0.0\nbookname="
			.. bookname
			.. "\nwordcount="
			.. #words
			.. "\nidxfilesize=0\nsametypesequence="
			.. sametypesequence
			.. "\n"
	)
	f:close()

	local parts = {}
	local off = 0
	local dict_data = {}
	for _, w in ipairs(words) do
		local definition = "definition of " .. w
		parts[#parts + 1] = w .. "\0" .. be32(off) .. be32(#definition)
		dict_data[#dict_data + 1] = definition
		off = off + #definition
	end
	local g = assert(io.open(dir .. "/fixture.idx", "wb"))
	g:write(table.concat(parts))
	g:close()
	local h = assert(io.open(dir .. "/fixture.dict", "wb"))
	h:write(table.concat(dict_data))
	h:close()
end

--- Create a source backed by fixture dictionaries, loaded synchronously
local function fixture_source(dict_words, opts, config)
	local tmp = vim.fn.tempname()
	for name, words in pairs(dict_words) do
		write_fixture_dict(tmp .. "/" .. name, name, words)
	end
	opts = vim.tbl_deep_extend("force", { dict_dirs = { tmp } }, opts or {})
	local s = source.new(opts, config or {})
	for _, d in ipairs(s._dicts) do
		assert.is_true(dict.load_sync(d))
	end
	return s, tmp
end

describe("blink-cmp-stardict", function()
	-- ── Source Creation ──────────────────────────────────────────

	describe("source.new", function()
		it("creates a source instance", function()
			local s = new_source()
			assert.is_table(s)
		end)

		it("has default opts", function()
			local s = new_source()
			assert.equals(3, s.opts.min_chars)
			assert.equals(100, s.opts.max_items)
			assert.is_true(s.opts.ansi_colors)
		end)

		it("merges user opts", function()
			local s = source.new({ min_chars = 5, ansi_colors = true }, {})
			assert.equals(5, s.opts.min_chars)
			assert.is_true(s.opts.ansi_colors)
		end)

		it("has required methods", function()
			local s = new_source()
			assert.is_function(s.get_completions)
			assert.is_function(s.resolve)
			assert.is_function(s.get_trigger_characters)
			assert.is_function(s.enabled)
		end)
	end)

	-- ── enabled ──────────────────────────────────────────────────

	describe("enabled", function()
		it("returns false when no dictionaries are found", function()
			local s = source.new({ dict_dirs = { vim.fn.tempname() } }, {})
			assert.is_false(s:enabled())
		end)

		it("returns true when dictionaries are discovered", function()
			local s = fixture_source({ TestDict = { "apple" } })
			assert.is_true(s:enabled())
		end)
	end)

	-- ── Trigger Characters ───────────────────────────────────────

	describe("get_trigger_characters", function()
		it("returns empty (relies on keyword triggering)", function()
			assert.same({}, new_source():get_trigger_characters())
		end)
	end)

	-- ── get_completions ──────────────────────────────────────────

	describe("get_completions", function()
		it("returns empty for prefix shorter than min_chars", function()
			local s = source.new({ min_chars = 3 }, {})
			local called = false
			s:get_completions(ctx("ab"), function(response)
				called = true
				assert.is_table(response)
				assert.equals(0, #response.items)
				-- must be marked incomplete so blink.cmp re-asks as the
				-- keyword grows past min_chars
				assert.is_true(response.is_incomplete_forward)
			end)
			assert.is_true(called)
		end)

		it("returns empty for nil prefix", function()
			local called = false
			new_source():get_completions(ctx(nil), function(response)
				called = true
				assert.equals(0, #response.items)
			end)
			assert.is_true(called)
		end)

		it("respects provider min_keyword_length over min_chars", function()
			local s = source.new({ min_chars = 2 }, { min_keyword_length = 5 })
			local called = false
			s:get_completions(ctx("abcd"), function(response)
				called = true
				assert.equals(0, #response.items)
			end)
			assert.is_true(called)
		end)

		it("accepts min_keyword_length as a function", function()
			local s = source.new({ min_chars = 2 }, {
				min_keyword_length = function()
					return 5
				end,
			})
			local called = false
			s:get_completions(ctx("abcd"), function(response)
				called = true
				assert.equals(0, #response.items)
			end)
			assert.is_true(called)
		end)
	end)

	-- ── get_completions with fixture dictionaries ────────────────

	describe("get_completions with local index", function()
		local words = {
			"apple",
			"Apple pie",
			"applecart",
			"applesauce",
			"application",
			"banana",
			"Hello",
			"hello",
			"world",
		}

		it("returns prefix matches from the local index", function()
			local s = fixture_source({ TestDict = words })
			local resp
			s:get_completions(ctx("appl"), function(r)
				resp = r
			end)
			local labels = {}
			for _, item in ipairs(resp.items) do
				labels[#labels + 1] = item.label
			end
			assert.same({ "apple", "Apple pie", "applecart", "applesauce", "application" }, labels)
		end)

		it("matches case-insensitively", function()
			local s = fixture_source({ TestDict = words })
			local resp
			s:get_completions(ctx("APPL"), function(r)
				resp = r
			end)
			assert.is_true(#resp.items >= 4)
		end)

		it("respects max_items", function()
			local s = fixture_source({ TestDict = words }, { max_items = 2 })
			local resp
			s:get_completions(ctx("appl"), function(r)
				resp = r
			end)
			assert.equals(2, #resp.items)
		end)

		it("returns empty when nothing matches", function()
			local s = fixture_source({ TestDict = words })
			local resp
			s:get_completions(ctx("zzz"), function(r)
				resp = r
			end)
			assert.equals(0, #resp.items)
		end)

		it("deduplicates the same word across dictionaries", function()
			local s = fixture_source({
				DictA = { "apple", "banana" },
				DictB = { "apple", "cherry" },
			})
			local resp
			s:get_completions(ctx("app"), function(r)
				resp = r
			end)
			assert.equals(1, #resp.items)
			assert.equals("apple", resp.items[1].label)
		end)

		it("round-robin merges so small dictionaries stay visible", function()
			local s = fixture_source({
				DictA = { "app1", "app2", "app3", "app4", "app5" },
				DictB = { "appx" },
			}, { max_items = 3 })
			local resp
			s:get_completions(ctx("app"), function(r)
				resp = r
			end)
			local labels = {}
			for _, item in ipairs(resp.items) do
				labels[#labels + 1] = item.label
			end
			assert.same({ "app1", "appx", "app2" }, labels)
		end)

		it("defers the callback while dictionaries are still loading", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/TestDict", "TestDict", { "apple" })
			local s = source.new({ dict_dirs = { tmp } }, {})
			local still_loading = false
			for _, d in ipairs(s._dicts) do
				if d.status ~= "ready" then
					still_loading = true
				end
			end
			if still_loading then
				local resp
				s:get_completions(ctx("app"), function(r)
					resp = r
				end)
				-- callback is deferred until all dictionaries are ready
				assert.is_nil(resp)
				await(function()
					for _, d in ipairs(s._dicts) do
						if d.status ~= "ready" then
							return false
						end
					end
					return true
				end)
				assert.equals(1, #resp.items)
				assert.equals("apple", resp.items[1].label)
			end
		end)

		it("loads dictionaries asynchronously and then completes", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/TestDict", "TestDict", { "apple", "application" })
			local s = source.new({ dict_dirs = { tmp } }, {})
			await(function()
				for _, d in ipairs(s._dicts) do
					if d.status ~= "ready" then
						return false
					end
				end
				return true
			end)
			local resp
			s:get_completions(ctx("appl"), function(r)
				resp = r
			end)
			assert.equals(2, #resp.items)
		end)
	end)

	-- ── dict module ──────────────────────────────────────────────

	describe("dict module", function()
		it("parses bookname from ifo", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp, "MyDict", { "apple" })
			local name, idx_path = dict.parse_ifo(tmp .. "/fixture.ifo")
			assert.equals("MyDict", name)
			assert.is_truthy(idx_path:find("fixture.idx"))
		end)

		it("discovers dictionaries in subdirectories", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/english", "English", { "apple" })
			write_fixture_dict(tmp .. "/chinese", "Chinese", { "apple" })
			local found = dict.discover({ tmp })
			assert.equals(2, #found)
		end)

		it("discovers dictionaries recursively", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/root", "Root", { "apple" })
			write_fixture_dict(tmp .. "/a/b/c", "Nested", { "apple" })
			local found = dict.discover({ tmp })
			assert.equals(2, #found)
		end)

		it("discovers across multiple dict_dirs", function()
			local tmp1 = vim.fn.tempname()
			local tmp2 = vim.fn.tempname()
			write_fixture_dict(tmp1 .. "/a", "DictA", { "apple" })
			write_fixture_dict(tmp2 .. "/b", "DictB", { "apple" })
			local found = dict.discover({ tmp1, tmp2 })
			assert.equals(2, #found)
		end)

		it("discovers only included booknames", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/a", "DictA", { "apple" })
			write_fixture_dict(tmp .. "/b", "DictB", { "apple" })
			local found = dict.discover({ tmp }, { include = { "DictB" } })
			assert.equals(1, #found)
			assert.equals("DictB", found[1].name)
		end)

		it("excludes booknames", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/a", "DictA", { "apple" })
			write_fixture_dict(tmp .. "/b", "DictB", { "apple" })
			local found = dict.discover({ tmp }, { exclude = { "DictA" } })
			assert.equals(1, #found)
			assert.equals("DictB", found[1].name)
		end)

		it("exclude wins over include", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp .. "/a", "DictA", { "apple" })
			write_fixture_dict(tmp .. "/b", "DictB", { "apple" })
			local found = dict.discover({ tmp }, { include = { "DictA", "DictB" }, exclude = { "DictB" } })
			assert.equals(1, #found)
			assert.equals("DictA", found[1].name)
		end)

		it("handles words with spaces and hyphens", function()
			local s = fixture_source({ TestDict = { "apple pie", "apple-pie", "applejack" } })
			local resp
			s:get_completions(ctx("apple"), function(r)
				resp = r
			end)
			assert.equals(3, #resp.items)
		end)

		it("reads definitions from .dict file", function()
			local tmp = vim.fn.tempname()
			write_fixture_dict(tmp, "TestDict", { "apple" })
			local found = dict.discover({ tmp })
			assert.is_true(dict.load_sync(found[1]))
			local data = dict.get_definition(found[1], "apple")
			assert.equals("definition of apple", data)
		end)
	end)

	-- ── resolve ──────────────────────────────────────────────────

	describe("resolve", function()
		it("returns item unchanged when data is nil", function()
			local item = { label = "test" }
			local called = false
			new_source():resolve(item, function(resolved)
				called = true
				assert.equals("test", resolved.label)
				assert.is_nil(resolved.documentation)
			end)
			assert.is_true(called)
		end)

		it("returns item unchanged when data.word is nil", function()
			local item = { label = "test", data = {} }
			local called = false
			new_source():resolve(item, function(resolved)
				called = true
				assert.equals("test", resolved.label)
			end)
			assert.is_true(called)
		end)

		it("resolves documentation from fixture dictionary", function()
			local s = fixture_source({ TestDict = { "apple" } })
			local item = { label = "apple", data = { word = "apple" } }
			local resolved
			s:resolve(item, function(r)
				resolved = r
			end)
			assert.is_not_nil(resolved.documentation)
			assert.equals("markdown", resolved.documentation.kind)
			assert.is_truthy(resolved.documentation.value:find("definition of apple", 1, true))
		end)
	end)

	-- ── format module ────────────────────────────────────────────

	describe("format module", function()
		it("strips ANSI codes by default", function()
			local md = format.to_markdown("\27[32mgreen\27[0m text", "m", {})
			assert.is_nil(md:find("\27", 1, true))
			assert.is_truthy(md:find("green text", 1, true))
		end)

		it("extracts ANSI spans when ansi_colors is enabled", function()
			local md, spans = format.to_markdown("\27[32mgreen\27[0m text", "m", { ansi_colors = true })
			assert.is_nil(md:find("\27", 1, true))
			assert.is_truthy(md:find("green text", 1, true))
			assert.is_table(spans)
			assert.equals(1, #spans)
			assert.equals(0, spans[1].row)
			assert.equals(0, spans[1].col_start)
			assert.equals(5, spans[1].col_end)
			assert.same({ "BlinkCmpStardictAnsiFg2" }, spans[1].groups)
		end)

		it("tracks ANSI span positions across lines", function()
			local md, spans = format.to_markdown("plain\n\27[31mred line\27[0m", "m", { ansi_colors = true })
			assert.is_nil(md:find("\27", 1, true))
			assert.equals(1, #spans)
			assert.equals(1, spans[1].row)
			assert.equals(0, spans[1].col_start)
			assert.equals(8, spans[1].col_end)
			assert.same({ "BlinkCmpStardictAnsiFg1" }, spans[1].groups)
		end)

		it("resets style on SGR 0", function()
			local _, spans = format.to_markdown("\27[1m\27[32mboldgreen\27[0mplain", "m", { ansi_colors = true })
			assert.equals(1, #spans)
			assert.same({ "BlinkCmpStardictAnsiFg2", "BlinkCmpStardictAnsiBold" }, spans[1].groups)
		end)

		it("offsets spans per dictionary in combine", function()
			local text, spans = format.combine({
				{ name = "DictA", definition = "def A", spans = { { row = 0, col_start = 1, col_end = 3, groups = { "X" } } } },
				{ name = "DictB", definition = "def B", spans = { { row = 0, col_start = 0, col_end = 2, groups = { "Y" } } } },
			})
			assert.is_truthy(text:find("## DictA", 1, true))
			assert.is_truthy(text:find("## DictB", 1, true))
			assert.equals(2, #spans)
			-- DictA definition starts at row 2; DictB definition at row 6
			assert.equals(2, spans[1].row)
			assert.equals(6, spans[2].row)
			assert.equals(1, spans[1].col_start)
		end)

		it("converts HTML to markdown", function()
			local md = format.to_markdown("<b>bold</b><br><i>italic</i>", "h", {})
			assert.is_truthy(md:find("%*%*bold%*%*", 1))
			assert.is_truthy(md:find("%*italic%*", 1))
		end)

		it("combines multiple dictionaries", function()
			local combined = format.combine({
				{ name = "DictA", definition = "def A" },
				{ name = "DictB", definition = "def B" },
			})
			assert.is_truthy(combined:find("## DictA", 1, true))
			assert.is_truthy(combined:find("## DictB", 1, true))
			assert.is_truthy(combined:find("def A", 1, true))
			assert.is_truthy(combined:find("def B", 1, true))
		end)
	end)

	-- ── resolve with real dictionaries ───────────────────────────

	describe("resolve with real dictionaries", function()
		it("finds wordnet and resolves a definition", function()
			local dirs = { "C:\\Users\\市内免税提货点\\.stardict\\dic" }
			local dicts = dict.discover(dirs, { include = { "WordNet" } })
			assert.is_true(#dicts > 0)

			local d = dicts[1]
			assert.is_true(dict.load_sync(d))
			assert.is_true(d.n > 100000)

			local matches = dict.prefix_search(d, "apple", 5)
			assert.is_true(#matches > 0)

			local data = dict.get_definition(d, matches[1])
			assert.is_not_nil(data)
			assert.is_true(#data > 0)

			local md = format.to_markdown(data, d.sametypesequence, { ansi_colors = false })
			assert.is_truthy(md:find("fruit", 1, true))
		end)
	end)
end)
