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
    for child, field in n:iter_children() do
      out[#out + 1] = field or ''
      visit(child)
    end
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
  { 'lambda numeric next argument', source('def apply(f: U32 -> U32, n: U32) -> U32: f(n)\ndef boundary() -> U32: apply(x => x 2)') },
  { 'lambda indented next argument', source('def apply(f: U32 -> U32, n: U32) -> U32: f(n)\ndef boundary(n: U32) -> U32:\n  apply(x =>\n    x\n      n)') },
  { 'successor reusable next pattern', source('def boundary(a: Nat, b: Nat) -> Nat:\n  match a b:\n    case 0n +y: 0n\n    case 1n+x +y: x') },
  { 'successor reusable next expression', source('def boundary(x: Nat) -> List<Nat>: [1n+x +x]') },
  { 'successor rewrite next argument', source('def apply(a: Nat, -b: U32) -> Nat: a\ndef boundary(x: Nat) -> Nat: apply(1n+x %{{==} : {0 == 0 : U32}} : U32; 2)') },
  { 'successor newline group argument', source('def apply(a: Nat, -b: U32) -> Nat: a\ndef boundary(x: Nat) -> Nat: apply(1n+x\n (2))') },
  { 'successor newline list argument', source('def boundary(x: Nat) -> List<Nat>: [1n+x\n [x]]') },
  { 'successor lambda operand', source('def boundary() -> Nat: 1n+x => x') },
  { 'successor adjacent inequality', source('def boundary(n: Nat) -> Type: {1n+n!=2n: Nat}') },
  { 'successor trailing comment', source('def boundary(n: Nat) -> Nat: 1n+n # trailing') },
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
  { 'comma-free string list pattern', source('def boundary(xs: List<String>) -> U32:\n  ["a" "b"] = xs\n  0') },
  { 'comma-free string constructor pattern', source('type Strings is Data: Strings{a: String, b: String}\ndef boundary(xs: Strings) -> U32:\n  Strings{"a" "b"} = xs\n  0') },
  { 'comma-free string pattern after newline/comment', source('def boundary(xs: List<String>) -> U32:\n  ["a" # between patterns\n   "b"] = xs\n  0') },
  { 'comma-free string list expression', source('def boundary() -> List<String>: ["a" "b"]') },
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
  -- With no arms the compiler returns the fallback unchanged. Preserve that
  -- identity only when its fallback is eligible in the surrounding context.
  { 'arm-free eliminator case binder', source('def boundary(n: U32) -> U32:\n  match n:\n    case \\{x}: x') },
  { 'arm-free eliminator ordinary binder', let_body('\\{x} = b') },
  { 'arm-free eliminator typed binder', let_body('\\{x}: U32 = b') },
  { 'arm-free eliminator parallel binder', let_body('\\{x} y = b 1') },
  { 'arm-free eliminator reusable typed binder', let_body('\\{+x}: U32 = b') },
  { 'nested arm-free eliminator typed binder', let_body('\\{\\{x;};}: U32 = b') },
  { 'arm-free eliminator zero-successor binder', let_body('0n+\\{x}: U32 = b') },
  { 'arm-free eliminators in constructor pattern', call_match('Kk{\\{a}, \\{c}}') },
  { 'arm-free eliminator constructor fallback', match_body('\\{Kk{a, c}}') },
  { 'arm-free eliminators in list pattern', list_match('[\\{a}, \\{b}]') },
  { 'arm-free eliminator list fallback', list_match('\\{[a, b]}') },
  { 'arm-free eliminators in tuple pattern', tuple_match('(\\{a}, \\{b})') },
  { 'arm-free eliminator natural tail', natural_match('1n+\\{n}') },
  { 'empty-call arm-free eliminator binder', call_let('\\{b}() = b') },
  { 'comma-free arm-free eliminator case binders', source('def boundary(a: U32, b: U32) -> U32:\n  match a b:\n    case \\{x} \\{y}: 0') },
  { 'comma-free arm-free eliminators in constructor', call_match('Kk{\\{a} \\{c}}') },
  { 'comma-free arm-free eliminators in list', list_match('[\\{a} \\{b}]') },
  { 'leading multiple law templates and quantified clauses', law_body(
    '  for ~f: U32 -> U32\n  for ~g: U32 -> U32\n  for +x: U32\n  for -y: U32') },
  { 'law templates followed by for/exs constraints', law_body(
    '  for ~f: U32 -> U32\n  for x: U32 where {x == x : U32}\n  exs y: U32 where {y == x : U32}') },
  { 'ordinary law for/exs/where clauses', law_body(
    '  for x: U32 where {x == x : U32}\n  exs y: U32 where {y == x : U32}') },
}
for _, op in ipairs({ '>', '>=', '>>' }) do
  positives[#positives + 1] = { 'successor comment operator ' .. op,
    source('def boundary(x: Nat, y: Nat) -> Nat: 1n+x # between\n  ' .. op .. ' y'), op }
end
for _, head in ipairs({ '(x)', 'x()', '[x]', 'Kk{x}' }) do
  for _, literal in ipairs({ '0n', '1n' }) do
    positives[#positives + 1] = { 'closed-atom ampersand ' .. head .. '&' .. literal,
      source('type Aa is Data: Kk{a: Nat}\ndef boundary(x: Nat) -> Nat: ' .. head .. '&' .. literal) }
  end
end
for _, quantity in ipairs({ '&0', '&1', '&2' }) do
  positives[#positives + 1] = { 'genuine quantity ' .. quantity, source('def boundary() -> Quant: ' .. quantity) }
end
-- Exercise the recursive boundary too: an expression cannot hide inside a
-- constructor, list, tuple, parentheses, or the tail of a natural pattern.
local negatives = {
  { 'eliminator arms in case pattern', call_match('\\{Kk: a; b}'), call_match('a') },
  { 'eliminator arms in ordinary binding', constructor_let('\\{Kk: a; c} = b'), constructor_let('x = b') },
  { 'eliminator arms in typed binding', let_body('\\{Kk: x; y}: U32 = b'), let_body('x: U32 = b') },
  { 'eliminator arms in parallel binding', let_body('\\{Kk: x; y} z = b 1'), let_body('x z = b 1') },
  { 'eliminator arms nested in constructor', call_match('Kk{\\{Kk: a; c}, c}'), call_match('Kk{a, c}') },
  { 'eliminator lambda fallback is not a pattern', call_match('\\{x => x}'), call_match('a') },
  { 'eliminator call fallback is not a pattern', call_match('\\{b(1)}'), call_match('b') },
  { 'empty eliminator is not a pattern', match_body('\\{}'), match_body('x') },
  { 'eliminator constructor fallback is not a typed name', constructor_let('\\{Kk{a, c}}: Aa = b'),
    constructor_let('x: Aa = b') },
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

-- Shared pattern prefixes may not finish a full successor operand early.
for _, spec in ipairs({
  { '1n+x[0]', '(x[0])', { 'x[0]' } },
  { '1n+g!(x)', '(g!(x))', { 'g!(x)' } },
  { '1n+1n+x & x', '(1n+(x & x))', { '1n+x & x', 'x & x' } },
  { '0n+[x][0]', '([x][0])', { '[x][0]' } },
}) do
  local function book(term) return source('def boundary(x: Nat) -> Nat: ' .. term) end
  positives[#positives + 1] = { 'full successor operand ' .. spec[1], book(spec[1]), function(tree, text)
    local values = {}
    local query = vim.treesitter.query.parse('bend2', '(natural_successor value: (_) @value)')
    for _, n in query:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
    assert(vim.deep_equal(values, spec[3]), 'changed successor operand fields/ranges')
    if spec[1]:find('g!', 1, true) then
      for file, capture in pairs({ highlights = 'function.call', tags = 'name', textobjects = 'call.outer' }) do
        local q = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/' .. file .. '.scm'), '\n'))
        local found = false
        for id, n in q:iter_captures(tree, text, 0, -1) do
          found = found or (q.captures[id] == capture and vim.treesitter.get_node_text(n, text) == (file == 'textobjects' and 'g!(x)' or 'g'))
        end
        assert(found, 'lost exact successor call capture ' .. file)
      end
    end
  end, book(spec[1]:sub(1, 3) .. spec[2]) }
end
positives[#positives + 1] = { 'zero literal successor identity binding', source(
  'type Nat is Data: Zero{} Succ{p: Nat}\ndef boundary(x: Nat) -> Nat: 0n+0n = x; x'), function(tree, text)
    local query = vim.treesitter.query.parse('bend2', '(let_expression pattern: (binding) @pattern)')
    local values = {}
    for _, n in query:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
    assert(vim.deep_equal(values, { '0n+0n' }), 'lost zero identity binding field/range')
  end, source('type Nat is Data: Zero{} Succ{p: Nat}\ndef boundary(x: Nat) -> Nat: 0n = x; x') }
positives[#positives + 1] = { 'array constructor type ownership', source('def boundary(x: Nat) -> Nat: [x: K{} ^ 2]'),
  function(tree, text)
    local query = vim.treesitter.query.parse('bend2', '(array_expression type: (constructor_expression) @type)')
    local values = {}
    for _, n in query:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
    assert(vim.deep_equal(values, { 'K{}' }), 'lost real array constructor type/delimiters')
  end, source('def boundary(x: Nat) -> Nat: [x: (K{}) ^ 2]') }
for _, atom in ipairs({ '@a: Type -> a', '1n+x' }) do
  negatives[#negatives + 1] = { 'array full-expression type steals size delimiter ' .. atom,
    source('def boundary(x: Nat) -> Nat: [x: ' .. atom .. ' * 2n]'),
    source('def boundary(x: Nat) -> Nat: [x: (' .. atom .. ') * 2n]'), function(tree, text, label)
      local field = atom:sub(1, 1) == '@' and 'codomain' or 'value'
      local kind = field == 'codomain' and 'dependent_type' or 'natural_successor'
      local query = vim.treesitter.query.parse('bend2', '(' .. kind .. ' ' .. field .. ': (_) @operand)')
      local operands = {}
      for _, n in query:iter_captures(tree, text, 0, -1) do
        assert(not n:has_error(), label .. ': damaged intact inner full expression')
        operands[#operands + 1] = vim.treesitter.get_node_text(n, text)
      end
      assert(vim.deep_equal(operands, { (field == 'codomain' and 'a' or 'x') .. ' * 2n' }),
        label .. ': stolen inner operator or truncated full operand')
      local def
      for child in tree:iter_children() do
        local name = child:field('name')[1]
        if name and vim.treesitter.get_node_text(name, text) == 'boundary' then def = child end
      end
      assert(def and def:has_error(), label .. ': edited declaration/error ownership lost')
      for _, name in ipairs({ 'name', 'parameters', 'return_type', 'body' }) do
        local parts = def:field(name)
        assert(#parts == 1 and (name == 'body' or not parts[1]:has_error()), label .. ': damaged intact header ' .. name)
      end
      local first, last = assert(text:find('[x: ' .. atom .. ' * 2n]', 1, true))
      local body = def:field('body')[1]
      assert(select(3, body:start()) == first - 1 and select(3, body:end_()) == last, label .. ': body boundaries changed')
      local real_closer = false
      local function inspect(n)
        local a, b = select(3, n:start()), select(3, n:end_())
        if n:type() == ']' and a == last - 1 and b == last and not n:missing() then real_closer = true end
        if n:type() == 'ERROR' or n:missing() then
          assert(a >= first - 1 and b <= last, label .. ': error crosses body/header boundary')
        end
        for child in n:iter_children() do inspect(child) end
      end
      inspect(def)
      assert(real_closer, label .. ': real array/list closer was lost or synthesized')
    end }
end

for _, spec in ipairs({
  { 'law lambda clause operator', 'law boundary:\n  for t:x=>x\n  U32',
    'law boundary:\n  for t:(x=>x)\n  U32', 'law_clause', 'type' },
  { 'rewrite lambda motive operator', 'def boundary(x:T)->U32: %e:x=>x;x',
    'def boundary(x:T)->U32: %e:(x=>x);x', 'rewrite_expression', 'motive' },
}) do
  positives[#positives + 1] = { spec[1], source(spec[2]), function(tree, text)
    local query = vim.treesitter.query.parse('bend2', '(' .. spec[4] .. ' ' .. spec[5] .. ': (lambda_expression) @lambda)')
    local values = {}
    for _, n in query:iter_captures(tree, text, 0, -1) do
      assert(vim.treesitter.get_node_text(n:field('parameter')[1], text) == 'x', 'lost lambda parameter')
      values[#values + 1] = vim.treesitter.get_node_text(n, text)
    end
    assert(vim.deep_equal(values, { 'x=>x' }), 'lambda operator stolen by block entry')
  end, source(spec[3]) }
end
for _, operand in ipairs({ 'x+1', 'x > 1', 'x% y' }) do
  positives[#positives + 1] = { 'law constraint owns full operand ' .. operand,
    source('law boundary:\n  for t:Type where 1n+' .. operand .. '\n  U32'), function(tree, text)
      local query = vim.treesitter.query.parse('bend2', '(law_clause constraint: (natural_successor value: (_) @operand))')
      local values = {}
      for _, n in query:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
      assert(vim.deep_equal(values, { operand }), 'constraint operator or operand stolen by block entry')
    end, source('law boundary:\n  for t:Type where (1n+' .. operand .. ')\n  U32') }
end
for _, spec in ipairs({
  { 'MOD proof field', 'def boundary()->T:%x% y:T;0', 'proof' },
  { 'MOD motive field', 'def boundary()->T:%e:x% y;0', 'motive' },
}) do
  positives[#positives + 1] = { spec[1], source(spec[2]), function(tree, text)
    local q = vim.treesitter.query.parse('bend2', '(rewrite_expression ' .. spec[3] .. ': (binary_expression) @operand)')
    local values = {}
    for _, n in q:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
    assert(vim.deep_equal(values, { 'x% y' }), 'MOD operator stolen from ' .. spec[3])
  end, source(spec[2]:gsub('x%% y', 'x& y')) }
end
-- Arithmetic is syntax even when Bend later requests an operator annotation.
positives[#positives + 1] = { 'annotated full MOD constraint operand',
  source('law boundary: for v:Type where (1n+x% y : Nat)\nT'), function(tree, text)
    local query = vim.treesitter.query.parse('bend2',
      '(law_clause constraint: (parenthesized_expression body: (body (natural_successor value: (binary_expression) @operand))))')
    local values = {}
    for _, n in query:iter_captures(tree, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
    assert(vim.deep_equal(values, { 'x% y' }), 'full MOD constraint operand truncated')
  end, source('law boundary: for v:Type where (1n+x& y : Nat)\nT') }
negatives[#negatives + 1] = { 'law trailing successor operand operator',
  source('type T<q> is Data: K{}\nlaw boundary:\n  for v:1n+v+\n  T'),
  source('type T<q> is Data: K{}\nlaw boundary:\n  for v:1n+v\n  T') }
positives[#positives + 1] = { 'law reusable next-line body remains separate',
  source('type T<q> is Data: K{}\nlaw boundary:\n  for v:1n+v\n  +T') }

negatives[#negatives + 1] = { 'hybrid missing law body retains header',
  source('law boundary: for v:T\n>1'), source('law boundary: for v:T\n1'), function(tree, text)
    local law
    for child in tree:iter_children() do
      local name = child:field('name')[1]
      if name and vim.treesitter.get_node_text(name, text) == 'boundary' then law = child end
    end
    local first, last = assert(text:find('law boundary: for v:T\r?\n>1'))
    local function exact(node, fragment, from)
      local a, b = assert(text:find(fragment, from or first, true))
      assert(node and not node:has_error() and select(3, node:start()) == a - 1
        and select(3, node:end_()) == b, 'law recovery corrupts intact field ' .. fragment)
    end
    assert(law and law:has_error() and select(3, law:start()) == first - 1
      and select(3, law:end_()) == last, 'edited law/header or native error lost')
    exact(law:field('name')[1], 'boundary')
    local clause
    for child in law:iter_children() do if child:type() == 'law_clause' then clause = child end end
    assert(clause and not clause:has_error(), 'intact law clause lost')
    exact(clause:field('name')[1], 'v', first + #'law boundary: for ')
    local term = clause:field('type')[1]
    -- The operator correctly extends the type; it is the BODY that is missing.
    assert(term and term:type() == 'binary_expression', 'clause comparison lost')
    exact(term, text:sub(assert(text:find('T', first, true)), last))
    exact(term:field('left')[1], 'T')
    exact(term:field('operator')[1], '>')
    exact(term:field('right')[1], '1')
    local body = law:field('body')[1]
    assert(body and body:has_error() and select(3, body:start()) == last
      and select(3, body:end_()) == last, 'missing law body borrowed real source')
    local missing = false
    local function errors(n)
      if n:type() == 'ERROR' or n:missing() then
        assert(select(3, n:start()) == last and select(3, n:end_()) == last,
          'law error overlaps intact header or next declaration')
        missing = true
      end
      for child in n:iter_children() do errors(child) end
    end
    errors(law)
    assert(missing, 'missing body has no native diagnostic')
    for file, wanted in pairs({ highlights = { 'function', 'variable.parameter', 'operator', 'number' },
      tags = { 'definition.function', 'name' }, folds = { 'fold' }, context = { 'context' },
      textobjects = { 'class.outer' }, locals = { 'local.scope', 'local.definition' }, indents = { 'indent.begin' } }) do
      local q = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/' .. file .. '.scm'), '\n'))
      local got = {}
      for id, n in q:iter_captures(law, text, 0, -1) do
        got[q.captures[id]] = n
      end
      for _, capture in ipairs(wanted) do
        assert(got[capture], 'lost law recovery capture ' .. file .. ' @' .. capture)
      end
      local capture = file == 'highlights' and got['function'] or file == 'tags' and got['name']
      if capture then exact(capture, 'boundary') end
      if file ~= 'highlights' and file ~= 'tags' then
        local n = got[wanted[1]]
        assert(select(3, n:start()) == first - 1 and select(3, n:end_()) == last,
          'changed law recovery capture boundary ' .. file)
      end
    end
  end, cycles = 3 }

for _, spec in ipairs({
  { 'law', 'law boundary: for v:g-!(x)\nT', 'law boundary: for v:g!(x)\nT' },
  { 'rewrite', 'def boundary()->T: %e:g-!(x);x', 'def boundary()->T: %e:g!(x);x' },
}) do
  negatives[#negatives + 1] = { 'hybrid real GPU recovery ' .. spec[1], source(spec[2]), source(spec[3]), function(tree, text)
    local query = vim.treesitter.query.parse('bend2', '(call_expression function: (identifier) @callee arguments: (arguments (gpu_call) @gpu) @arguments)')
    local values = {}
    for id, n in query:iter_captures(tree, text, 0, -1) do
      local capture = query.captures[id]
      values[capture] = vim.treesitter.get_node_text(n, text)
      if capture == 'arguments' then
        local closer
        for child in n:iter_children() do if child:type() == ')' and not child:missing() then closer = child end end
        assert(closer, 'real GPU closer no longer belongs to arguments')
      end
    end
    assert(vim.deep_equal(values, { callee = 'g', gpu = '!(', arguments = '!(x)' }), 'GPU call/delimiter ownership lost')
  end, cycles = 3 }
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
    local label, text = case[1] .. ' ' .. newline[1], lines(case[2] .. (case[4] and suffix or ''))
    check(label, function()
      local expected = parse(text)
      assert(not expected:has_error(), label .. ': legal syntax rejected')
      if type(case[3]) == 'function' then
        case[3](expected, text)
        check_following(expected, text, label)
        local control = lines(case[4] .. suffix)
        assert(not parse(control):has_error(), label .. ': invalid positive control')
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(control:sub(1, -2), '\n', { plain = true }))
        local parser = vim.treesitter.get_parser(buf, 'bend2')
        parser:parse()
        for _ = 1, 3 do
          edit(buf, control, text)
          local changed = parser:parse()[1]:root()
          assert(fingerprint(changed) == fingerprint(expected), label .. ': changed incremental ownership')
          case[3](changed, text)
          check_following(changed, text, label)
          edit(buf, text, control)
          assert(fingerprint(parser:parse()[1]:root()) == fingerprint(parse(control)), label .. ': positive control repair differs')
        end
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if case[1]:find('successor comment operator', 1, true) then
        local query = vim.treesitter.query.parse('bend2', '(natural_successor value: (_) @operand)')
        local values = {}
        for _, n in query:iter_captures(expected, text, 0, -1) do values[#values + 1] = vim.treesitter.get_node_text(n, text) end
        assert(vim.deep_equal(values, { 'x # between' .. newline[2] .. '  ' .. case[3] .. ' y' }), label .. ': changed successor operand/operator ownership')
      end
      if case[1]:find('closed-atom ampersand', 1, true) then
        local def = expected:named_child(2) or expected:named_child(1)
        local expression = def:field('body')[1]:named_child(0)
        assert(expression:type() == 'binary_expression', label .. ': lost binary expression')
        assert(vim.treesitter.get_node_text(expression:field('operator')[1], text) == '&', label .. ': lost ampersand field')
        local right = expression:field('right')[1]
        assert(right:type() == 'natural' and vim.treesitter.get_node_text(right, text):match('^[01]n$'), label .. ': split natural operand')
      end
      if case[1]:find('comma-free string', 1, true) then
        local query = vim.treesitter.query.parse('bend2', '(string) @literal')
        local captures = {}
        for _, n in query:iter_captures(expected, text, 0, -1) do
          captures[#captures + 1] = vim.treesitter.get_node_text(n, text)
        end
        assert(vim.deep_equal(captures, { '"a"', '"b"' }), label .. ': lost exact string nodes/ranges')
      end
      if not case[1]:find('arm-free eliminator', 1, true) then return end
      -- Adding an actual arm must invalidate a pattern, not silently widen it.
      local broken = text:gsub('\\{', '\\{Kk: a; ', 1)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text:sub(1, -2), '\n', { plain = true }))
      local parser = vim.treesitter.get_parser(buf, 'bend2')
      parser:parse()
      for _ = 1, 2 do
        edit(buf, text, broken)
        local changed = parser:parse()[1]:root()
        assert(changed:has_error(), label .. ': eliminator arm accepted as a pattern')
        assert(fingerprint(changed) == fingerprint(parse(broken)), label .. ': incremental arm rejection differs')
        edit(buf, broken, text)
        assert(fingerprint(parser:parse()[1]:root()) == fingerprint(expected), label .. ': identity repair differs')
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
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
        if case[4] then case[4](node, broken, label .. context) end
        -- Intact assignment headers must own the error and continuation.
        if case[2]:find('def boundary', 1, true) and case[2]:find(' = ', 1, true)
            and case[2]:find('\n  0', 1, true) then
          local crlf = newline[1] == 'CRLF'
          local first = assert(broken:find('def boundary', 1, true))
          local last = assert(broken:find(crlf and '\r\n  0\r\n' or '\n  0\n', first, true))
          last = last + (crlf and 4 or 3)
          local def
          for child in node:iter_children() do
            local name = child:field('name')[1]
            if name and vim.treesitter.get_node_text(name, broken) == 'boundary' then def = child end
          end
          assert(def and def:has_error(), label .. context .. ': edited function absent or falsely clean')
          assert(select(3, def:start()) == first - 1 and select(3, def:end_()) == last,
            label .. context .. ': edited function truncated or borrowed source')
          for _, field in ipairs({ 'name', 'parameters', 'return_type' }) do
            local parts = def:field(field)
            assert(#parts == 1 and not parts[1]:has_error(), label .. context .. ': damaged intact header ' .. field)
          end
          local highlights = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/highlights.scm'), '\n'))
          local captured = false
          for id, n in highlights:iter_captures(def, broken, 0, -1) do
            captured = captured or (highlights.captures[id] == 'number'
              and select(3, n:start()) == last - 1 and select(3, n:end_()) == last)
          end
          assert(captured, label .. context .. ': lost exact terminal number capture')
          local found = false
          local function terminal(n)
            if n:type() == 'ERROR' then return end
            if n:type() == 'body' and not n:has_error() and n:named_child_count() == 1 then
              local value = n:named_child(0)
              found = found or (value:type() == 'integer' and select(3, value:start()) == last - 1
                and select(3, value:end_()) == last)
            end
            for child in n:iter_children() do terminal(child) end
          end
          terminal(def:field('body')[1])
          assert(found, label .. context .. ': terminal integer detached from edited body')
        end
      end
      damaged(parse(broken), ' (fresh)')
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fixed:sub(1, -2), '\n', { plain = true }))
      local parser = vim.treesitter.get_parser(buf, 'bend2')
      assert(fingerprint(parser:parse()[1]:root()) == fingerprint(expected), label .. ': valid buffer differs from fresh parse')
      for _ = 1, case.cycles or 2 do
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
