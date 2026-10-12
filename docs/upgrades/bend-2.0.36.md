# Bend v2.0.36 compatibility audit

## Exact reference

- Previous: **v2.0.35**, `79df8d9c40722ee9507a1e253f283b51025f9d6c`.
- Target: **v2.0.36**, `ae1101ca7d15364f9274fa6b1367d175884a7da7`.
- Official release: <https://github.com/bendlang/bend/releases/tag/v2.0.36>.
- Comparison: <https://github.com/bendlang/bend/compare/v2.0.35...v2.0.36>.
- Parser package: **0.3.0**, still **ABI 15**. This source update does not publish
  packages or create release tags.
- `bend2/base.bend`: **3,089 lines / 75,064 bytes**, SHA256
  `99ac43f2b2bb3e3f39acdcedcecbbd3cb44749ce13969c827d6973fa66f7facf`.

The comparison contains **50 commits / 179 changed paths**. The scope ledger
below covers every commit. The complete cumulative `bend2/bend.ts` diff, not
release-note claims, determines the source-language changes. Changed sources,
formatter and verdict/CLI changes were also inspected. Kernel/compiler/runtime
execution is not covered by a Tree-sitter compatibility claim.

## Syntax, ownership and conflicts

The native source parser has a 39-line cumulative diff: the statement-write
span guard and a consumed/computed-scrutinee diagnostic rewrite. It adds no
source tokens, operators or term productions.

1. **Statement writes versus terms** (`653e391b`): native `term_write` now
   requires the written variable to start at the body's beginning. An explicit
   `Array.set(..)` call or a parenthesized `a[i] <- v` is a term; a real bare
   statement write may bind the remainder. Our existing upgrade regressions
   already retain the next eliminator row for both term forms. They still pass.
2. **Scrutinee diagnostics** (`a950fd68`): flattening now names the consumed or
   computed scrutinee more clearly. This does not introduce a lexical syntax
   rejection. The three changed consumed/constructor-scrutinee refusal fixtures
   remain syntax-clean here; no fake ERROR was added to imitate the checker.
3. **Formatter suffixes** (`2bfc83fd`): preserves glued `name?()` and rejects
   spacing away from the name as before. Existing suffix boundary tests cover
   space/newline/comment rejection. Formatter scanning is not a new lexer.
4. **Kernel kind/quantity terms and convoying**: `Kind(q)`, `<&>`, datatype kinds,
   quantity-bearing parameters, lambdas and matches already exist in the source
   grammar. New verdict semantics require no invented syntax restrictions.

Two new non-diagnostic fixtures exposed **existing** valid-syntax gaps, accepted
by both native tags. These were fixed, not added to the rejection baseline:

- `tests/check/kind_terms.bend`: `(y: Nat) => 1n` and `(z: Nat) => z` lacked
  lambda-binder support. The existing name-pattern/group production is reused.
  **Additive CST change:** `lambda_expression.parameter` can additionally be a
  `parenthesized_expression`; its `body` and optional `type` retain the binder
  and annotation. Direct named/reusable annotated binders retain parameter
  highlights and local definitions. No existing field/node/cardinality changes.
- `tests/check/convoy_dependent.bend`: an inner and middle match ending before
  an outer sibling case could reject the real outer case. The existing closure
  loop now completes the nearest active ancestor before that real dedented
  case, after eligible current-owner cases have first refusal. There is no new
  scanner state, scope, serialization format, header prediction or precedence.
  Recovery's all-valid mask cannot activate this new case-completion path.

Malformed controls retain native errors for the relevant construct: a grouped
arithmetic expression is not a lambda binder (one ERROR at the arrow/body,
without consuming the real group); a consumed arrow with no body has a MISSING
body at that arrow's end. Literal EOF is tested without Neovim's virtual LF.
The upgrade does not claim general recovery guarantees for newly admitted
lambda forms; documented broader lambda/rewrite recovery limits still apply.

## Executed comparison and retained checks

| Check | Result |
| --- | --- |
| v2.0.36 full sweep | **1,685 visited: 1,563 clean / 122 rejected / 0 rejected non-diagnostic** |
| v2.0.35 full sweep | **1,644 visited: 1,522 clean / 122 rejected**, unchanged |
| Previously clean trees | **3,083 parse instances across both tags**, recursive CST/fields/ranges and all seven capture sets unchanged |
| Changed extant `.bend` sources | **88 checked natively**, 85 accepted/lowered; 3 consumed/computed-scrutinee flattening refusals stay syntax-clean |
| Changed diagnostic-bearing sources | All 10 inspected; remaining 7 are unsafe/runtime/foreign/I/O diagnostics, not syntax errors |
| New release witnesses | **36 LF/CRLF/final-LF/literal-EOF vectors, 216 exact-string edits**, full CST/fields and seven captures agree fresh/incremental/repaired |
| Existing upgrade regressions | **85/85** |
| Corpus / syntax boundaries | **42/42 / 412/412** |
| GPU recovery / owners / successor | **48/48 / 44/44 / 1,172 vectors, 3,504 edits** |
| Missing-body guards | **124 sources / 372 edits** |
| Scanner / actual GPU masks | Bounds and serialization plus new ancestor/case regression; **178 masks / 3,916 checks** |
| Editor / documentation | Seven query compilation/captures, 180 buffer edits; 11 README snippets |
| Standard libraries | Both tags parse cleanly; old library CST/captures unchanged |

The rejection list has the **same 122 paths**, only its reference label changes.
All 122 also encounter native rejection: 114 were checked through local
parse/lowering; the remaining eight required the native loader's import-header
validation, not a helper's missing-file/blocked-import error. No network fetch or
fixture program execution occurred. A native declaration/semantic wall can
precede a later real syntax fault (e.g. duplicate `String.eq` before an obsolete
`type ...:` header); Tree-sitter does not imitate declaration resolution or
promise the same earliest diagnostic. Diagnostic comments alone are not a
syntax oracle. No new semantic refusal was turned into a grammar error.

Same source-derived O2 builds: parser states **21,923 → 22,337**, generated
parser.c **30,340,024 → 31,275,085 bytes**, shared library
**4,580,816 → 5,092,816 bytes** (**+512,000 / approximately 11.2%**). Scanner
state/serialization sizes and ABI stay unchanged. CLI sweeps around 4.1 seconds
are not evidence of a speed improvement or universal performance guarantee.

Known accepted recovery limits remain strict and unchanged: **12 common
recovery failures**, **28 nested-proof rewrite assertions**, and the documented
ordinary-function-body GPU EOF ownership family. The common suite reports
539/551 assertion cases plus six separate passing healthy controls (545 passing
records overall); these are not different before/after results. A new annotated
lambda with an invalid `$` body can still lose its enclosing law, as its already
admitted bare-lambda counterpart does on the baseline. This update neither
redesigns that deferred recovery family nor weakens its tests.
`npm run test:offline` remains red and stops at the 28 existing rewrite-recovery
failures, before common recovery. Later suites were executed separately, not
claimed reached by the chained gate. No failing tests are bypassed or disabled.
The CI PR remains postponed on its own branch and its policy was not changed.

## Reproduction

Use the exact tagged checkout named in `test/bend-reference.json`. Generation
uses tree-sitter-cli 0.26.9, ABI 15; no parser-table hand edits are needed.
Set output/cache/log/TMPDIR destinations privately before running:

```sh
export BEND2_UPSTREAM=/absolute/path/to/bend-v2.0.36
npm run generate
npm test
npm run test:scanner
npm run test:upgrade
npm run test:syntax
npm run test:stdlib
npm run test:upstream
npm run test:release
# Intentionally strict; currently stops at the documented rewrite failures:
npm run test:offline
```

`npm run test:upgrade` now includes `scripts/test-bend-2.0.36.lua`, which reads
the two full official witnesses from `BEND2_UPSTREAM` (default `../bend`). The
existing `test-upgrade.lua` still needs no upstream source on its own.
`BEND2_PARSER` selects a private library; `BEND2_REPORT` optionally saves the
new regression's full source/CST/captures/edit results.

## Complete upstream commit scope ledger

“Outside source syntax” does not mean untested native behavior was executed;
those commits are covered for source compatibility by the cumulative parser
comparison and source sweeps, not by runtime/kernel validation.

| Commit | Change and source-parser consequence |
| --- | --- |
| `5a0b523f` | Flake version 2.0.35; packaging only. |
| `2f0af0c4` | Upstream PR gate; CI, outside source syntax. |
| `f48a8365` | Formatter scanning simplification; source token grammar unchanged. |
| `653e391b` | Statement-write span guard; explicit call/grouped write keep next row, existing regressions pass. |
| `a950fd68` | Nested split-value match diagnostic; flattening, not new syntax rejection. |
| `a3f1782a` | README hub/accounts correction; documentation. |
| `2bfc83fd` | Formatter unsafe suffix; existing glued-name boundary support retained. |
| `396a65e6` | Demo law comments; documentation. |
| `360d2c41` | Code-generation memoization; outside source syntax. |
| `698b2e81` | Graph closure indexing; compiler algorithm. |
| `60b6c5f9` | Graph closure memo simplification; compiler algorithm. |
| `565d7fde` | I/O pending links; runtime. |
| `c375faf9` | Isolate spare sum-arm nodes; compiler. |
| `a3b0dfe7` | Process.run polling; runtime. |
| `1159f0b0` | Native-effect Bend callback C emission; compiler/runtime. |
| `e1328291` | New-book layout cache reset; display. |
| `08a6083e` | Verdict temporary-input cleanup; kernel tooling. |
| `1a2e5cd3` | Lean version/cache validation; kernel tooling. |
| `fdedd46e` | F32.read whitespace alignment; runtime input, not source floats. |
| `bf968271` | Compiler file/shared-cell/effect mechanism simplification; outside source syntax. |
| `ffeddf06` | Quantity-term kinds, meets, Σ/subsumption and generic verdict output; existing source forms, kind_terms witness fixed. |
| `95217e9c` | Promise traversal visited-set simplification; semantic dependency analysis. |
| `1cce4999` | Native result-copy removal; compiler. |
| `8828cc19` | Dependent convoy variables/quantities; verdict semantics, convoy_dependent witness fixed. |
| `c6bf2771` | Unit provenance/word families; verdict semantics. |
| `b003a4eb` | Fragmented HTTP demo response reads; demo/runtime. |
| `5169abf1` | Unsafe dependencies in datatype kinds; semantic dependency analysis, sources stay clean. |
| `5c885eb9` | CUDA probe diagnostics; runtime. |
| `d052d4f3` | Numbered kernel name collisions; generated kernel output. |
| `9cab39a1` | Channel/socket timeout twins and Poll; standard-library declarations, clean full-library parse. |
| `0d9adafb` | Iterative unsafe-reference collection; semantic dependency analysis. |
| `53fc961d` | Reusable-lambda kernel conversion; semantics, no new source operator. |
| `1487e77d` | Shared template root constants; verdict optimization. |
| `9a862d2b` | Effective upstream test assertions; source sweep/changed diagnostic audit. |
| `a074244d` | Promise-free early return/reach set; semantic dependency analysis. |
| `af6a54fd` | UDP byte twins; standard-library declarations, clean full-library parse. |
| `e39ab13a` | Declared constructor-field types in compilation; outside source syntax. |
| `7ed3424b` | MSL heap error-flag load; runtime. |
| `ebd9e904` | Type-reduction/dedup optimization; compiler/verdict. |
| `a000c04f` | Pocket workshop link; documentation. |
| `11d48327` | Grow-pass lane rings; runtime. |
| `ef627814` | Simpler retention of type-reduction speedups; compiler/verdict. |
| `4f277091` | Open-proof rewrite type reading/C-facts refusal; compiler semantics, existing rewrite grammar. |
| `add2fdf2` | Boxed-constructor datatype registration; compiler. |
| `7192eff9` | Remove specialization masks; verdict semantics. |
| `5be8ddd4` | Reuse tele_fill for template prefixes; verdict implementation. |
| `fa4ba634` | Live-copy cap fail-stop message; runtime, not a syntax limit. |
| `bc69e81e` | Shared documentation GIF writer; tooling. |
| `0ad47fc0` | Kernel book name table; kernel implementation. |
| `ae1101ca` | v2.0.36/BendAI release, auth-key migration and library/runtime summary; reference pin advanced, no source grammar additions. |
