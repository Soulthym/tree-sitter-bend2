-- Syntax restrictions at the compiler's pattern/name/template boundaries.
-- BEND2_PARSER selects a compiled library; BEND2_UPSTREAM selects the real
-- Bend checkout used by the offline sweep (including its malformed fixtures).
local root = vim.fn.getcwd()
local upstream = vim.env.BEND2_UPSTREAM or (root .. '/../bend')
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or (root .. '/build/bend2.so') })

local function parse(text)
  return vim.treesitter.get_string_parser(text, 'bend2'):parse()[1]:root()
end
local function fingerprint(node)
  local out = {}
  local function visit(n)
    out[#out + 1] = n:type() .. ':' .. table.concat({ n:range() }, ',') .. ':' .. tostring(n:missing())
    for child in n:iter_children() do visit(child) end
  end
  visit(node)
  return table.concat(out, '\n')
end
local function position(text, offset)
  local preceding = text:sub(1, offset)
  local _, row = preceding:gsub('\n', '')
  return row, #preceding - (preceding:match('.*\n()') or 1) + 1
end
local function edit(buf, from, to)
  local first, last = 0, 0
  while first < math.min(#from, #to) and from:byte(first + 1) == to:byte(first + 1) do first = first + 1 end
  while last < math.min(#from, #to) - first and from:byte(#from - last) == to:byte(#to - last) do last = last + 1 end
  local sr, sc = position(from, first)
  local er, ec = position(from, #from - last)
  vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, vim.split(to:sub(first + 1, #to - last), '\n', { plain = true }))
end
local function replace_once(text, old, new)
  local first, last = text:find(old, 1, true)
  assert(first, 'fixture no longer contains repair target: ' .. old)
  assert(not text:find(old, last + 1, true), 'ambiguous fixture repair target: ' .. old)
  return text:sub(1, first - 1) .. new .. text:sub(last + 1)
end
local function source(body)
  return 'import Base\n' .. body .. '\n'
end
local function let_body(head)
  return source('def boundary(b: U32) -> U32:\n  ' .. head .. '\n  0')
end
local function constructor_let(head)
  return source('type Aa is Data: Kk{a: U32, c: U32}\n'
    .. 'def boundary(b: Aa) -> U32:\n  ' .. head .. '\n  0')
end
local function match_body(pattern)
  return source('type Aa is Data: Kk{a: U32, c: U32}\n'
    .. 'def boundary(b: Aa) -> U32:\n  match b:\n    case ' .. pattern .. ': 0')
end
-- Empty calls preserve an already-bound Var. An unbound name can resolve to
-- a Ref before the call; that resolved-name eligibility remains compiler-owned.
local function call_let(head)
  return source('def boundary(b: U32, c: U32) -> U32:\n  ' .. head .. '\n  0')
end
local function call_constructor_let(head)
  return source('type Aa is Data: Kk{a: U32, c: U32}\n'
    .. 'def boundary(b: Aa, a: U32, c: U32) -> U32:\n  ' .. head .. '\n  0')
end
local function call_match(pattern)
  return source('type Aa is Data: Kk{a: U32, c: U32}\n'
    .. 'def boundary(b: Aa, a: U32, c: U32) -> U32:\n  match b:\n    case ' .. pattern .. ': 0')
end
local function natural_match(pattern)
  return source('def boundary(n: Nat) -> U32:\n  match n:\n    case ' .. pattern .. ': 0')
end
local function list_match(pattern)
  return source('def boundary(xs: List<U32>, a: U32, b: U32) -> U32:\n  match xs:\n    case ' .. pattern .. ': 0')
end
local function tuple_match(pattern)
  return source('def boundary(t: (U32 & U32), a: U32, b: U32) -> U32:\n  match t:\n    case ' .. pattern .. ': 0')
end
local function law_body(clauses)
  return source('law boundary:\n' .. clauses .. '\n  U32')
end

-- These controls follow parse_patt/parse_body, not just the old grammar's
-- expression-shaped patterns. Constructor names/arity remain compiler-owned.
local positives = {
  { 'nested constructor pattern with reusable field', source([[
type Nt is Data: Zr{} Sc{p: Nt}
def boundary(n: Nt) -> U32:
  match n:
    case Zr{}: 0
    case Sc{Zr{}}: 1
    case Sc{Sc{+p}}: 2]]) },
  { 'natural zero and successor patterns', source([[
def boundary(n: Nat) -> U32:
  match n:
    case 0n: 0
    case 1n+p: 1]]) },
  { 'natural successor with reusable tail', source([[
def boundary(n: Nat) -> U32:
  match n:
    case 0n: 0
    case 1n++q: 1]]) },
  { 'natural-valued arm ends before the next case', source([[
def boundary(n: Nat) -> Nat:
  match n:
    case 0n: 0n
    case 1n+p: 2n+p]]) },
  { 'word literal patterns', source([[
def boundary(n: U32) -> U32:
  match n:
    case 0: 0
    case 7: 1
    case p: 2]]) },
  { 'float literal pattern', source([[
def boundary(n: F32) -> U32:
  match n:
    case 1.5: 0
    case p: 1]]) },
  { 'character and string patterns', source([[
def character(c: Char) -> U32:
  match c:
    case 'a': 0
    case c: 1
def boundary(s: String) -> U32:
  match s:
    case "hi": 0
    case s: 1]]) },
  { 'list and cons patterns', source([[
def boundary(xs: List<U32>) -> U32:
  match xs:
    case []: 0
    case [a, b]: 1
    case +h <> t: 2]]) },
  { 'nested tuple patterns', source([[
def boundary(t: ((Nat & Nat) & Nat)) -> U32:
  match t:
    case ((0n, b), 0n): 0
    case ((a, b), c): 1]]) },
  { 'parenthesized constructor and reusable binder patterns', source([[
type Nt is Data: Zr{} Sc{p: Nt}
def boundary(n: Nt) -> U32:
  match n:
    case (Sc{(p)}): 0
    case (+p): 1]]) },
  { 'multiple scrutinee patterns', source([[
def boundary(a: Nat, b: Nat) -> U32:
  match a b:
    case 0n 0n: 0
    case 1n+p q: 1]]) },
  { 'reusable second pattern without a comma', source([[
def boundary(a: U32, b: U32) -> U32:
  match a b:
    case x+y: 0]]) },
  { 'ordinary constructor destructuring let', source([[
type Aa is Data: Kk{a: U32, c: U32}
def boundary(b: Aa) -> U32:
  Kk{a, c} = b
  (a + c : U32)]]) },
  { 'tuple and list destructuring lets', source([[
def boundary(t: (U32 & U32), xs: List<U32>) -> U32:
  (a, b) = t
  [c, d] = xs
  (a + b + c + d : U32)]]) },
  { 'reusable binder let', let_body('+x = b') },
  { 'typed named let', let_body('x: U32 = b') },
  { 'typed reusable named let', let_body('+x: U32 = b') },
  { 'typed parenthesized name', let_body('(x): U32 = b') },
  { 'typed parenthesized reusable name', let_body('(+x): U32 = b') },
  { 'typed annotated parenthesized name', let_body('(x : U32): U32 = b') },
  { 'erased named let', let_body('-x = b') },
  { 'erased typed named let', let_body('-x: U32 = b') },
  { 'grouped typed lets', source('def boundary() -> U32: (x: U32 = 1; y: U32 = 2; x + y : U32)') },
  { 'parallel named lets', let_body('x y = b 1') },
  { 'parallel reusable named lets', let_body('+x y = b 1') },
  { 'parallel parenthesized name', let_body('(x) y = b 1') },
  { 'parallel annotated parenthesized names', let_body('(x : U32) y = b 1') },
  { 'ordinary empty-call name', call_let('b() = b') },
  { 'reusable empty-call name', call_let('+b() = b') },
  { 'parenthesized empty-call name', call_let('(b)() = b') },
  { 'repeated empty-call name', call_let('b()() = b') },
  { 'typed empty-call name', call_let('b(): U32 = b') },
  { 'typed reusable empty-call name', call_let('+b(): U32 = b') },
  { 'typed repeated empty-call name', call_let('b()(): U32 = b') },
  { 'parallel empty-call names', call_let('b() c() = b 1') },
  { 'parallel repeated empty-call name', call_let('b()() y = b 1') },
  { 'empty-call case name', call_match('b()') },
  { 'repeated empty-call case name', call_match('b()()') },
  { 'empty-call recursive constructor let', call_constructor_let('Kk{a(), c()} = b') },
  { 'empty-call recursive constructor case', call_match('Kk{a(), c()}') },
  { 'empty-call constructor case', call_match('Kk{a, c}()') },
  { 'empty-call list case', list_match('[a(), b()]') },
  { 'empty-call tuple case', tuple_match('(a(), b())') },
  { 'empty-call list container', list_match('[a, b]()') },
  { 'empty-call tuple container', tuple_match('(a, b)()') },
  { 'empty-call natural tail', natural_match('1n+n()') },
  { 'empty-call literal patterns', source([[
def word(n: U32) -> U32:
  match n:
    case 0(): 0
def natural(n: Nat) -> U32:
  match n:
    case 0n(): 0
def character(c: Char) -> U32:
  match c:
    case 'a'(): 0
def boundary(s: String) -> U32:
  match s:
    case "hi"(): 0]]) },
  { 'zero-successor reusable typed name', let_body('0n++x: U32 = b') },
  { 'zero-successor reusable parallel name', let_body('0n++x y = b 1') },
  { 'nested zero-successor typed empty-call name', call_let('00n+0n+b()(): U32 = b') },
  { 'nested zero-successor parallel empty-call name', call_let('000n+00n+b() c() = b 1') },
  { 'zero-successor case name', match_body('0n+x') },
  { 'zero-successor constructor let', constructor_let('0n+Kk{a, c} = b') },
  { 'zero-successor recursive constructor case', call_match('Kk{0n+a, 00n+c()}') },
  { 'zero-successor list case', list_match('[0n+a, 00n+b()]') },
  { 'zero-successor tuple case', tuple_match('(0n+a, 00n+b())') },
  { 'zero-successor natural tail', natural_match('1n+00n+n()') },
  { 'leading multiple law templates and quantified clauses', law_body(
    '  for ~f: U32 -> U32\n  for ~g: U32 -> U32\n  for +x: U32\n  for -y: U32') },
  { 'law templates followed by for/exs constraints', law_body(
    '  for ~f: U32 -> U32\n  for x: U32 where {x == x : U32}\n  exs y: U32 where {y == x : U32}') },
  { 'ordinary law for/exs/where clauses', law_body(
    '  for x: U32 where {x == x : U32}\n  exs y: U32 where {y == x : U32}') },
}
-- Exercise the recursive boundary too: an expression cannot hide inside a
-- constructor, list, tuple, parentheses, or the tail of a natural pattern.
local negatives = {
  { 'call assignment target', let_body('f(1) = 3'), let_body('x = 3') },
  { 'typed constructor let', source('type Aa is Data: Kk{a: U32, c: U32}\ndef boundary(b: Aa) -> U32:\n  Kk{a, c}: Aa = b\n  0'),
    source('type Aa is Data: Kk{a: U32, c: U32}\ndef boundary(b: Aa) -> U32:\n  Kk{a, c} = b\n  0') },
  { 'lambda case pattern', match_body('x => x'), match_body('x') },
  { 'spaced natural successor is not sugar', natural_match('1n + 2n'), natural_match('1n+2n') },
  { 'template after plain for', law_body('  for x: U32\n  for ~f: U32 -> U32'),
    law_body('  for ~f: U32 -> U32\n  for x: U32') },
  { 'template after reusable for', law_body('  for +x: U32\n  for ~f: U32 -> U32'),
    law_body('  for ~f: U32 -> U32\n  for +x: U32') },
  { 'template after erased for', law_body('  for -x: U32\n  for ~f: U32 -> U32'),
    law_body('  for ~f: U32 -> U32\n  for -x: U32') },
  { 'template after exs', law_body('  exs x: U32\n  for ~f: U32 -> U32'),
    law_body('  for ~f: U32 -> U32\n  exs x: U32') },
  { 'template quantity on exs', law_body('  exs ~x: U32'), law_body('  exs x: U32') },
  { 'call nested in constructor case', match_body('Kk{f(1), c}'), match_body('Kk{a, c}') },
  { 'call nested in constructor let', constructor_let('Kk{f(1), c} = b'), constructor_let('Kk{a, c} = b') },
  { 'call nested in list case', match_body('[f(1)]'), match_body('[a]') },
  { 'spaced call nested in constructor case', match_body('Kk{f (1), c}'), match_body('Kk{a, c}') },
  { 'spaced index nested in list case', match_body('[f [0]]'), match_body('[a]') },
  { 'call nested in tuple case', match_body('(f(1), c)'), match_body('(a, c)') },
  { 'parenthesized call case', match_body('(f(1))'), match_body('(a)') },
  { 'call in natural successor case', match_body('1n+f(1)'), match_body('1n+p') },
  { 'erased constructor let', constructor_let('-Kk{a, c} = b'), constructor_let('-x = b') },
  { 'erased grouped name', let_body('-(x) = b'), let_body('-x = b') },
  { 'parallel constructor let', constructor_let('Kk{a, c} x = b 1'), constructor_let('a x = b 1') },
  { 'nonempty call beside ordinary empty-call name', call_let('b(1) = b'), call_let('b() = b') },
  { 'nonempty call beside typed empty-call name', call_let('b(1): U32 = b'), call_let('b(): U32 = b') },
  { 'nonempty call beside parallel empty-call name', call_let('b(1) c() = b 1'), call_let('b() c() = b 1') },
  { 'nonempty second parallel call', call_let('b() c(1) = b 1'), call_let('b() c() = b 1') },
  { 'nonempty call after ordinary empty call', call_let('b()(1) = b'), call_let('b()() = b') },
  { 'nonempty call after typed empty call', call_let('b()(1): U32 = b'), call_let('b()(): U32 = b') },
  { 'nonempty call after parallel empty call', call_let('b()(1) y = b 1'), call_let('b()() y = b 1') },
  { 'nonempty call after case empty call', call_match('b()(1)'), call_match('b()()') },
  { 'nonempty call after recursive constructor empty call', call_match('Kk{a()(1), c()}'), call_match('Kk{a()(), c()}') },
  { 'nonempty call after constructor pattern', call_match('Kk{a, c}(1)'), call_match('Kk{a, c}()') },
  { 'nonempty call after list empty call', list_match('[a()(1), b()]'), list_match('[a()(), b()]') },
  { 'nonempty call after tuple empty call', tuple_match('(a()(1), b())'), tuple_match('(a()(), b())') },
  { 'nonempty call after list container', list_match('[a, b](1)'), list_match('[a, b]()') },
  { 'nonempty call after tuple container', tuple_match('(a, b)(1)'), tuple_match('(a, b)()') },
  { 'nonempty call after natural tail empty call', natural_match('1n+n()(1)'), natural_match('1n+n()()') },
  { 'nonempty call after literal', source('def boundary(n: U32) -> U32:\n  match n:\n    case 0(1): 0'),
    source('def boundary(n: U32) -> U32:\n  match n:\n    case 0(): 0') },
  { 'indexed empty-call assignment name', call_let('b()[0] = b'), call_let('b() = b') },
  { 'typed nonzero reusable successor', let_body('1n++x: U32 = b'), let_body('0n++x: U32 = b') },
  { 'parallel nonzero reusable successor', let_body('1n++x y = b 1'), let_body('0n++x y = b 1') },
  { 'zero prefix cannot hide typed nonzero successor', let_body('00n+1n+x: U32 = b'), let_body('00n+0n+x: U32 = b') },
  { 'zero prefix cannot hide parallel nonzero successor', let_body('000n+01n+x y = b 1'), let_body('000n+00n+x y = b 1') },
  { 'nonempty call nested in zero constructor pattern', call_match('Kk{0n+a(1), 00n+c()}'),
    call_match('Kk{0n+a(), 00n+c()}') },
  { 'nonempty call nested in zero list pattern', list_match('[0n+a(1), 00n+b()]'),
    list_match('[0n+a(), 00n+b()]') },
  { 'nonempty call nested in zero tuple pattern', tuple_match('(0n+a(1), 00n+b())'),
    tuple_match('(0n+a(), 00n+b())') },
  { 'nonempty call nested in zero natural tail', natural_match('1n+00n+n(1)'), natural_match('1n+00n+n()') },
}

-- Numeric identity is value-based: leading zeroes do not turn a zero
-- successor into a constructor, but every nonzero successor does.
for _, digits in ipairs({ '0', '000' }) do
  local zero = digits .. 'n+'
  local nonzero = digits:sub(1, -2) .. '1n+'
  positives[#positives + 1] = { zero .. ' ordinary name', let_body(zero .. 'x = b') }
  positives[#positives + 1] = { zero .. ' typed name', let_body(zero .. 'x: U32 = b') }
  positives[#positives + 1] = { zero .. ' parallel name', let_body(zero .. 'x y = b 1') }
  negatives[#negatives + 1] = { nonzero .. ' typed successor', let_body(nonzero .. 'x: U32 = b'),
    let_body(zero .. 'x: U32 = b') }
  negatives[#negatives + 1] = { nonzero .. ' parallel successor', let_body(nonzero .. 'x y = b 1'),
    let_body(zero .. 'x y = b 1') }
  negatives[#negatives + 1] = { zero .. ' nonempty-call ordinary name', call_let(zero .. 'b(1) = b'),
    call_let(zero .. 'b() = b') }
  negatives[#negatives + 1] = { zero .. ' nonempty-call typed name', call_let(zero .. 'b(1): U32 = b'),
    call_let(zero .. 'b(): U32 = b') }
  negatives[#negatives + 1] = { zero .. ' nonempty-call parallel name', call_let(zero .. 'b(1) y = b 1'),
    call_let(zero .. 'b() y = b 1') }
end

-- Read the actual ten official sources, with their imports, declarations and
-- diagnostic comments intact. A missing checkout/file is a prerequisite error,
-- never a skip or a copied miniature posing as coverage of the real fixture.
local official = {
  { 'tests/parse/invalid_assign_target.bend', '  f(1) = 3', '  x = 3' },
  { 'tests/parse/typed_let_pattern.bend', '  Kk{a, c} : Aa = b', '  Kk{a, c} = b' },
  { 'tests/flatten/unsupported_pattern.bend', '    case x => x:', '    case x:' },
  { 'tests/spec/comp_erased_args.bend', '  for ~g:', '  for g:' },
  { 'tests/spec/comp_generic_dedupe.bend', '  for ~f:', '  for f:' },
  { 'tests/spec/comp_generic_mint.bend', '  for ~f:', '  for f:' },
  { 'tests/spec/comp_instantiation_error.bend', '  for ~f:', '  for f:' },
  { 'tests/spec/comp_late_param.bend', '  for ~f:', '  for f:' },
  { 'tests/spec/comp_let_split.bend', '  for ~p:', '  for p:' },
  { 'tests/spec/mint_count.bend', '  for ~g:', '  for g:' },
}
for _, spec in ipairs(official) do
  local path = upstream .. '/' .. spec[1]
  assert(vim.fn.filereadable(path) == 1, 'missing official malformed fixture: ' .. path)
  local text = table.concat(vim.fn.readfile(path, 'b'), '\n'):gsub('\r\n', '\n')
  -- Diagnostic excerpt comments can repeat a target; limit repair to source.
  local diagnostic = text:find('\n#|', 1, true)
  local program, comments = text:sub(1, diagnostic or #text), diagnostic and text:sub(diagnostic + 1) or ''
  local repaired = replace_once(program, spec[2], spec[3]) .. comments
  negatives[#negatives + 1] = { 'official ' .. spec[1], text, repaired }
end

local suffix = '\ntype SyntaxAfter is Data: SyntaxAfter{}\n'
  .. 'law syntax_after_law: U32\ndef syntax_after() -> U32: 42\n'
local function check_following(node, text, label)
  local found = {}
  for child in node:iter_children() do
    local name = child:field('name')[1]
    if name then found[vim.treesitter.get_node_text(name, text)] = child end
  end
  for _, name in ipairs({ 'SyntaxAfter', 'syntax_after_law', 'syntax_after' }) do
    assert(found[name] and not found[name]:has_error(), label .. ': lost intact following definition ' .. name)
  end
end
local failures, count = {}, 0
local function check(label, run)
  count = count + 1
  local ok, err = pcall(run)
  if ok then print('PASS ' .. label)
  else failures[#failures + 1] = tostring(err); print('FAIL ' .. tostring(err)) end
end
for _, newline in ipairs({ { 'LF', '\n' }, { 'CRLF', '\r\n' } }) do
  local function lines(text)
    return text:gsub('\n', newline[2])
  end
  for _, case in ipairs(positives) do
    local label, text = case[1] .. ' ' .. newline[1], lines(case[2])
    check(label, function() assert(not parse(text):has_error(), label .. ': legal syntax rejected') end)
  end
  for _, case in ipairs(negatives) do
    local label = case[1] .. ' ' .. newline[1]
    local broken, fixed = lines(case[2] .. suffix), lines(case[3] .. suffix)
    local buf
    check(label, function()
      local expected = parse(fixed)
      assert(not expected:has_error(), label .. ': invalid repair control')
      assert(parse(lines(case[2])):has_error(), label .. ': standalone malformed syntax accepted')
      local function damaged(node, context)
        assert(node:has_error(), label .. context .. ': malformed syntax accepted')
        check_following(node, broken, label .. context)
      end
      damaged(parse(broken), ' (fresh)')
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fixed:sub(1, -2), '\n', { plain = true }))
      local parser = vim.treesitter.get_parser(buf, 'bend2')
      assert(fingerprint(parser:parse()[1]:root()) == fingerprint(expected), label .. ': valid buffer differs from fresh parse')
      for _ = 1, 2 do
        edit(buf, fixed, broken)
        local changed = parser:parse()[1]:root()
        damaged(changed, ' (incremental)')
        assert(fingerprint(changed) == fingerprint(parse(broken)), label .. ': incremental rejection differs from fresh parse')
        edit(buf, broken, fixed)
        local restored = parser:parse()[1]:root()
        assert(not restored:has_error(), label .. ': repaired buffer retains an error')
        assert(fingerprint(restored) == fingerprint(expected), label .. ': repair did not restore the fresh valid tree')
        check_following(restored, fixed, label .. ' (repaired)')
      end
    end)
    if buf then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
end
assert(#failures == 0, table.concat(failures, '\n'))
print(('Syntax boundaries: %d scenarios passed (LF/CRLF controls, actual official files, rejection, following definitions, incremental edits and repair).'):format(count))
vim.cmd('qa!')
