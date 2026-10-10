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
  local result = { node:type(), node:range() }
  for child in node:iter_children() do result[#result + 1] = signature(child) end
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
local function check_integer_function(node, text, label, declaration, damaged_line)
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
  local literal = assert(declaration:match('(%d+)$'))
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
        if value:type() == 'integer' then return value end
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
  assert(integer and integer:type() == 'integer', label .. ': lost terminal integer body node')
  check_range(integer, text, body_first, last, label .. ' integer node')
  check_capture(highlights, def, text, 'function', fields.name[1], fields.name[2], label)
  check_capture(highlights, def, text, 'number', body_first, last, label)
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
    local first, last = source_range(text, 'case ' .. pattern .. ': ' .. value)
    local pattern_start = first + 5
    local body_start = last - #value + 1
    check_range(arm, text, first, last, label .. ' following arm ' .. pattern)
    check_range(arm:field('pattern')[1], text, pattern_start, pattern_start + #pattern - 1,
      label .. ' following pattern ' .. pattern)
    check_range(body, text, body_start, last, label .. ' following body ' .. pattern)
    for _, spec in ipairs({
      { 'keyword.conditional', first, first + 3 },
      { 'constructor', pattern_start, pattern_start + #pattern - 3 },
      { 'number', body_start, last },
    }) do
      check_capture(highlights, arm, text, spec[1], spec[2], spec[3], label .. ' following arm highlights')
    end
    local got = {}
    for id, capture in highlights:iter_captures(arm, text, 0, -1) do
      got[highlights.captures[id] .. ':' .. vim.treesitter.get_node_text(capture, text)] = true
    end
    for _, wanted in ipairs({ 'keyword.conditional:case', 'constructor:' .. pattern:sub(1, -3), 'number:' .. value }) do
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
      locals = { { 'local.reference', pattern_start, pattern_start + #pattern - 3 } },
      indents = { { 'indent.align', pattern_start, pattern_start + #pattern - 1 } },
    }) do
      for _, spec in ipairs(captures) do
        check_capture(structure_queries[file].query, arm, text, spec[1], spec[2], spec[3], label .. ' following arm ' .. file)
      end
    end
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
      check_integer_function(expected, fixed, case[1] .. ' control', case.retained_integer_function)
    end
    if case.delimiter then
      local expression = case.delimiter.fixed
      if case.crlf then expression = expression:gsub('\n', '\r\n') end
      check_delimiter_owner(expected, fixed, case[1] .. ' control', case.delimiter.kind, expression)
    end
    local function check_damaged(node, label)
      if case.retained_integer_function then
        assert(node:has_error(), label .. ': malformed input must retain a native error')
        check_integer_function(node, broken, label, case.retained_integer_function)
        if case.edited_integer_function then
          check_integer_function(node, broken, label, case.edited_integer_function, case.damaged_line)
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
    for _ = 1, 2 do
      edit(buf, fixed, broken)
      local damaged = parser:parse()[1]:root()
      check_damaged(damaged, case[1] .. ' (incremental)')
      assert(vim.deep_equal(signature(damaged), signature(parse(broken))), case[1] .. ': incremental error tree differs')
      edit(buf, broken, fixed)
      local restored = parser:parse()[1]:root()
      assert(vim.deep_equal(signature(restored), signature(expected)), case[1] .. ': repair differs')
      if case.retained_integer_function then
        check_integer_function(restored, fixed, case[1] .. ' repaired', case.retained_integer_function)
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
