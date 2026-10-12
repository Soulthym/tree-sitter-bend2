-- Error locality and highlight recovery, including real broken/repaired buffer
-- edits. Run from the repo after: tree-sitter build -o build/bend2.so
local root = vim.fn.getcwd()
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or (root .. '/build/bend2.so') })
local highlights = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/highlights.scm'), '\n'))

local cases = {
  { 'extra operator', 'def broken() -> U32: (1 + * 2 : U32)', 'def broken() -> U32: (1 + 2 : U32)' },
  { 'missing parenthesis', 'def broken() -> U32: (1 + 2', 'def broken() -> U32: (1 + 2)' },
  { 'missing let value', 'def broken() -> U32:\n  x =', 'def broken() -> U32:\n  x = 1; x' },
  { 'incomplete case pattern', 'def broken(x: T) -> U32:\n  match x:\n    case A{:', 'def broken(x: T) -> U32:\n  match x:\n    case A{}: 1' },
  { 'invalid character', 'def broken() -> U32: $', 'def broken() -> U32: 1' },
  { 'missing call closer', 'def broken() -> U32: g(1, 2', 'def broken() -> U32: g(1, 2)' },
  { 'missing function body', 'def broken() -> U32:', 'def broken() -> U32: 1' },
  { 'missing header colon', 'def broken() -> U32', 'def broken() -> U32: 1' },
  { 'missing function name', 'def () -> U32: 1', 'def broken() -> U32: 1' },
  { 'unfinished parameters', 'def broken(x: U32', 'def broken(x: U32) -> U32: x' },
  { 'unfinished type argument', 'def broken(x: List<U32', 'def broken(x: List<U32>) -> U32: 1' },
  { 'missing typed let value', 'def broken() -> U32:\n  x: U32 =', 'def broken() -> U32:\n  x: U32 = 1; x' },
  { 'missing parallel value', 'def broken() -> U32:\n  a b = g(1)', 'def broken() -> U32:\n  a b = g(1) g(2); a' },
  { 'unfinished do bind', 'def broken() -> IO(U32):\n  do IO<U32>:\n    x: U32 <-', 'def broken() -> IO(U32):\n  do IO<U32>:\n    x: U32 <- get(); return x' },
  { 'unfinished rewrite', 'def broken(e: P) -> P: %e :', 'def broken(e: P) -> P: %e : P; {==}' },
  { 'missing constructor closer', 'def broken() -> T: C{1', 'def broken() -> T: C{1}' },
  { 'missing list closer', 'def broken() -> T: [1, 2', 'def broken() -> T: [1, 2]' },
  { 'unfinished lambda', 'def broken() -> T: x =>', 'def broken() -> T: x => x' },
  { 'missing closing quote', 'def broken() -> String: "unfinished', 'def broken() -> String: "unfinished"' },
  { 'missing opening quote', 'def broken() -> String: text"', 'def broken() -> String: "text"' },
  { 'invalid escape', 'def broken() -> String: "\\q"', 'def broken() -> String: "\\n"' },
  { 'unfinished escape', 'def broken() -> String: "text\\', 'def broken() -> String: "text\\n"' },
  { 'multiline closing quote', 'def broken() -> String: "first\nsecond', 'def broken() -> String: "first\nsecond"' },
  { 'distant closing quote', 'def broken() -> String: "' .. ('line\n'):rep(400), 'def broken() -> String: "' .. ('line\n'):rep(400) .. '"' },
}
-- A rejected typo must not cost the surrounding declaration its useful CST.
for _, gap in ipairs({
  { 'space', ' ' }, { 'tab', '\t' }, { 'newline', '\n' },
  { 'CRLF', '\r\n' }, { 'comment', ' # comment\n' },
}) do
  local tail = '?(x: U32) -> U32:\n  g(7)'
  cases[#cases + 1] = { 'unsafe suffix after ' .. gap[1],
    'def broken' .. gap[2] .. tail, 'def broken' .. tail, false, true }
  local header = 'def broken(x: U32) -> U32:\n  g!'
  -- Baseline recovery leaves the invalid GPU prefix before the body field.
  -- Keep header/body highlights without pinning the damaged GPU-call tree.
  cases[#cases + 1] = { 'GPU opener after ' .. gap[1],
    header .. gap[2] .. '(7)', header .. '(7)', false, 'body_prefix' }
end
for _, op in ipairs({ '&', '|', '->' }) do
  local term = 'A ' .. op .. ' B'
  cases[#cases + 1] = { 'compound parameter argument ' .. op,
    'def broken(x: F<' .. term .. '>) -> U32:\n  g(7)',
    'def broken(x: F<(' .. term .. ')>) -> U32:\n  g(7)', false, 'parameter' }
  cases[#cases + 1] = { 'unfinished compound body argument ' .. op,
    'def broken(x: U32) -> U32:\n  F<' .. term,
    'def broken(x: U32) -> U32:\n  F<(' .. term .. ')>', false, 'body' }
end
-- An invalid do body must not swallow the next complete declaration header.
-- This is recovery coverage, not support for match/ordinary lets inside do.
local invalid_do = 'def broken(x: Bool) -> IO(Bool):\n  do IO<Bool>:\n'
  .. '    y = x\n    match x:\n      case False{}: return x\n'
  .. '      case True{}:\n        r : Bool <- work(x)\n        return r'
local valid_do = 'def broken(x: Bool) -> IO(Bool):\n  do IO<Bool>:\n    return x'
local definition_first = '\ndef after(x: U32) -> U32: g(42)\n'
  .. 'type Recovered is Data: Recovered{}\nlaw recovered_law: U32\n'
for _, crlf in ipairs({ false, true }) do
  cases[#cases + 1] = {
    'invalid nested do body ' .. (crlf and 'CRLF' or 'LF'),
    invalid_do, valid_do, suffix = definition_first, crlf = crlf,
  }
end
local structure_queries = {}
for file, capture in pairs({ folds = 'fold', tags = 'definition.function', context = 'context',
  textobjects = 'function.outer', locals = 'local.scope', indents = 'indent.begin' }) do
  structure_queries[file] = { capture = capture, query = vim.treesitter.query.parse('bend2',
    table.concat(vim.fn.readfile('queries/' .. file .. '.scm'), '\n')) }
end
-- Missing call/constructor closers must retain sibling arms and editor
-- captures. Other damaged-arm forms still promise only consistency/repair;
-- do not enshrine their current error trees.
for _, arm in ipairs({
  { 'missing let value', 'y =', 'y = 1; y' },
  { 'missing parenthesis', '(1 + 2', '(1 + 2)' },
  { 'missing call closer', 'g(1, 2', 'g(1, 2)', retain_siblings = true },
  { 'invalid character', '$', '1' },
  { 'missing constructor closer', 'C{1', 'C{1}', retain_siblings = true },
  { 'missing quote', '"unfinished', '"unfinished"' },
  { 'missing body', '', '1' },
}) do
  local start = 'def broken(x: T) -> U32:\n  match x:\n    case A{}:\n      '
  local finish = '\n    case B{}: 42\n    case C{}: 43'
  local retain = arm.retain_siblings
  for _, crlf in ipairs(retain and { false, true } or { false }) do
    cases[#cases + 1] = {
      'match arm: ' .. arm[1] .. (crlf and ' CRLF' or ' LF'),
      start .. arm[2] .. finish, start .. arm[3] .. finish, true, crlf = crlf,
      following_cases = retain and { ['B{}'] = '42', ['C{}'] = '43' } or nil,
    }
  end
end
local match_owner_columns = { ['B{}'] = 2, ['C{}'] = 2, ['InnerB{}'] = 6 }
for _, inner_sibling in ipairs({ false, true }) do
  for _, crlf in ipairs({ false, true }) do
    local start = 'def broken(x: T) -> U32:\n  match x:\n    case A{}:\n'
      .. '      match x:\n        case InnerA{}:\n          g(1, 2'
    local finish = (inner_sibling and '\n        case InnerB{}: 44' or '')
      .. '\n    case B{}: 42\n    case C{}: 43'
    local retained = { ['B{}'] = '42', ['C{}'] = '43' }
    if inner_sibling then retained['InnerB{}'] = '44' end
    cases[#cases + 1] = {
      (inner_sibling and 'inner' or 'outer') .. ' match boundary ' .. (crlf and 'CRLF' or 'LF'),
      start .. finish, start .. ')' .. finish, true, crlf = crlf,
      following_cases = retained, arm_owner_column = match_owner_columns,
    }
  end
end
-- PR #1 review regressions: each has a clean control and exercises both
-- newline encodings through the same twice-repeated minimal buffer edit below.
local function review_case(name, broken, fixed, options)
  for _, crlf in ipairs({ false, true }) do
    local case = { 'review ' .. name .. (crlf and ' CRLF' or ' LF'), broken, fixed, crlf = crlf }
    for key, value in pairs(options or {}) do case[key] = value end
    cases[#cases + 1] = case
  end
end
local match_start = 'def broken(x: T) -> U32:\n  match x:\n    case '
local match_finish = '\n    case B{}: 42\n    case C{}: 43'
local siblings = { ['B{}'] = '42', ['C{}'] = '43' }
review_case('1 invalid case pattern before immediate def',
  match_start .. '{}: g(x)' .. match_finish,
  match_start .. 'A{}: g(x)' .. match_finish,
  { suffix = definition_first })
review_case('1 missing case colon',
  match_start .. 'A{} g(1, 2)' .. match_finish,
  match_start .. 'A{}: g(1, 2)' .. match_finish,
  { suffix = definition_first, following_cases = { ['C{}'] = '43' } })
review_case('2 unfinished GPU prefix before immediate def',
  'def broken() -> U32: g!', 'def broken() -> U32: g!(1)',
  { suffix = definition_first })
review_case('3 missing function name with GPU body',
  'def (x: T) -> T: g!(x)', 'def broken(x: T) -> T: g!(x)',
  { suffix = definition_first })
review_case('3 missing function name after header comment',
  'def # header\n(x: T) -> T: g!(x)', 'def # header\nbroken(x: T) -> T: g!(x)',
  { suffix = definition_first })
review_case('5 invalid do before immediate decorated def', invalid_do, valid_do,
  { suffix = '\n@unsafe' .. definition_first })
for _, damage in ipairs({
  { '4 mistyped GPU opener', 'g!)1)', 'g!(1)' },
  { '6 missing let-value call closer', 'y = g(1\n      y', 'y = g(1)\n      y' },
}) do
  review_case(damage[1] .. ' with siblings',
    match_start .. 'A{}:\n      ' .. damage[2] .. match_finish,
    match_start .. 'A{}:\n      ' .. damage[3] .. match_finish,
    { following_cases = siblings })
  for _, inner_sibling in ipairs({ false, true }) do
    local start = match_start .. 'A{}:\n      match x:\n        case InnerA{}:\n          '
    local finish = (inner_sibling and '\n        case InnerB{}: 44' or '') .. match_finish
    local retained = { ['B{}'] = '42', ['C{}'] = '43' }
    if inner_sibling then retained['InnerB{}'] = '44' end
    review_case(damage[1] .. (inner_sibling and ' nested inner sibling' or ' nested outer boundary'),
      start .. damage[2]:gsub('\n      ', '\n          ') .. finish,
      start .. damage[3]:gsub('\n      ', '\n          ') .. finish,
      { following_cases = retained, arm_owner_column = match_owner_columns })
  end
end
for _, outer in ipairs({
  { 'grouping unfinished GPU', '(g!)', '(g)', 'parenthesized_expression' },
  { 'outer call unfinished GPU', 'wrap(g!)', 'wrap(g)', 'call_expression' },
  { 'outer call missing GPU opener', 'wrap(g!1)', 'wrap(g!(1))', 'call_expression' },
  { 'outer call missing closer after real inner GPU opener', 'wrap(g!(1)', 'wrap(g!(1))', 'call_expression', true },
}) do
  -- A real inner '!(' legitimately owns the first ')'. If one closer is
  -- absent, preserve normal nesting and report the missing outer closer;
  -- do not guess that the author meant this token for the outer expression.
  review_case('4 delimiter ownership ' .. outer[1],
    'def broken() -> T: ' .. outer[2], 'def broken() -> T: ' .. outer[3],
    { delimiter = { kind = outer[4], broken = outer[2], fixed = outer[3], inner_closer = outer[5] } })
  local start = match_start .. 'A{}:\n      match x:\n        case InnerA{}:\n          '
  local finish = '\n        case InnerB{}: 44' .. match_finish
  review_case('4 nested delimiter ownership ' .. outer[1], start .. outer[2] .. finish, start .. outer[3] .. finish,
    { following_cases = { ['InnerB{}'] = '44', ['B{}'] = '42', ['C{}'] = '43' },
      arm_owner_column = match_owner_columns,
      delimiter = { kind = outer[4], broken = outer[2], fixed = outer[3], inner_closer = outer[5] } })
end
-- Nearby damage found by differential probes must not regress shared guards.
local nested_match = '\n  match x:\n    case A{}:\n      match x:\n'
  .. '        case InnerA{}: g(1, 2)\n        case '
review_case('guard nested malformed header retains outer owner',
  'def broken(x: T) -> U32:' .. nested_match .. '{}: 44' .. match_finish,
  'def broken(x: T) -> U32:' .. nested_match .. 'InnerB{}: 44' .. match_finish,
  { following_cases = siblings, arm_owner_column = 2 })
review_case('guard damaged name prefix retains arms',
  match_start:gsub('^def ', 'def) ') .. 'A{}: C{1, 2}' .. match_finish,
  match_start .. 'A{}: C{1, 2}' .. match_finish,
  { following_cases = siblings, arm_owner_column = 2 })
review_case('guard inline declaration typo is not a restart',
  'law broken:\n  for x: T\n  match x:\n    case A{}: g!def (1, 2)' .. match_finish,
  'law broken:\n  for x: T\n  match x:\n    case A{}: g!(1, 2)' .. match_finish,
  { following_cases = siblings, arm_owner_column = 2 })
local anonymous_header = 'broken(x: T) -> U32:' .. nested_match .. 'InnerB{}: 44' .. match_finish
review_case('guard missing declaration keyword', anonymous_header, 'def ' .. anonymous_header)
review_case('guard stray inline decorator',
  'def broken() -> U32: 1 @unsafe garbage', 'def broken() -> U32: 1')
local annotation_body = 'def broken(x: T) -> U32:\n  a b = g!(x) g(x)\n  +m = h(a, b)\n  (m + 1 * 2'
review_case('guard unfinished GPU before annotation', annotation_body .. '! : U32)', annotation_body .. ' : U32)')
local typed_do = 'def broken(x: T) -> IO(U32):\n  do IO<U32>:\n    x'
review_case('guard real GPU prefix during do recovery',
  typed_do .. ' U32 <- g!(1)\n    return x', typed_do .. ': U32 <- g!(1)\n    return x')
for _, declaration in ipairs({ 'type Extra is Data: Extra{}', 'law extra: U32' }) do
  review_case('guard decorator on wrong declaration ' .. declaration,
    invalid_do .. '\n@unsafe ' .. declaration, valid_do .. '\n' .. declaration)
end
-- PR #2: a malformed parallel value must not eat an immediately following
-- definition, including name forms admitted by zero/empty-call identities.
for _, pattern in ipairs({
  'x y', '+x y', '(x) y', '(x : U32) y', 'x() y', 'x()() y',
  '0n+x y', '00n+0n+x y', '0n++x y', '0n+x() y',
}) do
  local start = 'def broken(a,b):\n  ' .. pattern .. ' = a b'
  review_case('2 malformed parallel value ' .. pattern,
    start .. ' $\n  0', start .. '\n  0',
    { prefix = '', suffix = '\ndef after():\n  42\n', retained_integer_function = 'def after():\n  42' })
end
-- Rejection of expression-shaped targets must preserve the unaffected final
-- integer as the edited function's body, rather than retaining the bad target.
for _, target in ipairs({ 'f(1)', 'f()(1)', '(f(1))', 'f[0]' }) do
  local start = 'import Base\n\ndef boundary(b: U32) -> U32:\n  '
  review_case('2 malformed assignment final body ' .. target,
    start .. target .. ' = 3\n  0', start .. 'x = 3\n  0',
    { prefix = '', suffix = '\n\ndef after() -> U32:\n  42\n',
      retained_integer_function = 'def after() -> U32:\n  42',
      edited_integer_function = 'def boundary(b: U32) -> U32:\n  ' .. target .. ' = 3\n  0',
      damaged_line = target .. ' = 3' })
end
for _, natural in ipairs({ '0n', '1n' }) do
  review_case('2 unfinished natural successor ' .. natural,
    'def broken(p: Nat) -> Nat:\n  ' .. natural .. '+',
    'def broken(p: Nat) -> Nat:\n  ' .. natural .. '+p')
end
review_case('6 damaged grouped case pattern',
  match_start .. '(x $): 0n' .. match_finish,
  match_start .. '(x): 0n' .. match_finish,
  { suffix = definition_first, following_cases = siblings, arm_owner_column = 2 })
local grouped_inner = match_start .. 'A{}:\n      match x:\n        case '
review_case('6 damaged nested grouped case pattern',
  grouped_inner .. '(x $): 0n\n        case InnerB{}: 44' .. match_finish,
  grouped_inner .. '(x): 0n\n        case InnerB{}: 44' .. match_finish,
  { suffix = definition_first, following_cases = { ['InnerB{}'] = '44', ['B{}'] = '42', ['C{}'] = '43' },
    arm_owner_column = match_owner_columns })
review_case('5 damaged array in case before immediate def',
  'def broken(x: T) -> U32:\n  match x:\n    case x: [a : U32 = x\n  0',
  'def broken(x: T) -> U32:\n  match x:\n    case x: [a : U32 * x]',
  { suffix = definition_first })
review_case('5 damaged nested array before immediate def',
  'def broken(x: T) -> U32:\n  match x:\n    case x:\n      match x:\n        case x: [a : U32 = x\n  0',
  'def broken(x: T) -> U32:\n  match x:\n    case x:\n      match x:\n        case x: [a : U32 * x]',
  { suffix = definition_first })
review_case('4 damaged parallel value before immediate def',
  'def broken(x: T) -> U32:\n  a b = x x $',
  'def broken(x: T) -> U32:\n  a b = x x\n  0',
  { suffix = definition_first })
review_case('4 damaged parallel value before immediate decorated def',
  'def broken(x: T) -> U32:\n  a b = x x $',
  'def broken(x: T) -> U32:\n  a b = x x\n  0',
  { suffix = '\n@unsafe' .. definition_first })
for _, literal in ipairs({
  { '"hi"', 'String', 'string', 'string' },
  { "'a'", 'Char', 'character', 'character' },
  { '1.5', 'F32', 'float', 'number.float' },
  { '1n', 'Nat', 'natural', 'number' },
}) do
  local start = 'def boundary(b: U32) -> ' .. literal[2] .. ':\n  '
  local broken = start .. 'f(1) = 3\n  ' .. literal[1]
  review_case('7 invalid assignment intact literal ' .. literal[3], broken,
    start .. 'x = 3\n  ' .. literal[1],
    { prefix = '', suffix = '\ndef after() -> U32: 42\n',
      retained_integer_function = 'def after() -> U32: 42',
      edited_integer_function = broken, damaged_line = 'f(1) = 3', terminal = literal })
end
review_case('design damaged lambda successor before fresh header',
  'def broken() -> Nat -> Nat:\n  $x => 1n+x',
  'def broken() -> Nat -> Nat:\n  x => 1n+x',
  { prefix = '', suffix = '\ndef after(): 42\n', retained_integer_function = 'def after(): 42', owned = true })
review_case('design malformed array with intact string before fresh header',
  'def broken(x: T):\n  [a : U32 = x\n  "s"',
  'def broken(x: T):\n  [a : U32 * x]',
  { prefix = '', suffix = '\ndef after(): 42\n', retained_integer_function = 'def after(): 42', owned = true })
for _, damage in ipairs({
  { 'array natural tail', 'def broken(x: T):\n  [a : U32 = x\n  0n+x', 'def broken(x: T):\n  [a : U32 * x]' },
  { 'array literal tail', 'def broken(x: T):\n  [a : U32 = x\n  0n', 'def broken(x: T):\n  [a : U32 * x]' },
  { 'eliminator grouped damage', 'def broken(x: T):\n  (\\{x} $)', 'def broken(x: T):\n  (\\{x})' },
  { 'extra assignment', 'def broken(x: Nat, y: Nat) -> Nat:\n  x = y = x x\n  0',
    'def broken(x: Nat, y: Nat) -> Nat:\n  x = y; x = x\n  0' },
}) do
  review_case('structural ' .. damage[1], damage[2], damage[3],
    { prefix = '', suffix = '\ndef after(): 42\n', retained_integer_function = 'def after(): 42', owned = true })
end
for _, terminal in ipairs({ '"s"', 'Type' }) do
  local start = 'def broken(x: T, y: T) -> T:\n  '
  review_case('structural extra assignment terminal ' .. terminal,
    start .. 'x = y = x x\n  ' .. terminal, start .. 'x = y; x = x\n  ' .. terminal,
    { prefix = '', suffix = '\ndef after(): 42\n', retained_integer_function = 'def after(): 42', owned = true })
end
-- Body-entry ownership must work for every lexical term family, not only numbers.
for _, term in ipairs({
  { '"s"', 'string', { { 'string', '"s"', 0 } } },
  { '"first\\nlast"', 'string', { { 'string', '"first\\nlast"', 0 } } },
  { '"first\n  last"', 'string', { { 'string', '"first\n  last"', 0 } } },
  { "'a'", 'character', { { 'character', "'a'", 0 } } },
  { '1.5', 'float', { { 'number.float', '1.5', 0 } } },
  { '0n', 'natural', { { 'number', '0n', 0 } } },
  { '1n+x', 'natural_successor', { { 'number', '1n', 0 } } },
  { 'Type', 'builtin_type', { { 'type.builtin', 'Type', 0 } } },
  { 'Data', 'builtin_type', { { 'type.builtin', 'Data', 0 } } },
  { 'Quant', 'builtin_type', { { 'type.builtin', 'Quant', 0 } } },
  { 'Kind(Type)', 'kind_expression', { { 'type.builtin', 'Kind', 0 }, { 'type.builtin', 'Type', 0 } } },
  { '(x)', 'parenthesized_expression', { { 'variable', 'x', 0 } } },
  { '(x, x)', 'tuple_expression', { { 'variable', 'x', 0 } } },
  { 'g(x)', 'call_expression', { { 'function.call', 'g', 0 } } },
  { '[x, x]', 'list_expression', { { 'variable', 'x', 0 } } },
  { 'z => z', 'lambda_expression', { { 'variable.parameter', 'z', 0 } } },
  { '&2', 'quantity', { { 'constant.builtin', '&2', 0 } } },
  { '\\{x}', 'eliminator', { { 'variable', 'x', 0 } } },
  { '+x', 'reusable_expression', { { 'operator', '+', 0 } } },
  { 'g!(x)', 'call_expression', { { 'function.call', 'g', 0 }, { 'keyword.modifier', '!', 0 } } },
  { '[x : U32 ^ 2]', 'array_expression', { { 'number', '2', 11 } } },
}) do
  for _, nested in ipairs({ false, true }) do
    local start = 'def broken(x:T) -> U32:\n' .. (nested and '  match x:\n    case B{}:\n      ' or '  ')
    local indentation = nested and '\n      ' or '\n  '
    local terminal = term[1]:gsub('\n', indentation)
    local captures = vim.deepcopy(term[3])
    for _, capture in ipairs(captures) do capture[2] = capture[2]:gsub('\n', indentation) end
    local separator = term[1] == '&2' and ';' or ''
    local finish = nested and '\n    case C{}: 43' or ''
    review_case('body entry ' .. (nested and 'nested ' or '') .. term[2] .. ' ' .. term[1],
      start .. 'x=y=x x' .. separator .. indentation .. terminal .. finish,
      start .. 'x y=x x' .. separator .. indentation .. terminal .. finish,
      { owned = true, terminal_expression = { terminal, term[2], captures }, damaged_line = 'x=y=x x',
        following_cases = nested and { ['C{}'] = '43' } or nil, arm_owner_column = 2 })
  end
end
for _, pattern in ipairs({
  { 'incomplete annotation', '(x:)', '(x: T)' },
  { 'successor tuple closer', '[1n+(x,y]', '[1n+(x,y)]' },
  { 'zero successor tuple closer', '[0n+(x,y]', '[0n+(x,y)]' },
  { 'eliminator fallback', '\\{($x)}', '\\{(x)}' },
  { 'eliminator opener', '\\1{x}', '\\{x}' },
}) do
  local start = 'def broken(x: T):\n  match x:\n    case '
  local finish = '\n    case y: 42\n    case z: 43'
  review_case('structural ' .. pattern[1], start .. pattern[2] .. ': 0' .. finish,
    start .. pattern[3] .. ': 0' .. finish,
    { prefix = '', suffix = '\ndef after(): 42\n', retained_integer_function = 'def after(): 42',
      following_cases = { y = '42', z = '43' }, arm_owner_column = 2, owned = true })
end
-- Final review: preserve fresh headers and real sibling owners after damage.
local typed_review_header = 'def broken(x: T) -> T: '
local law_review_header = 'law broken: U32\nlaw after: U32\ndef broken(): '
for _, spec in ipairs({
  { 'nested array missing size', typed_review_header, '[x:[x:T 2n]^2n]', '[x:[x:T^2n]^2n]' },
  { 'zero successor unfinished rewrite', typed_review_header, '[0n+%,x]', '[0n+%e:T;x,x]' },
  { 'nonzero successor unfinished rewrite', typed_review_header, '[1n+%,x]', '[1n+%e:T;x,x]' },
  { 'let missing group closer', typed_review_header, 'x=x;(x', 'x=x;(x)' },
  { 'parallel missing value group', typed_review_header, 'x y=x( x;x', 'x y=x x;x' },
  { 'rewrite unfinished let', typed_review_header, '%e:T;x=', '%e:T;x=x;x' },
  { 'law rewrite unfinished header', law_review_header, '[%e:T;x x]', '[%e:T;x]' },
  { 'law let array missing size', law_review_header, 'a = [x: U32 2n]; a', 'a = [x: U32 * 2n]; a' },
  { 'law parallel damaged annotation', law_review_header, 'a b = (x: T$ x; a', 'a b = (x: T) x; a' },
  { 'law parallel missing eliminator closer', law_review_header, 'a b = \\{x: x; y x; a', 'a b = \\{x: x; y} x; a' },
  { 'law eliminator lambda unfinished header', law_review_header, '\\{x: x => x x}', '\\{x: x => x}' },
  { 'law rewrite array unfinished header', law_review_header, '[%x: T; x T ^ 2]', '[%x: T; x]' },
}) do
  review_case('third review ' .. spec[1], spec[2] .. spec[3], spec[2] .. spec[4],
    { prefix = '', suffix = '\ndef after() -> U32: 42\n', retained_integer_function = 'def after() -> U32: 42' })
end
local match_review_header = 'type T is Data: A{} B{} C{}\ndef broken(x: T) -> U32:\n  match x:\n    case '
local match_review_tail = '\n    case B{}: 42\n    case C{}: 43'
for _, spec in ipairs({
  { 'damaged closed kind array', 'A{}: [x:K$ind(Type)^2n]', 'A{}: [x:Kind(Type)^2n]' },
  { 'missing successor operator', 'A{}: 1n+1n$x', 'A{}: 1n+1n+x' },
  { 'leading case body semicolon', 'A{}: ;[x:T^2n]', 'A{}: [x:T^2n]' },
  { 'replaced case colon before natural', 'A{}) 0n', 'A{}: 0n' },
}) do
  review_case('third review ' .. spec[1], match_review_header .. spec[2] .. match_review_tail,
    match_review_header .. spec[3] .. match_review_tail,
    { prefix = '', suffix = '\ndef after() -> U32: 42\n', retained_integer_function = 'def after() -> U32: 42',
      following_cases = { ['B{}'] = '42', ['C{}'] = '43' }, arm_owner_column = 2 })
end
-- Ownership inventory: introduced losses must not be hidden by broad-suite counts.
-- Fixed vectors from the pre-change inventory; no expectation is weakened.
for index, term in ipairs({
  { "[x: K=ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K:ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K;ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K,ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K)ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K]ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: K}ind(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki=nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki:nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki;nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki,nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki)nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki]nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "[x: Ki}nd(Type) ^ 2n]", "[x: Kind(Type) ^ 2n]" },
  { "1n+x\n[0]", "1n+x[0]" },
  { "1n+ x\\{x}", "1n+\\{x}" },
  { "1n++x\\{x}", "1n+\\{x}" },
  { "1n+\\{x}}", "1n+\\{x}" },
  { "1n+\\{x};", "1n+\\{x}" },
  { "1n+\\{x},", "1n+\\{x}" },
  { "1n+\\{x})", "1n+\\{x}" },
  { "1n+\\{x}]", "1n+\\{x}" },
  { "1n+ x@a:Type->a", "1n+@a:Type->a" },
  { "1n++x@a:Type->a", "1n+@a:Type->a" },
  { "1n+g\n(x => x)", "1n+g(x => x)" },
  { "1n+g()x => x)", "1n+g(x => x)" },
  { "1n+1n\nx", "1n+1n+x" },
  { "0n+0n\nx", "0n+0n+x" },
}) do
  review_case('arm ownership inventory ' .. index, match_review_header .. 'A{}: ' .. term[1] .. match_review_tail,
    match_review_header .. 'A{}: ' .. term[2] .. match_review_tail,
    { suffix = definition_first,
      following_cases = { ['B{}'] = '42', ['C{}'] = '43' }, arm_owner_column = 2 })
end
-- A dedented orphan after a completed match must stay outside that function,
-- regardless of the later root token. Do not predict a future case/header.
for _, value in ipairs({ '1n+1n', '42', 'x' }) do
  for _, orphan in ipairs({ 'x', '2', ';', '$', '^' }) do
    for _, ending in ipairs({ 'ordinary', 'decorated', 'EOF' }) do
      local before = 'def before(x: T) -> U32:\n  match x:\n    case A{}: ' .. value
      review_case('completed match boundary ' .. value .. ' ' .. orphan .. ' ' .. ending, orphan, '',
        { prefix = before .. '\n', preceding_function = before,
          suffix = ending == 'EOF' and '\n' or (ending == 'decorated' and '\n@unsafe' .. definition_first or definition_first),
          orphan_eof = ending == 'EOF' })
    end
  end
end
local caller_prelude = 'type T is Data: A{} B{} C{}\ntype Wrap is Data: Wrap{v:T}\ndef broken(x:Wrap)->U32:\n'
local inner_match = '  match x:\n    case Wrap{v}:\n      match v:\n        case A{}: '
for _, spec in ipairs({
  { 'let terminal match', '  Wrap{v}=x;\n  match v:\n    case A{}: 1n+1n\n2\n    case C{}: 43',
    '  Wrap{v}=x;\n  match v:\n    case A{}: 1n+1n\n    case C{}: 43', 2 },
  { 'nested terminal match', inner_match .. '1n+1n\n2\n        case C{}: 43',
    inner_match .. '1n+1n\n        case C{}: 43', 6 },
  { 'incomplete nested lambda', inner_match .. 'z => a=vv\n        case C{}: 43',
    inner_match .. 'z => a=v;v\n        case C{}: 43', 6,
    { 'lambda_expression', 'z => a=vv', { parameter = 'z' } } },
  { 'incomplete nested writer group', inner_match .. 'a[0]<(-v;v\n        case B{}: 42\n        case C{}: 43',
    inner_match .. 'a[0]<-v;v\n        case B{}: 42\n        case C{}: 43', 6 },
  { 'attached successor erasure', '  match x:\n    case A{}:1n+x~\n    case B{}:42',
    '  match x:\n    case A{}:1n+x\n    case B{}:42', 2 },
}) do
  review_case('fifth review ' .. spec[1], caller_prelude .. spec[2], caller_prelude .. spec[3],
    { prefix = '', suffix = '\ndef after()->U32:42\n', retained_integer_function = 'def after()->U32:42',
      following_cases = spec[1] == 'attached successor erasure' and { ['B{}'] = '42' } or { ['C{}'] = '43' },
      arm_owner_column = spec[4], retained_construct = spec[5] })
end
for _, spec in ipairs({
  { 'array dependent skipped header', caller_prelude .. inner_match .. '[v:@a:Type->(a=)^2n]\n        case C{}: 43\n    case w: 0',
    caller_prelude .. inner_match .. '[v:@a:Type->(a)^2n]\n        case C{}: 43\n    case w: 0' },
  { 'law parallel skipped header', 'law broken:\n  for v:T\n  a b=(v v;a', 'law broken:\n  for v:T\n  a b=v v;a' },
  { 'array owned type damage', 'def broken(x:T)->U32: [x:K=ind(Type)^2n]',
    'def broken(x:T)->U32: [x:Kind(Type)^2n]',
    { 'array_expression', '[x:K=ind(Type)^2n]', { value = 'x', size = '2n' }, { '[', '^', ']' } } },
  { 'annotated group owned let', 'def broken(v:T)->U32: (\n2\na=v;v:T)',
    'def broken(v:T)->U32: (\na=v;v:T)',
    { 'parenthesized_expression', '(\n2\na=v;v:T)', { body = 'a=v;v', type = 'T' }, { '(', ')' } } },
}) do
  review_case('fifth review ' .. spec[1], spec[2], spec[3],
    { prefix = '', suffix = '\ndef after()->U32:42\n', retained_integer_function = 'def after()->U32:42',
      retained_construct = spec[4] })
end
for _, ending in ipairs({ 'ordinary', 'decorated', 'EOF' }) do
  local before = 'def before(a: Array<U32>) -> Array<U32>:\n  a[0] <- 42'
  review_case('terminal write root mask ' .. ending, '$', '',
    { prefix = before .. '\n', preceding_function = before,
      suffix = ending == 'EOF' and '\n' or (ending == 'decorated' and '\n@unsafe' .. definition_first or definition_first),
      orphan_eof = ending == 'EOF' })
end
for _, depth in ipairs({ 5, 10 }) do
  local source = 'type W is Data: W{v:W} C{}\ndef broken(x:W)->Nat:\n'
  for level = 1, depth do
    local column = 2 + 6 * (level - 1)
    source = source .. (' '):rep(column) .. 'match ' .. (level == 1 and 'x' or ('v' .. (level - 2))) .. ':\n'
      .. (' '):rep(column + 2) .. 'case W{v' .. (level - 1) .. '}:\n'
  end
  source = source .. (' '):rep(2 + 6 * depth) .. '1n+1n\n'
  local tail = (' '):rep(4 + 6 * (depth - 1)) .. 'case C{}: 0n'
  review_case('nested transfer depth ' .. depth, source .. '2\n' .. tail, source .. tail,
    { prefix = '', suffix = '\ndef after()->U32:42\n', retained_integer_function = 'def after()->U32:42',
      following_cases = { ['C{}'] = '0n' }, arm_owner_column = 2 + 6 * (depth - 1) })
end
for _, terminal in ipairs({
  { 'String', 'U32', '"s"', 'string', { { 'string', '"s"', 0 } } },
  { 'Nat', 'Nat', '0n+x', 'natural_successor', { { 'number', '0n', 0 }, { 'operator', '+', 2 }, { 'variable', 'x', 3 } } },
  { 'Nat', 'Nat', '0n', 'natural', { { 'number', '0n', 0 } } },
}) do
  local header = 'def broken(x:' .. terminal[2] .. ') -> ' .. terminal[1] .. ':\n  '
  local assignment = 'a:' .. terminal[2] .. '=x'
  review_case('tight array typed assignment ' .. terminal[3], header .. '[' .. assignment .. '\n  ' .. terminal[3],
    header .. assignment .. '\n  ' .. terminal[3],
    { prefix = 'law after: U32\ndef before() -> U32: 1\n', suffix = '\ndef after(): 42\n',
      retained_integer_function = 'def after(): 42', owned = true, damaged_line = '[' .. assignment,
      terminal_expression = { terminal[3], terminal[4], terminal[5] } })
end
for _, successor in ipairs({ '1n+n', '0n+n' }) do
  for _, orphan in ipairs({ 'oops', '2', 'x y', '"hi"', "'a'" }) do
    for _, ending in ipairs({ 'ordinary', 'decorated', 'EOF' }) do
      local before = 'def before(n: Nat) -> Nat: ' .. successor
      review_case('structural orphan ' .. successor .. ' ' .. orphan .. ' ' .. ending, orphan, '',
        { prefix = before .. '\n', preceding_function = before,
          suffix = ending == 'EOF' and '\n' or (ending == 'decorated' and '\n@unsafe' .. definition_first or definition_first),
          orphan_eof = ending == 'EOF' })
    end
  end
end
review_case('final orphan numeric keeps preceding function clean', '2', '', {})
review_case('final orphan name keeps completed successor function clean', 'oops', '',
  { prefix = 'def before(n: Nat) -> Nat: 1n+n\n' })
local prefix = 'def before() -> U32: 1\n'
local suffix = '\n' .. [[
type Recovered is Data: Recovered{}
law recovered_law: U32
@unsafe
def after(x: U32) -> U32: g(42)
]]

local function parse(text)
  return vim.treesitter.get_string_parser(text, 'bend2'):parse()[1]:root()
end
local function signature(node)
  local result = { node:type(), { node:range() }, node:missing() }
  for child, field in node:iter_children() do result[#result + 1] = { field or '', signature(child) } end
  return result
end
local function position(text, offset)
  local preceding = text:sub(1, offset)
  local _, row = preceding:gsub('\n', '')
  return row, #preceding - (preceding:match('.*\n()') or 1) + 1
end
-- Source offsets are independent of the recovered tree. Comparing text alone
-- would miss borrowed fields or captures extending into a damaged neighbor.
local function check_range(node, text, first, last, label)
  assert(node, label .. ': missing node')
  local sr, sc = position(text, first - 1)
  local er, ec = position(text, last)
  local _, _, a = node:start()
  local _, _, b = node:end_()
  assert(a == first - 1 and b == last and vim.deep_equal({ node:range() }, { sr, sc, er, ec }),
    label .. ': wrong range for ' .. node:type())
end
local function source_range(text, fragment, from)
  local first, last = text:find(fragment, from or 1, true)
  assert(first, 'fixture missing source fragment: ' .. fragment)
  return first, last
end
local function check_capture(query, node, text, name, first, last, label)
  for id, capture in query:iter_captures(node, text, 0, -1) do
    local _, _, a = capture:start()
    local _, _, b = capture:end_()
    if query.captures[id] == name and a == first - 1 and b == last then
      check_range(capture, text, first, last, label .. ' @' .. name)
      return
    end
  end
  error(label .. ': lost exact capture @' .. name .. ' at bytes ' .. (first - 1) .. '..' .. last)
end
local function check_intact_function(def, text, label)
  local declaration = 'def after(x: U32) -> U32: g(42)'
  local first, last = source_range(text, declaration)
  local header = first
  local decorator = text:sub(1, first - 1):match('@unsafe\r?\n$')
  if decorator then first = first - #decorator end
  assert(def:type() == 'function_definition', label .. ': wrong intact definition type')
  check_range(def, text, first, last, label .. ' after definition')
  local parts = {}
  for _, spec in ipairs({
    { 'name', 'after' }, { 'parameters', '(x: U32)' },
    { 'return_type', 'U32', header + #('def after(x: U32) -> ') }, { 'body', 'g(42)' },
  }) do
    local a, b = source_range(text, spec[2], spec[3] or header)
    local field = def:field(spec[1])
    assert(#field == 1 and not field[1]:has_error(), label .. ': damaged after field ' .. spec[1])
    check_range(field[1], text, a, b, label .. ' after field ' .. spec[1])
    parts[spec[1]] = { a, b, field[1] }
  end
  local parameter = parts.parameters[3]:named_child(0)
  local x = header + #('def after(')
  check_range(parameter, text, x, x + #('x: U32') - 1, label .. ' after parameter')
  check_range(parameter:field('name')[1], text, x, x, label .. ' after parameter name')
  check_range(parameter:field('type')[1], text, x + 3, x + 5, label .. ' after parameter type')
  local body = parts.body[1]
  for _, spec in ipairs({
    { 'function', parts.name[1], parts.name[2] }, { 'variable.parameter', x, x },
    { 'function.call', body, body }, { 'number', body + 2, body + 3 },
  }) do
    check_capture(highlights, def, text, spec[1], spec[2], spec[3], label .. ' after highlights')
  end
  for file, captures in pairs({
    folds = { { 'fold', first, last } },
    tags = { { 'definition.function', first, last }, { 'name', parts.name[1], parts.name[2] },
      { 'reference.call', body, parts.body[2] }, { 'name', body, body } },
    context = { { 'context', first, last }, { 'context.end', body, parts.body[2] } },
    textobjects = { { 'function.outer', first, last }, { 'function.inner', body, parts.body[2] },
      { 'parameter.outer', x, x + 5 }, { 'parameter.inner', x, x + 5 },
      { 'call.outer', body, parts.body[2] }, { 'call.inner', body + 2, body + 3 } },
    locals = { { 'local.scope', first, last }, { 'local.definition', x, x },
      { 'local.reference', parts.name[1], parts.name[2] }, { 'local.reference', body, body } },
    indents = { { 'indent.begin', first, last },
      { 'indent.align', parts.parameters[1], parts.parameters[2] },
      { 'indent.align', body + 1, parts.body[2] } },
  }) do
    for _, spec in ipairs(captures) do
      check_capture(structure_queries[file].query, def, text, spec[1], spec[2], spec[3], label .. ' after ' .. file)
    end
  end
  local decorations = {}
  for child in def:iter_children() do
    if child:type() == 'decorator' then decorations[#decorations + 1] = child end
  end
  assert(#decorations == (decorator and 1 or 0), label .. ': changed after decorator')
  if decorator then
    check_range(decorations[1], text, first, first + 6, label .. ' after decorator')
    check_capture(highlights, def, text, 'attribute', first, first + 6, label .. ' after decorator highlight')
  end
end
-- Exact public fields/captures for the small PR #2 boundary fixtures. Unlike
-- consistency alone, these assertions detect a stable but swallowed body.
local function check_literal_function(node, text, label, declaration, damaged_line, terminal)
  if text:find('\r\n', 1, true) then declaration = declaration:gsub('\n', '\r\n') end
  local name, parameters, return_type = declaration:match('^def ([%w_]+)(%b())%s*%-%>%s*([%w_]+):')
  if not name then name, parameters = declaration:match('^def ([%w_]+)(%b()):') end
  local first, last = source_range(text, declaration)
  local def
  for child in node:iter_children() do
    local field = child:field('name')[1]
    if field and vim.treesitter.get_node_text(field, text) == name then def = child end
  end
  assert(def and def:type() == 'function_definition', label .. ': lost integer function ' .. name)
  assert(def:has_error() == (damaged_line ~= nil), label .. ': wrong error ownership in ' .. name)
  check_range(def, text, first, last, label .. ' integer definition')
  local fields = {}
  for _, spec in ipairs({
    { 'name', name, first + 4 }, { 'parameters', parameters, first + 4 + #name },
  }) do
    local a, b = source_range(text, spec[2], spec[3])
    local field = def:field(spec[1])
    assert(#field == 1 and not field[1]:has_error(), label .. ': damaged integer function ' .. spec[1])
    check_range(field[1], text, a, b, label .. ' integer ' .. spec[1])
    fields[spec[1]] = { a, b, field[1] }
  end
  if return_type then
    local a, b = source_range(text, return_type, fields.parameters[2] + 1)
    local field = def:field('return_type')
    assert(#field == 1 and not field[1]:has_error(), label .. ': damaged integer return type')
    check_range(field[1], text, a, b, label .. ' integer return type')
  else
    assert(#def:field('return_type') == 0, label .. ': invented integer return type')
  end
  if parameters == '(b: U32)' then
    local parameter = fields.parameters[3]:named_child(0)
    local a = fields.parameters[1] + 1
    check_range(parameter, text, a, a + 5, label .. ' intact parameter')
    check_range(parameter:field('name')[1], text, a, a, label .. ' intact parameter name')
    check_range(parameter:field('type')[1], text, a + 3, a + 5, label .. ' intact parameter type')
    check_capture(highlights, def, text, 'variable.parameter', a, a, label)
  else
    assert(fields.parameters[3]:named_child_count() == 0, label .. ': invented empty parameter')
  end
  local literal = terminal and terminal[1] or assert(declaration:match('(%d+)$'))
  local kind = terminal and terminal[3] or 'integer'
  local highlight = terminal and terminal[4] or 'number'
  local body_first = last - #literal + 1
  local body = def:field('body')
  assert(#body == 1, label .. ': missing integer function body')
  local integer
  local damaged_first = damaged_line and source_range(text, damaged_line, fields.parameters[2]) or nil
  if damaged_line then
    local function find_terminal(node)
      if node:type() == 'ERROR' then return end
      local _, _, a = node:start()
      local _, _, b = node:end_()
      if node:type() == 'body' and a == body_first - 1 and b == last
          and not node:has_error() and node:named_child_count() == 1 then
        local value = node:named_child(0)
        if value:type() == kind then return value end
      end
      for child in node:iter_children() do
        local value = find_terminal(child)
        if value then return value end
      end
    end
    integer = find_terminal(body[1])
    assert(integer, label .. ': lost clean terminal integer body node')
    local _, _, a = body[1]:start()
    local _, _, b = body[1]:end_()
    assert(body[1]:type() == 'body' and a >= damaged_first - 1
      and a <= body_first - 1 and b == last, label .. ': body crosses unaffected source boundaries')
  else
    assert(not body[1]:has_error(), label .. ': damaged unaffected integer body')
    check_range(body[1], text, body_first, last, label .. ' integer body')
    integer = body[1]:named_child(0)
    assert(body[1]:named_child_count() == 1, label .. ': extra clean integer body nodes')
  end
  assert(integer and integer:type() == kind, label .. ': lost terminal ' .. kind .. ' body node')
  check_range(integer, text, body_first, last, label .. ' integer node')
  check_capture(highlights, def, text, 'function', fields.name[1], fields.name[2], label)
  check_capture(highlights, def, text, highlight, body_first, last, label)
  for file, captures in pairs({
    folds = { { 'fold', first, last } },
    tags = { { 'definition.function', first, last }, { 'name', fields.name[1], fields.name[2] } },
    context = { { 'context', first, last } },
    textobjects = { { 'function.outer', first, last } },
    locals = { { 'local.scope', first, last }, { 'local.reference', fields.name[1], fields.name[2] } },
    indents = { { 'indent.begin', first, last },
      { 'indent.align', fields.parameters[1], fields.parameters[2] } },
  }) do
    for _, spec in ipairs(captures) do
      check_capture(structure_queries[file].query, def, text, spec[1], spec[2], spec[3], label .. ' ' .. file)
    end
  end
  for file, capture_name in pairs({ context = 'context.end', textobjects = 'function.inner' }) do
    local query = structure_queries[file].query
    local found = false
    for id, capture in query:iter_captures(def, text, 0, -1) do
      if query.captures[id] == capture_name then
        local _, _, a = capture:start()
        local _, _, b = capture:end_()
        -- Recovery may omit part of the invalid target, but must include the
        -- terminal value without crossing the header or following declaration.
        local lower = damaged_first or body_first
        if b == last and a >= lower - 1 and a <= body_first - 1 then
          found = true
        end
      end
    end
    assert(found, label .. ': lost source-bounded body capture @' .. capture_name)
  end
  if damaged_line then
    local a, b = source_range(text, damaged_line, fields.parameters[2])
    local function localized(n)
      if n:type() == 'ERROR' or n:missing() then
        local _, _, start_byte = n:start()
        local _, _, end_byte = n:end_()
        assert(start_byte >= a - 1 and end_byte <= b, label .. ': error escaped malformed assignment')
      end
      for child in n:iter_children() do localized(child) end
    end
    localized(def)
  end
end
local function check_neighbors(node, text, label)
  assert(node:has_error(), label .. ': broken input must remain an error')
  local definitions = {}
  for child in node:iter_children() do
    local names = child:field('name')
    if names[1] then definitions[vim.treesitter.get_node_text(names[1], text)] = child end
  end
  for _, name in ipairs({ 'before', 'Recovered', 'recovered_law', 'after' }) do
    local def = definitions[name]
    assert(def and not def:has_error(), label .. ': lost intact declaration ' .. name)
    local _, _, start_byte = def:start()
    local _, _, end_byte = def:end_()
    local actual = text:sub(start_byte + 1, end_byte)
    assert(not actual:find('broken', 1, true), label .. ': neighboring declaration absorbed damaged text')
  end
  for name, wanted in pairs({
    before = { 'function:before' },
    Recovered = { 'type.definition:Recovered', 'constructor:Recovered' },
    recovered_law = { 'function:recovered_law' },
    after = { 'function:after', 'variable.parameter:x', 'function.call:g', 'number:42' },
  }) do
    local captures = {}
    for id, capture in highlights:iter_captures(definitions[name], text, 0, -1) do
      captures[highlights.captures[id] .. ':' .. vim.treesitter.get_node_text(capture, text)] = true
    end
    for _, capture in ipairs(wanted) do
      assert(captures[capture], label .. ': lost highlight ' .. capture .. ' in ' .. name)
    end
  end
  check_intact_function(definitions.after, text, label)
end
local function check_edited_function(node, text, label, damaged_field)
  local def
  for child in node:iter_children() do
    local name = child:field('name')[1]
    if name and vim.treesitter.get_node_text(name, text) == 'broken' then def = child end
  end
  assert(def and def:type() == 'function_definition', label .. ': lost the edited function')
  assert(def:has_error(), label .. ': error detached from the edited function')
  for _, field in ipairs({ 'name', 'parameters', 'return_type', 'body' }) do
    local part = def:field(field)[1]
    local affected = (damaged_field == 'parameter' and field == 'parameters')
      or ((damaged_field == 'body' or damaged_field == 'body_prefix') and field == 'body')
    assert(part and (affected or not part:has_error()), label .. ': damaged intact field ' .. field)
  end
  if damaged_field ~= 'body' and damaged_field ~= 'body_prefix' then
    assert(vim.treesitter.get_node_text(def:field('body')[1], text) == 'g(7)', label .. ': changed function body')
  end
  local captures = {}
  for id, capture in highlights:iter_captures(def, text, 0, -1) do
    captures[highlights.captures[id] .. ':' .. vim.treesitter.get_node_text(capture, text)] = true
  end
  local wanted = { 'function:broken', 'variable.parameter:x' }
  if damaged_field == 'body_prefix' then
    wanted[#wanted + 1] = 'number:7'
  elseif damaged_field ~= 'body' then
    vim.list_extend(wanted, { 'function.call:g', 'number:7' })
  end
  for _, capture in ipairs(wanted) do
    assert(captures[capture], label .. ': lost edited-function highlight ' .. capture)
  end
  local _, _, start_byte = def:field('name')[1]:end_()
  local _, _, end_byte = def:field('parameters')[1]:start()
  if damaged_field == 'parameter' or damaged_field == 'body' then
    local affected = def:field(damaged_field == 'parameter' and 'parameters' or 'body')[1]
    _, _, start_byte = affected:start()
    _, _, end_byte = affected:end_()
  elseif damaged_field == 'body_prefix' then
    _, _, start_byte = def:field('return_type')[1]:end_()
    _, _, end_byte = def:end_()
  end
  local function check_errors(n)
    if n:type() == 'ERROR' or n:missing() then
      local _, _, a = n:start()
      local _, _, b = n:end_()
      assert(a >= start_byte and b <= end_byte, label .. ': error escaped the damaged field')
    end
    for child in n:iter_children() do check_errors(child) end
  end
  check_errors(def)
  for file, spec in pairs(structure_queries) do
    local found = false
    for id, capture in spec.query:iter_captures(def, text, 0, -1) do
      found = found or (spec.query.captures[id] == spec.capture and capture:id() == def:id())
    end
    assert(found, label .. ': lost ' .. file .. ' capture for edited function')
  end
end
local function check_following_cases(node, text, label, expected, owner_column)
  local arms = {}
  local function collect(n)
    if n:type() == 'case_clause' then
      local pattern = n:field('pattern')[1]
      if pattern then arms[vim.treesitter.get_node_text(pattern, text)] = n end
    end
    for child in n:iter_children() do collect(child) end
  end
  collect(node)
  local patterns = vim.tbl_keys(expected)
  table.sort(patterns)
  for _, pattern in ipairs(patterns) do
    local value = expected[pattern]
    local arm = arms[pattern]
    assert(arm and not arm:has_error(), label .. ': lost intact following arm ' .. pattern)
    if owner_column then
      local owner = arm:parent()
      while owner and owner:type() ~= 'match_expression' do owner = owner:parent() end
      local column = type(owner_column) == 'table' and owner_column[pattern] or owner_column
      assert(owner and select(2, owner:start()) == column,
        label .. ': arm reassigned to another match')
    end
    local body = arm:field('body')[1]
    assert(body and vim.treesitter.get_node_text(body, text) == value,
      label .. ': changed following arm body ' .. pattern)
    local first = source_range(text, 'case ' .. pattern .. ':')
    local _, last = source_range(text, value, first + #('case ' .. pattern .. ':'))
    local pattern_start = first + 5
    local body_start = last - #value + 1
    check_range(arm, text, first, last, label .. ' following arm ' .. pattern)
    check_range(arm:field('pattern')[1], text, pattern_start, pattern_start + #pattern - 1,
      label .. ' following pattern ' .. pattern)
    check_range(body, text, body_start, last, label .. ' following body ' .. pattern)
    for _, spec in ipairs({
      { 'keyword.conditional', first, first + 3 },
      { pattern:sub(-2) == '{}' and 'constructor' or 'variable', pattern_start,
        pattern_start + #pattern - (pattern:sub(-2) == '{}' and 3 or 1) },
      { 'number', body_start, last },
    }) do
      check_capture(highlights, arm, text, spec[1], spec[2], spec[3], label .. ' following arm highlights')
    end
    local got = {}
    for id, capture in highlights:iter_captures(arm, text, 0, -1) do
      got[highlights.captures[id] .. ':' .. vim.treesitter.get_node_text(capture, text)] = true
    end
    for _, wanted in ipairs({ 'keyword.conditional:case',
      (pattern:sub(-2) == '{}' and 'constructor:' .. pattern:sub(1, -3) or 'variable:' .. pattern), 'number:' .. value }) do
      assert(got[wanted], label .. ': lost following-arm highlight ' .. wanted)
    end
    local _, _, arm_start = arm:start()
    local _, _, arm_end = arm:end_()
    local function check_errors(n)
      if n:type() == 'ERROR' or n:missing() then
        local _, _, first = n:start()
        local _, _, last = n:end_()
        assert(last <= arm_start or first >= arm_end, label .. ': error overlaps intact arm ' .. pattern)
      end
      for child in n:iter_children() do check_errors(child) end
    end
    check_errors(node)
    for file, capture_name in pairs({
      folds = 'fold', context = 'context', textobjects = 'conditional.outer',
      locals = 'local.scope', indents = 'indent.begin',
    }) do
      local query = structure_queries[file].query
      local found = false
      for id, capture in query:iter_captures(arm, text, 0, -1) do
        found = found or (query.captures[id] == capture_name and capture:id() == arm:id())
      end
      assert(found, label .. ': lost ' .. file .. ' capture for ' .. pattern)
      check_capture(query, arm, text, capture_name, first, last, label .. ' following arm ' .. file)
    end
    for file, captures in pairs({
      context = { { 'context.end', body_start, last } },
      textobjects = { { 'conditional.inner', body_start, last } },
      locals = { { 'local.reference', pattern_start, pattern_start + #pattern - (pattern:sub(-2) == '{}' and 3 or 1) } },
      indents = { { 'indent.align', pattern_start, pattern_start + #pattern - 1 } },
    }) do
      for _, spec in ipairs(captures) do
        if file ~= 'indents' or pattern:sub(-2) == '{}' then
          check_capture(structure_queries[file].query, arm, text, spec[1], spec[2], spec[3], label .. ' following arm ' .. file)
        end
      end
    end
  end
end
local function check_retained_construct(node, text, label, spec)
  local kind, fragment, fields, delimiters = unpack(spec)
  if text:find('\r\n', 1, true) then fragment = fragment:gsub('\n', '\r\n') end
  local first, last = source_range(text, fragment)
  local owner
  local function find(n)
    if n:type() == kind and select(3, n:start()) == first - 1 and select(3, n:end_()) == last then owner = n end
    for child in n:iter_children() do find(child) end
  end
  find(node)
  assert(owner, label .. ': lost retained ' .. kind)
  local def = owner
  while def and def:type() ~= 'function_definition' do def = def:parent() end
  assert(def and vim.treesitter.get_node_text(def:field('name')[1], text) == 'broken', label .. ': wrong construct owner')
  for _, field in ipairs({ 'name', 'parameters', 'return_type', 'body' }) do
    local parts = def:field(field)
    assert(#parts == 1 and (field == 'body' or not parts[1]:has_error()), label .. ': damaged intact header ' .. field)
  end
  for field, value in pairs(fields) do
    local parts = owner:field(field)
    local a, b = source_range(text, value, first)
    assert(#parts == 1 and not parts[1]:has_error(), label .. ': damaged retained field ' .. field)
    check_range(parts[1], text, a, b, label .. ' retained ' .. field)
  end
  for _, delimiter in ipairs(delimiters or {}) do
    local a = source_range(text, delimiter, first)
    local found = false
    for child in owner:iter_children() do
      found = found or (child:type() == delimiter and not child:missing() and select(3, child:start()) == a - 1)
    end
    assert(found, label .. ': lost real retained delimiter ' .. delimiter)
  end
end
local function check_delimiter_owner(node, text, label, kind, expression, inner_closer)
  local first, last = source_range(text, expression)
  local owner
  local function collect(n)
    local _, _, a = n:start()
    local _, _, b = n:end_()
    if n:type() == kind and a == first - 1 and b == last then owner = n end
    for child in n:iter_children() do collect(child) end
  end
  collect(node)
  assert(owner, label .. ': lost outer ' .. kind .. ' for ' .. expression)
  check_range(owner, text, first, last, label .. ' delimiter owner')
  local container, opener = owner, first
  if kind == 'call_expression' then
    local head = expression:match('^[%w_]+')
    check_range(owner:field('function')[1], text, first, first + #head - 1, label .. ' outer callee')
    container = owner:field('arguments')[1]
    opener = first + #head + (expression:sub(#head + 1, #head + 1) == '!' and 1 or 0)
    check_range(container, text, first + #head, last, label .. ' outer arguments')
  else
    assert(owner:field('body')[1], label .. ': lost grouped body')
  end
  local closing_owner = container
  if inner_closer then
    local missing
    for child in container:iter_children() do
      if child:type() == ')' and child:missing() then missing = child end
    end
    assert(missing, label .. ': missing outer closer was not reported')
    local inner = container:field('argument')[1]
    assert(inner and inner:type() == 'call_expression' and not inner:has_error(),
      label .. ': real inner call lost or damaged')
    closing_owner = inner:field('arguments')[1]
  end
  local closer
  for child in closing_owner:iter_children() do
    local _, _, a = child:start()
    if child:type() == ')' and a == last - 1 then closer = child end
  end
  assert(closer and not closer:missing(), label .. ': real closer reassigned or synthesized')
  check_range(closer, text, last, last, label .. ' real closer')
  -- A GPU opener may only exist where the source actually contains '!('.
  -- Do not pin the otherwise uncertain error tree for an unfinished operand.
  local function real_openers(n)
    if n:type() == 'gpu_call' then
      assert(vim.treesitter.get_node_text(n, text) == '!(', label .. ': invented GPU opener')
      for child in n:iter_children() do
        assert(not child:missing(), label .. ': synthesized GPU opener')
      end
    end
    for child in n:iter_children() do real_openers(child) end
  end
  real_openers(owner)
  -- Ordinary delimiters belong directly to arguments/grouping; GPU '('
  -- belongs to gpu_call, while its ')' belongs to arguments.
  local open_container = container
  if text:sub(opener - 1, opener - 1) == '!' then
    for child in container:iter_children() do
      if child:type() == 'gpu_call' then open_container = child; break end
    end
  end
  local open
  for child in open_container:iter_children() do
    local _, _, a = child:start()
    if child:type() == '(' and a == opener - 1 then open = child end
  end
  assert(open and not open:missing(), label .. ': real outer opener lost')
  check_range(open, text, opener, opener, label .. ' real outer opener')
end
local function edit(buf, from, to)
  local first, last = 0, 0
  while first < math.min(#from, #to) and from:byte(first + 1) == to:byte(first + 1) do first = first + 1 end
  while last < math.min(#from, #to) - first and from:byte(#from - last) == to:byte(#to - last) do last = last + 1 end
  local sr, sc = position(from, first)
  local er, ec = position(from, #from - last)
  vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, vim.split(to:sub(first + 1, #to - last), '\n', { plain = true }))
end
-- These are valid Bend multiline strings, not declaration recovery points.
-- In particular a later unescaped quote must still close the literal, even
-- when its contents look like source code.
for _, literal in ipairs({
  '"first\ndef not_a_definition() -> U32: 1\nlast"',
  '"first\n# not a comment\n\\"escaped\\"\nlast"',
  '"\n\n"',
  '"first\r\nlast"',
}) do
  local text = prefix .. 'def text() -> String: ' .. literal .. suffix
  local tree = parse(text)
  assert(not tree:has_error(), 'valid multiline string rejected: ' .. literal)
  local strings = vim.treesitter.query.parse('bend2', '(string) @string')
  local count = 0
  for _, capture in strings:iter_captures(tree, text, 0, -1) do
    assert(vim.treesitter.get_node_text(capture, text) == literal, 'multiline string cut short')
    count = count + 1
  end
  assert(count == 1, 'expected exactly one complete multiline string')
end
-- A valid multiline string can contain a same-column case-looking line.
-- It must not trigger damaged-arm recovery or create a phantom sibling.
for _, crlf in ipairs({ false, true }) do
  local text = 'def quoted(x: T) -> String:\n  match x:\n    case A{}:\n'
    .. '      "first\n    case NotAnArm{}: 99\nlast"\n    case B{}: "other"\n'
  if crlf then text = text:gsub('\n', '\r\n') end
  local tree = parse(text)
  assert(not tree:has_error(), 'case-looking multiline string rejected')
  local query = vim.treesitter.query.parse('bend2', '(case_clause pattern: (_) @pattern)')
  local patterns = {}
  for _, capture in query:iter_captures(tree, text, 0, -1) do
    patterns[#patterns + 1] = vim.treesitter.get_node_text(capture, text)
  end
  assert(vim.deep_equal(patterns, { 'A{}', 'B{}' }), 'string contents became match arms')
end
-- Valid nesting must not acquire an indentation rule for ')' during recovery
-- fixes. Check every real closer's owner, not merely that parsing succeeds.
for _, sample in ipairs({
  { 'compact nested GPU', 'wrap(g!(wrap(g!(1))))', 'g!(wrap(g!(1)))' },
  { 'less-indented inner closer', 'wrap(\n      g!(\n        wrap(g!(1))\n )\n          )',
    'g!(\n        wrap(g!(1))\n )' },
  { 'more-indented inner closer', 'wrap(\n  g!(\n    wrap(g!(1))\n            )\n)',
    'g!(\n    wrap(g!(1))\n            )' },
}) do
  for _, crlf in ipairs({ false, true }) do
    local expression, inner = sample[2], sample[3]
    if crlf then expression, inner = expression:gsub('\n', '\r\n'), inner:gsub('\n', '\r\n') end
    local text = 'def nested() -> T: ' .. expression .. '\n'
    local tree = parse(text)
    local label = 'review 4 valid ' .. sample[1] .. (crlf and ' CRLF' or ' LF')
    assert(not tree:has_error(), label .. ': invalid control fixture')
    for _, owned in ipairs({ expression, inner, 'wrap(g!(1))', 'g!(1)' }) do
      check_delimiter_owner(tree, text, label, 'call_expression', owned)
    end
    print('PASS ' .. label)
  end
end
for _, text in ipairs({
  '@ # marker\nunsafe # keyword\ndef f() -> U32: g!(1)\n',
  'def f() -> Type: (@unsafe: U32 -> U32)\n',
}) do
  assert(not parse(text):has_error(), 'valid contextual/decorator control rejected')
end
local failed = {}
local locality_count, retained_arm_count = 0, 0
for _, case in ipairs(cases) do
  local ok, err = pcall(function()
    local tail = case.suffix or suffix
    local head = case.prefix or prefix
    local broken, fixed = head .. case[2] .. tail, head .. case[3] .. tail
    if case.crlf then
      broken, fixed = broken:gsub('\n', '\r\n'), fixed:gsub('\n', '\r\n')
    end
    local expected = parse(fixed)
    assert(not expected:has_error(), case[1] .. ': invalid control fixture')
    if case.retained_integer_function then
      check_literal_function(expected, fixed, case[1] .. ' control', case.retained_integer_function)
    end
    if case.delimiter then
      local expression = case.delimiter.fixed
      if case.crlf then expression = expression:gsub('\n', '\r\n') end
      check_delimiter_owner(expected, fixed, case[1] .. ' control', case.delimiter.kind, expression)
    end
    local function check_damaged(node, label)
      if case.preceding_function then
        assert(node:has_error(), label .. ': orphan must remain an error')
        local before
        for child in node:iter_children() do
          local name = child:field('name')[1]
          if name and vim.treesitter.get_node_text(name, broken) == 'before' then before = child end
        end
        local control = case.preceding_function
        if case.crlf then control = control:gsub('\n', '\r\n') end
        assert(before and not before:has_error(), label .. ': orphan damaged preceding declaration')
        assert(vim.deep_equal(signature(before), signature(parse(control):named_child(0))), label .. ': preceding fields/ranges changed')
        if not case.orphan_eof then check_neighbors(node, broken, label) end
      elseif case.retained_integer_function then
        assert(node:has_error(), label .. ': malformed input must retain a native error')
        check_literal_function(node, broken, label, case.retained_integer_function)
        if case.edited_integer_function then
          check_literal_function(node, broken, label, case.edited_integer_function, case.damaged_line, case.terminal)
        end
        if case.following_cases then
          check_following_cases(node, broken, label, case.following_cases, case.arm_owner_column)
        end
      elseif case[4] then
        assert(node:has_error(), label .. ': broken match must remain an error')
        if case.following_cases then
          check_neighbors(node, broken, label)
          check_following_cases(node, broken, label, case.following_cases, case.arm_owner_column)
        end
      else
        check_neighbors(node, broken, label)
        if case[5] then check_edited_function(node, broken, label, case[5]) end
        if case.following_cases then
          check_following_cases(node, broken, label, case.following_cases, case.arm_owner_column)
        end
      end
      if case.owned then
        local source = case[2]
        if case.crlf then source = source:gsub('\n', '\r\n') end
        local first, last = source_range(broken, source)
        local def
        for child in node:iter_children() do
          local name = child:field('name')[1]
          if name and vim.treesitter.get_node_text(name, broken) == 'broken' then def = child end
        end
        assert(def and def:has_error(), label .. ': edited declaration lost error ownership')
        check_range(def, broken, first, last, label .. ' edited declaration')
        for _, field in ipairs({ 'name', 'parameters', 'return_type' }) do
          local parts = def:field(field)
          for _, part in ipairs(parts) do assert(not part:has_error(), label .. ': damaged intact header ' .. field) end
          local count = field == 'return_type' and not source:match('^def broken%([^\n]*%)%s*%->') and 0 or 1
          assert(#parts == count, label .. ': missing or duplicated intact header ' .. field)
        end
        local body = def:field('body')[1]
        assert(body, label .. ': edited body detached')
        local body_start = assert(source:find('\n', 1, true)) + 1
        while source:sub(body_start, body_start):match('%s') do body_start = body_start + 1 end
        assert(select(3, body:start()) >= first + body_start - 2
          and select(3, body:end_()) == last, label .. ': edited body crosses intact boundaries')
        for _, file in ipairs({ 'folds', 'tags', 'context', 'textobjects', 'locals', 'indents' }) do
          check_capture(structure_queries[file].query, def, broken, structure_queries[file].capture,
            first, last, label .. ' edited ' .. file)
        end
      end
      if case.terminal_expression then
        local fragment, kind, captures = unpack(case.terminal_expression)
        if case.crlf then fragment = fragment:gsub('\n', '\r\n') end
        local function terminal(tree, source)
          local def
          for child in tree:iter_children() do
            local name = child:field('name')[1]
            if name and vim.treesitter.get_node_text(name, source) == 'broken' then def = child end
          end
          assert(def, label .. ': edited function missing')
          local first, last = source_range(source, fragment, select(3, def:field('body')[1]:start()) + 1)
          local found
          local function find(n)
            if n:type() == kind and select(3, n:start()) == first - 1 and select(3, n:end_()) == last then found = n end
            for child in n:iter_children() do find(child) end
          end
          find(def)
          assert(found and not found:has_error(), label .. ': intact terminal absent or damaged')
          local body = found:parent()
          assert(body and body:type() == 'body' and not body:has_error(), label .. ': terminal clean body lost')
          check_range(body, source, first, last, label .. ' terminal body')
          for _, capture in ipairs(captures) do
            local text = capture[2]
            if case.crlf then text = text:gsub('\n', '\r\n') end
            local a, b = source_range(source, text, first + capture[3])
            check_capture(highlights, def, source, capture[1], a, b, label .. ' terminal highlight')
          end
          return found
        end
        assert(vim.deep_equal(signature(terminal(node, broken)), signature(terminal(expected, fixed))),
          label .. ': terminal fields/delimiter owners changed')
        local first, last = source_range(broken, case.damaged_line)
        local function errors(n)
          if n:type() == 'ERROR' or n:missing() then
            assert(select(3, n:start()) >= first - 1 and select(3, n:end_()) <= last,
              label .. ': error crosses terminal or intact header')
          end
          for child in n:iter_children() do errors(child) end
        end
        errors(node)
      end
      if case.retained_construct then check_retained_construct(node, broken, label, case.retained_construct) end
      if case.delimiter then
        local expression = case.delimiter.broken
        if case.crlf then expression = expression:gsub('\n', '\r\n') end
        check_delimiter_owner(node, broken, label, case.delimiter.kind, expression, case.delimiter.inner_closer)
      end
    end
    check_damaged(parse(broken), case[1])
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fixed:sub(1, -2), '\n', { plain = true }))
    local parser = vim.treesitter.get_parser(buf, 'bend2')
    parser:parse()
    for _ = 1, 3 do
      edit(buf, fixed, broken)
      local damaged = parser:parse()[1]:root()
      check_damaged(damaged, case[1] .. ' (incremental)')
      assert(vim.deep_equal(signature(damaged), signature(parse(broken))), case[1] .. ': incremental error tree differs')
      edit(buf, broken, fixed)
      local restored = parser:parse()[1]:root()
      assert(vim.deep_equal(signature(restored), signature(expected)), case[1] .. ': repair differs')
      if case.retained_integer_function then
        check_literal_function(restored, fixed, case[1] .. ' repaired', case.retained_integer_function)
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  if ok then
    if case.following_cases then
      retained_arm_count = retained_arm_count + 1
    elseif not case[4] then
      locality_count = locality_count + 1
    end
    local scope = case.following_cases and ' (sibling-arm locality/captures)'
      or (case[4] and ' (consistency/repair only)' or '')
    print('PASS ' .. case[1] .. scope)
  else
    failed[#failed + 1] = tostring(err); print('FAIL ' .. tostring(err))
  end
end
assert(#failed == 0, table.concat(failed, '\n'))
print(('Recovery: %d declaration locality/highlight scenarios; %d sibling-arm locality/capture scenarios; %d match repair/consistency-only scenarios.'):format(
  locality_count, retained_arm_count, #cases - locality_count - retained_arm_count))
vim.cmd('qa!')
