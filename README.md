# blink-cmp-stardict

Word completion and definitions from local [StarDict](https://github.com/huzheng001/stardict-3) dictionaries.

Authors: Kimi-K3🧙‍♂️, scillidan🤡

- Instant case-insensitive prefix search over the dictionary's `.idx` index (pure Lua, no `sdcv` binary needed)
- Definitions rendered as markdown in the documentation window
- Handles `sametypesequence=m` (plain / sdcv-style text with ANSI colors, rendered as real highlights) and `h` (HTML → markdown)
- Dictionaries load asynchronously; Neovim never blocks

## Requirements

- [Neovim](https://github.com/neovim/neovim) + [blink.cmp](https://github.com/Saghen/blink.cmp)
- StarDict dictionaries (`.ifo` + `.idx` + `.dict`)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
	"saghen/blink.cmp",
	dependencies = { "your-name/blink-cmp-stardict" },
	opts = {
		sources = {
			default = { "lsp", "path", "stardict" },
			providers = {
				stardict = {
					name = "stardict",
					module = "blink-cmp-stardict",
					opts = {
						-- Required. StarDict .ifo/.idx/.dict files:
						--   Linux: ~/.stardict/dic, /usr/share/stardict/dic
						--   Windows: custom path with your dictionaries
						dict_dirs = { "~/.stardict/dic" },

						-- include_dictionaries = { "WordNet", "CC-CEDICT" },
						-- exclude_dictionaries = { "GCIDE" },

						max_items = 100,
						min_chars = 3,
						ansi_colors = true,
					},
				},
			},
			per_filetype = {
				text = { "stardict" },
				markdown = { "stardict" },
			},
		},
	},
}
```

## Dictionaries

Only the `.idx` index is kept in memory; definitions are read from `.dict` on demand, so large dictionaries (CC-CEDICT ≈ 500k entries) stay cheap.

## Testing

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim):

```sh
make test
```

## Related projects

- [blink-cmp-words](https://github.com/archie-judd/blink-cmp-words) — WordNet-based dictionary & thesaurus source this project is modeled after
- [sdcv](https://dushistov.github.io/sdcv/) — console version of StarDict
- [sdcv-windows-build](https://github.com/scillidan/sdcv-windows-build) — Native MinGW64 build of sdcv, with runtime DLLs bundled
