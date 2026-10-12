# Changelog

## Unreleased

## 0.3.0

Bend reference: **v2.0.36**, `ae1101ca7d15364f9274fa6b1367d175884a7da7`.
ABI remains 15; no package publication or tag is performed by this source update.

- Audit all 50 upstream commits since v2.0.35; update the reference/stdlib hashes
  and sweep all 1,685 sources: 1,563 clean, the same 122 reviewed rejections,
  and zero rejected non-diagnostic fixtures. No new rejection exemption.
- Support annotated named lambda binders via the existing parenthesized node
  and retain parameter highlights/local definitions. The public parameter
  schema widens additively; previously clean trees/captures remain unchanged.
- Complete existing ancestor match scopes before a real dedented sibling case,
  fixing valid three-level nested matches without new scanner state or relaxing
  recovery's all-valid entry guard. Add 36 exact-string variants/216 edits and
  LF/CRLF scanner regressions. Native v2.0.35 also accepts these witnesses.
- Record the approximately 11.2% compiled-library increase and preserve the
  documented deferred recovery failures; the strict offline gate remains red.

- Upgrade the Go runtime binding to `go-tree-sitter v0.25.0` for ABI 15 and
  require Go 1.23+. Commit module checksums and test actual parser loading plus
  valid source parsing; the old language-object-only test missed incompatibility.
- Retain the full successor operand's atomic GPU call through native infix
  errors, with 1,172 exact ownership tests and real byte-edit repairs. No public
  schema/scanner-state change; compiled-library cost +23.25%.

- Preserve the next law after a malformed lambda rewrite proof and the actual
  outer-law terminal body/rewrite scope after a bad let value. Add the full
  strict40 next-law/40 law-body/eight scope/four missing-body guard matrix.
- Document the still-unresolved nested-proof law recovery defect: its completed
  inner rewrite survives, but the law wrapper/terminal body can be lost. Keep
  its28 regressions red; the strict offline gate is not claimed green. See
  [known limits](README.md#known-nested-proof-law-recovery-limit).

- Restore comma-free string patterns and contextual infix `&` without changing
  quantity syntax. Preserve following declarations after parallel/array damage,
  grouped-pattern siblings and intact literal continuations. Reject invalid
  assignment targets inside their full edited function; commit completed
  successor operands before recovery can borrow another statement's value.
  Extend LF/CRLF native-error ownership, field/capture and repeated-repair tests.

- Preserve arm-free eliminator identities in recursive patterns and named
  bindings. Require an eligible fallback; keep actual eliminator arms and
  expression-shaped fallbacks invalid as patterns. Add LF/CRLF rejection/
  repair controls and a public-CST regression without changing scanner state.

- Document the public CST migration for glued `1n+2n`: binary
  `left/operator/right` fields become an unfielded successor head and `value`.
  Provide and execute the replacement query with exact LF/CRLF capture ranges.

- Preserve binary `&` after natural literals and keep trailing comments outside
  natural-valued body fields. Distinguish literal and glued-successor tokens
  without a trailing zero-width natural token.
- Preserve following declarations after damaged parallel-let values and clean
  terminal values after invalid call/index assignment targets. Expose actual
  numeric lexemes during native recovery without admitting expression patterns
  or adding body-selector state. Add LF/CRLF field/capture and break/repair checks.
- Strengthen mutation regressions for natural operator spacing and recovered
  match-frame serialization with an independent expected-state oracle.

- Restore declaration/arm recovery after malformed case headers, unfinished
  GPU prefixes and missing function names with GPU bodies. Recognize an
  immediately following decorated definition after an invalid `do`.
- Preserve sibling arms after missing call closers in let values, and preserve
  real delimiter ownership through malformed GPU calls without a new closing-
  parenthesis indentation rule. Extend LF/CRLF break/repair tests with exact
  field/capture ranges, all editor query groups and valid nesting controls.
- Correct GPU migration guidance: `gpu_call` changes from a named leaf to a
  composite node, not from a combined anonymous token.

- Reject non-pattern assignment and case terms, destructuring in typed/parallel
  lets, and law templates after ordinary clauses. Preserve recursive patterns,
  empty-call and zero-successor identities, optional commas, named CST nodes
  and following declarations through repair.
  Add LF/CRLF regressions using all ten affected official malformed fixtures;
  update the reviewed rejection baseline without exempting new failures.
- Preserve following top-level declarations after invalid nested `do` bodies
  by closing bounded scanner scopes before restarting declaration recovery.
  Add LF/CRLF break/repair regressions; keep native syntax errors and existing
  valid-syntax acceptance unchanged.
- Preserve same-column sibling `case` arms after missing call or constructor
  closers, including inner/outer match boundaries. Retain native errors,
  intact arm fields, highlights, folds, context, textobjects, locals and indents
  through LF/CRLF break/repair edits; other damaged-arm forms remain limited.
- Expose separate `!` and `(` tokens inside the existing `gpu_call` node.
  GPU modifier highlights no longer cover the opening bracket, and editor
  bracket queries can pair its parentheses. Keep `!(` adjacency and useful
  recovery for whitespace/comment typos and malformed unsafe headers.
- Highlight eliminator-arm constructor names and unsafe definition suffixes
  by their roles. A hole's `?` is no longer overridden by an operator capture.

## 0.2.0

Bend reference: **v2.0.35**, `79df8d9c40722ee9507a1e253f283b51025f9d6c`.
This is a tagged-release reference, not upstream `main`. Tree-sitter ABI stays 15.

- Support the deep-operator regression in Bend's release tests by compacting
  scanner serialization: up to 200 frames within the fixed 1,024-byte budget.
- Respect the glued compound-type argument boundary introduced in Bend 2.0.32,
  while retaining parenthesized arguments, quantities, ordinary comparisons and
  spaced generic closers. Public array-type nodes may now contain a
  `binary_expression` for glued comparisons.
- Report misplaced whitespace/comments before a declaration's `?` suffix,
  preserving its structure, highlights, folds and tags.
- Keep functions, unaffected fields and all seven query groups' captures intact
  through malformed compound type arguments. Atomic postfix/glued-comparison
  heads also fix the CST precedence of `1 + 2<3`; call/index head schemas narrow
  accordingly (parenthesized functions and expressions remain supported).
- Raise Python's optional Tree-sitter core minimum to 0.25 for ABI 15.
- Make editor usefulness and localized recovery an explicit project policy.
  Add field/capture/locality tests alongside acceptance and incremental tests.
- Add standalone scanner, upgrade, whole-stdlib and release-metadata gates,
  plus selectable old/new parser libraries for upstream comparison reports.
- Validate the entire 3,009-line stdlib with old and new parsers; its recursive
  node types/ranges are unchanged. At the tag, visit all 1,644 `.bend` files:
  1,532 clean parses and 112 reviewed diagnostic rejections, with no rejected
  non-diagnostic fixtures.

See the [complete upstream audit](docs/upgrades/bend-2.0.35.md) and
[recovery policy](docs/recovery-policy.md). Preparing these sources does not
publish a package or imply that dependency-specific binding suites were run.

## 0.1.0

Initial Bend 2.0.29 grammar, serializable layout scanner and seven Neovim
queries; full upstream sweep, editor tests and installation documentation.
Follow-up work added declaration/string recovery and explicit editing tests.
