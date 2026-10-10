# tree-sitter-bend2

Tree-sitter grammar for **Bend 2**, with Neovim highlighting, folding,
indentation, textobjects, locals, symbol tags and treesitter-context queries.
This is **not** the older Bend/HVM language grammar.

Parser version: **0.2.0** (ABI 15).
Syntax reference: Bend **2.0.35**, release tag **`v2.0.35`**, specifically
[`bend2/bend.ts` at `79df8d9c`](https://github.com/bendlang/bend/blob/79df8d9c40722ee9507a1e253f283b51025f9d6c/bend2/bend.ts).
See the [release audit](docs/upgrades/bend-2.0.35.md) for every upstream change,
old/new parser results, and the distinction between this tag and later `main`.

## Installation

See the [Neovim installation guide](docs/neovim.md) for a complete **lazy.nvim /
nvim-treesitter main** setup, HTTPS GitHub installation, optional local checkouts,
legacy `master`, manual installation, editor features and troubleshooting.

For an already-configured `main` setup, see the short registration example below.

## Build and test (offline)

Requires a C compiler and Tree-sitter CLI **0.26.9** (used for development).
Generated ABI-15 sources are included, so consumers need not generate the parser.
Node is needed for the upstream sweep; Neovim is needed for editor tests.
The upstream sweep expects the Bend checkout in a sibling directory named
`bend` (`../bend` relative to this repository). You can pass a different checkout
path to `scripts/validate-upstream.mjs`. Corpus and Neovim tests do not require
the Bend checkout.

These commands use installed tools; no npm installation is necessary:

```sh
tree-sitter generate
tree-sitter test
tree-sitter build -o build/bend2.so
nvim --headless -u NONE -l scripts/test-neovim.lua
nvim --headless -u NONE -l scripts/test-recovery.lua
node scripts/validate-upstream.mjs ../bend
```

Equivalent npm scripts: `generate`, `test`, `test:neovim`, `test:recovery`,
`test:upstream`. Additional gates: `test:scanner`, `test:upgrade`, `test:stdlib`
and `test:release`. `npm run test:offline` runs the installed-tool gates,
including the full upstream sweep; it does not install dependencies or run the
separate binding suites.
`npm run test:docs` checks the installation snippets in a temporary Neovim
runtime without network access or changes to user configuration. It requires an
installed main-branch nvim-treesitter checkout; set `BEND2_NVIM_TREESITTER` to its
path if it is not under `stdpath('data') .. '/lazy/nvim-treesitter'`.
`test:bindings` retains the scaffold's Node binding test, requiring its npm
dependencies to be installed separately.

### Validation results

On the integrated parser, using the existing 10-second per-file deadline:

- **1,644 / 1,644 `.bend` files visited**, with a per-file timeout.
- **1,522 clean parse results**, including the entire 3,009-line standard library,
  all demos and the completed non-diagnostic fixtures.
- **122 reviewed syntax rejections**, pinned in `test/upstream-rejections.json`. These contain
  malformed or removed syntax. Some upstream goldens stop at an *earlier*
  semantic error, so “expects an error” alone is not used as an exemption.
- **41 corpus cases**, covering tree shape, precedence, column ownership,
  literals, proofs, do notation, templates, parallel lets, arrays and rejection.
- All seven queries compile in Neovim **0.12.1**; captures, folds, conventional
  indentation and **180 deterministic incremental edits** are checked.
- **104 declaration-recovery scenarios** check error locality and retained
  highlight captures; **36 sibling-arm scenarios** also preserve intact
  `case_clause` fields and highlight/fold/context/textobject/local/indent captures
  after missing call/constructor closers (including calls in let values),
  mistyped GPU openers and nested match boundaries. Malformed case-header
  controls preserve the demonstrated intact neighbors.
  **5 other damaged-match scenarios** check consistency and repair only.
  Scenarios are broken and repaired twice using minimal buffer edits, comparing
  complete node types/ranges against fresh parses. LF/CRLF and valid multiline
  strings containing case-looking text are checked. Suffix/type-argument cases
  check edited-function fields and captures from all seven query groups.
  Invalid nested `do` bodies additionally check following definition/type/law
  recovery with LF and CRLF, including an immediately following `@unsafe`
  definition. Exact fields, ranges, highlights, tags, folds and textobjects are
  checked for retained definitions and arms. Delimiter-ownership regressions
  and six valid nested-GPU controls cover differently indented closers without
  imposing an alignment rule. This does not make ordinary lets or `match` inside
  `do` valid Bend, or guarantee preservation of the damaged function itself.
  Damaged parallel-let values retain their following definition. Invalid
  call/index assignment targets retain the edited function's header and clean
  terminal integer body/capture, without pinning an incidental recovery shape.
- **85 upgrade checks** cover syntax boundaries, valid lookalikes, deep nesting
  and incremental edits, including natural-literal binary operands, postfixes
  and body/capture boundaries before trailing comments. Standalone C tests
  exercise scanner serialization, full-width columns, all frame kinds, capacity
  and truncated states.
- The strict full offline gate passes with no timeout exemptions or baseline
  additions: the 2.6 MB `generics_3200/main.bend` parsed in **3.65 seconds** and
  the 5.7 MB `proofs_3200/main.bend` in **5.30 seconds**, under the unchanged
  10-second deadline. Earlier parser snapshots timed out; these are measured
  final-parser results, not a guarantee for every machine or workload.

The sweep writes **every file's result** to `build/upstream-report.json`, not
just failures. New rejections (including diagnostic fixtures) and formerly
rejected fixtures require review against the baseline. No Bend code, foreign
effects, import resolution or network requests are executed by this sweep.
A clean Tree-sitter tree is not proof that a program typechecks.

## Neovim: existing nvim-treesitter `main` setup

Keep filetype **`bend`** (including existing LSP configuration), and map it to
parser **`bend2`**. Place this at the **start of your existing nvim-treesitter
`config` function**, before computing `get_available()` or installing parsers:

```lua
local function register_bend2()
  require('nvim-treesitter.parsers').bend2 = {
    install_info = {
      url = 'https://github.com/Soulthym/tree-sitter-bend2',
      queries = 'queries',
      -- revision = '<commit-sha>', -- optional: pin a tested parser revision
    },
  }
end
register_bend2()
vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('Bend2ParserRegistration', { clear = true }),
  pattern = 'TSUpdate',
  callback = register_bend2,
})
vim.filetype.add({ extension = { bend = 'bend' } })
vim.treesitter.language.register('bend2', 'bend')
```

Restart Neovim, run **`:TSInstall bend2`**, wait for completion, then reopen a
`.bend` file. This installs from GitHub over HTTPS without an SSH key or a local
checkout. Use `:TSUpdate bend2` for updates, then restart to reload the parser.

**Highlighting is not automatically enabled by installation.** If your existing
FileType callback does not call `vim.treesitter.start()`, use the
[complete lazy.nvim example](docs/neovim.md#nvim-treesitter-main--lazynvim).
It also enables query-based indentation. Verify with `:set filetype?` and
`:InspectTree`; see [troubleshooting](docs/neovim.md#troubleshooting-missing-highlighting)
if colors are missing.

### Optional local checkout

For local development, replace `install_info` above with:

```lua
install_info = {
  path = '<path>/<to>/tree-sitter-bend2/', -- replace with your local checkout
  queries = 'queries',
},
```

Use an absolute path and omit `url`/`revision`. The checkout must already exist.
After editing the grammar, run `tree-sitter generate` there, then `:TSUpdate bend2`
and restart Neovim. See the guide for a
[checkout under the Neovim config directory](docs/neovim.md#local-development-checkout),
[legacy master](docs/neovim.md#legacy-nvim-treesitter-master),
[manual installation](docs/neovim.md#manual-installation-without-nvim-treesitter)
and [folding, context and textobjects](docs/neovim.md#optional-editor-features).

## Syntax and scope

The grammar follows the implementation, including:

- `def`, `law`, `type`, ordinary/foreign imports, `@unsafe`, `?` definitions;
- quantities, dependent arrows, existential binders, equality and rewrites;
- constructor/list/tuple/natural patterns, local and counted parallel lets;
- templates, GPU calls, do binds/lets/steps, arrays and implicit write rebinding;
- optional argument commas, adjacency-sensitive constructors and operators;
- nested case ownership by **case columns**, not Python INDENT/DEDENT tokens.

Indentation queries suggest conventional formatting; they do not define the
language. Native C/JS foreign imports contain **paths**, not embedded source,
so there is deliberately no fake C/JS injection query.

Assignments and case arms accept recursive patterns, not arbitrary expressions:
calls with arguments, indexing and lambdas cannot be patterns, including inside
constructors, lists, tuples and natural successors. Same-line `f (1)` and
`f [0]` are still postfix expressions, not separate patterns; a comma or newline
separates them. Empty `()` suffixes preserve eligible patterns, and `0n+name`
(including leading-zero spellings) preserves name binders, as in the compiler.
Typed and parallel lets bind names, not destructuring patterns; grouped/reusable
names and these identity forms remain supported. Erased `-` lets take a direct
name. Law templates (`for ~...`) must precede ordinary `for`/`exs` clauses.

Constructor resolution/arity, resolved-name eligibility, literal limits, pattern
counts and computed-match eligibility remain compiler-owned. `npm run test:syntax`
checks legal controls, the ten affected official malformed files, neighboring
declarations, and LF/CRLF incremental rejection/repair; set `BEND2_UPSTREAM` to
the pinned checkout.

For editor consumers, `gpu_call` still spans `!(`, but now contains separate
anonymous `!` and `(` children. The modifier capture covers only `!`; bracket
queries can capture `(` and the enclosing `arguments` node's closing `)`.
Previously `gpu_call` was a named leaf spanning `!(`; it is now a named
composite node. Existing `(gpu_call)` queries remain valid. Consumers assuming
a leaf or capturing the whole node as the modifier should target its `!` child
instead. Tree-sitter ABI 15 is unchanged.

### Recovery while editing

**Policy: preserve useful editor structure through mistakes and report localized
errors, rather than sacrificing tooling for compiler-like rejection.** Every
applicable grammar, scanner, query and upgrade change follows the
[error-tolerant parsing policy](docs/recovery-policy.md). Tightening syntax needs
structure/capture and break/repair tests, not just a rejection assertion.

Recovery tests require real syntax errors, intact neighboring `def`/`type`/`law`
nodes, and preserved function, type, parameter, call and number captures. They
cover missing delimiters, headers, bodies and let values; unfinished parallel
lets, do binds, case patterns, rewrites and lambdas; stray characters and quote/
escape mistakes. Repairing the text must restore the same tree as a fresh parse.
Incremental consistency alone would not establish this: two equally damaged
trees can agree while both lose highlighting.

Unterminated strings recover at a newline **when no later unescaped closing
quote exists**. Valid multiline strings, including strings containing apparent
Bend declarations, remain valid. A later quote in otherwise unrelated code can
therefore still extend an accidentally opened string. Multiline content is
represented by separate `string_content` nodes around physical newlines.

These are tested scenarios, not a guarantee for arbitrary broken programs.
After a missing call/constructor closer, same-column sibling arms retain their
`case_clause` nodes and editor captures; calls in let values and nested match
boundaries are tested too. A GPU modifier is recognized only with a real,
adjacent opening `(`, so an unfinished `!` cannot invent a GPU opener and steal
an outer closer. If a real inner opener exists, ordinary nesting still applies:
`wrap(g!(1)` may close the inner call and report a missing outer `)`; the parser
cannot infer which closer the author intended to omit.
Recovery **inside other damaged matches** remains coarse: later case arms can be
absorbed into an error region, and complicated combinations can also affect
following declarations. Five such probes verify repair and incremental
consistency, not highlight preservation for those arms. Fixing the original
syntax error restores the complete tree.

### Boundaries and remaining limitations

- Bend's parser performs name-sensitive checks and elaboration which cannot be
  represented by a context-free editor grammar: constructor arities, binder
  validity, template counts, law filling, import aliases, quantities, literal
  ranges, finite F32 values and type correctness remain Bend's responsibility.
- Pattern positions retain expression-shaped CST nodes; syntactic locals cover
  simple binders conservatively, not all nested destructuring or dependent
  name resolution. Use the LSP for authoritative references and definitions.
- The serializable scanner supports **up to 200 simultaneously active
  layout/counting frames** (not 200 parentheses), subject to the 1,024-byte
  serialized-state budget. Ordinary frames use five bytes, match frames nine,
  plus a three-byte header. Excessive nesting fails safely; state is never
  silently truncated.
- Lambda `: T =` lookahead is lexical rather than an embedded second Bend
  parser. Exotic malformed types may recover differently. Source columns use
  Tree-sitter's column API; unusual Unicode-containing same-line layout should
  be tested before relying on equivalence to Bend's JavaScript offsets.
- This is a tested syntax implementation, **not a claim of formal equivalence**
  for every possible byte sequence. Recovery deliberately remains useful on
  incomplete source. Further differences should become focused corpus tests.
- C/CLI and Neovim builds were exercised. Other generated language bindings are
  retained, but their dependency-specific test suites have not all been run.

## Updating the language reference

Pin a Bend release tag and its commit, not `main`. Review upstream parser/loader
changes first and apply the [recovery policy](docs/recovery-policy.md). Add
positive, negative and editing cases with reviewed trees, regenerate, run the
complete sweep and editor tests,
and review changes to the rejection baseline. Never blindly approve generated
expected trees or treat all diagnostic fixtures as syntactically invalid.
