-- Bend 2.0.35 compatibility regressions. No upstream checkout is required.
-- Override BEND2_PARSER to demonstrate failures in the pre-upgrade library.
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or (vim.fn.getcwd() .. '/build/bend2.so') })
local failures, count = {}, 0
local function fingerprint(node)
  local out = {}
  local function visit(n)
    out[#out + 1] = n:type() .. ':' .. table.concat({ n:range() }, ',')
    for child in n:iter_children() do visit(child) end
  end
  visit(node)
  return table.concat(out, '\n')
end
local function check(name, text, erroneous, inspect)
  count = count + 1
  local ok, err = pcall(function()
    local node = vim.treesitter.get_string_parser(text, 'bend2'):parse()[1]:root()
    assert(node:has_error() == erroneous, name .. ': expected ' .. (erroneous and 'an error' or 'a clean tree'))
    if inspect then inspect(node, text) end
    -- Change a byte position in the middle, then repair it. This exercises
    -- scanner snapshots deep inside the new nesting/angle-boundary cases.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text:sub(1, -2), '\n', { plain = true }))
    local parser = vim.treesitter.get_parser(buf, 'bend2')
    assert(fingerprint(parser:parse()[1]:root()) == fingerprint(node), name .. ': buffer parse differs')
    local at = math.floor(#text / 2)
    local prefix = text:sub(1, at)
    local _, row = prefix:gsub('\n', '')
    local col = #prefix - (prefix:match('.*\n()') or 1) + 1
    vim.api.nvim_buf_set_text(buf, row, col, row, col, { ' ' })
    local edited = prefix .. ' ' .. text:sub(at + 1)
    local fresh = vim.treesitter.get_string_parser(edited, 'bend2'):parse()[1]:root()
    assert(fingerprint(parser:parse()[1]:root()) == fingerprint(fresh), name .. ': incremental parse differs')
    vim.api.nvim_buf_set_text(buf, row, col, row, col + 1, { '' })
    assert(fingerprint(parser:parse()[1]:root()) == fingerprint(node), name .. ': repair differs')
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  if ok then print('PASS ' .. name) else failures[#failures + 1] = tostring(err); print('FAIL ' .. tostring(err)) end
end
for _, depth in ipairs({ 99, 100, 140, 190, 199 }) do
  local expression = 'a'
  for _ = 1, depth do expression = '(' .. expression .. ' + b : U32)' end
  check('nested operators depth ' .. depth, 'def deep(+a: U32, +b: U32) -> U32: ' .. expression .. '\n', false)
end
check('nesting overflow remains an error', 'def f() -> T: ' .. ('('):rep(200) .. '1' .. (')'):rep(200) .. '\n', true)
check('deep mixed match frames', 'def f(x: T) -> T: ' .. ('('):rep(140) .. 'match x:\n' .. (' '):rep(180) .. 'case A{}: 1' .. (')'):rep(140) .. '\n', false)
for _, op in ipairs({ '&', '|', '->' }) do
  check('compound type needs parentheses ' .. op, 'def f(x: F<A ' .. op .. ' B>) -> T: x\n', true)
  check('glued comparison cannot hide compound type ' .. op, 'def f() -> T: F<A ' .. op .. ' B\n', true)
  check('parenthesized type argument ' .. op, 'def f(x: F<(A ' .. op .. ' B)>) -> T: x\n', false)
  check('spaced comparison before type operator ' .. op, 'def f() -> T: F < A ' .. op .. ' B\n', false)
end
for _, expression in ipairs({
  '1<2<=3', '1<2 < 3', '1<2<3', '1<2 + 3 * 4', '1<2 << 3',
  '1<2 && 3', '1<2 || 3',
  'F<A<B>>', 'F<&2, A>', 'F < A >', 'F<(A & B)>',
}) do
  check('comparison/type control ' .. expression, 'def f() -> T: ' .. expression .. '\n', false)
end
-- Postfix/glued operations bind within arithmetic operands; accepting the
-- tokens is insufficient if the CST assigns them to the wrong expression.
for _, case in ipairs({
  { '1<2 + 3 * 4', '<', '2 + 3 * 4' },
  { '1 + 2<3', '+', '2<3' },
  { '1<2 << 3', '<', '2 << 3' },
  { '1<2<3', '<', '2<3' },
  { '1<2(3)', '<', '2(3)' },
  { '1<2[3]', '<', '2[3]' },
  { '1 + f(2)', '+', 'f(2)' },
  { '1 + a[2]', '+', 'a[2]' },
  { '(f)(2)(3)', nil, nil },
  { '(a + b)[2]', nil, nil },
  { 'F<A, B & C>', nil, nil },
  { 'F<A, B | C>', nil, nil },
  { 'F<A, B -> C>', nil, nil },
}) do
  check('precedence/recovery control ' .. case[1], 'def f() -> T: ' .. case[1] .. '\n', false, function(node, text)
    if not case[2] then return end
    local expr = node:named_child(0):field('body')[1]:named_child(0)
    assert(expr:type() == 'binary_expression', 'lost binary expression')
    local op, rhs = expr:field('operator')[1], expr:field('right')[1]
    assert(op and vim.treesitter.get_node_text(op, text) == case[2], 'wrong root operator')
    assert(rhs and vim.treesitter.get_node_text(rhs, text) == case[3], 'wrong right-operand ownership')
  end)
end
-- The compiler distinguishes Nat.add from glued successor syntax even when
-- both trees are clean. Keep the operand roles under the type annotation.
for _, case in ipairs({
  { '1n + 2n', 'binary_expression' },
  { '1n+2n', 'natural_successor' },
}) do
  for _, newline in ipairs({ '\n', '\r\n' }) do
    local text = 'def probe() -> Nat: (' .. case[1] .. ' : Nat)' .. newline
    check('annotated natural addition ' .. case[1] .. ' ' .. (newline == '\n' and 'LF' or 'CRLF'),
      text, false, function(node, source)
        local paren = node:named_child(0):field('body')[1]:named_child(0)
        assert(paren:type() == 'parenthesized_expression', 'lost annotated natural expression')
        local expression = paren:field('body')[1]:named_child(0)
        assert(expression:type() == case[2], 'wrong natural addition classification')
        assert(vim.treesitter.get_node_text(expression, source) == case[1], 'wrong natural addition extent')
        if case[2] == 'binary_expression' then
          assert(vim.treesitter.get_node_text(expression:field('operator')[1], source) == '+', 'lost addition operator')
          assert(vim.treesitter.get_node_text(expression:field('left')[1], source) == '1n', 'lost left natural operand')
          assert(vim.treesitter.get_node_text(expression:field('right')[1], source) == '2n', 'lost right natural operand')
        else
          assert(vim.treesitter.get_node_text(expression:field('value')[1], source) == '2n', 'lost successor value')
        end
      end)
  end
end
-- Parallel arity counts whole expressions, not natural/operator fragments.
for _, newline in ipairs({ '\n', '\r\n' }) do
  local text = table.concat({
    'def f(x: Nat) -> Nat:',
    '  a b = 00n & (x) x',
    '  a',
    '',
  }, newline)
  check('parallel natural infix value ' .. (newline == '\n' and 'LF' or 'CRLF'),
    text, false, function(node, source)
      local parallel = node:named_child(0):field('body')[1]:named_child(0)
      assert(parallel:type() == 'parallel_let_expression', 'lost parallel binding')
      local values = parallel:field('value')
      assert(#values == 2 and values[1]:type() == 'binary_expression'
        and values[2]:type() == 'identifier', 'parallel value arity or ownership changed')
      assert(vim.treesitter.get_node_text(values[1], source) == '00n & (x)', 'split natural infix value')
      assert(vim.treesitter.get_node_text(values[1]:field('left')[1], source) == '00n', 'lost natural operand')
      assert(vim.treesitter.get_node_text(values[1]:field('operator')[1], source) == '&', 'lost infix operator')
      assert(vim.treesitter.get_node_text(values[1]:field('right')[1], source) == '(x)', 'lost parenthesized operand')
      assert(vim.treesitter.get_node_text(values[2], source) == 'x', 'lost second parallel value')
      assert(vim.treesitter.get_node_text(parallel:field('body')[1], source) == 'a', 'lost parallel continuation')
    end)
end
-- parse_body consumes glued '&' after a natural literal as an ordinary
-- binary operator, not as part of a pattern or quantity.
for _, case in ipairs({
  { '0n&1n', '0n', '1n', 'natural' },
  { '1n&1n', '1n', '1n', 'natural' },
  { '00n&1n', '00n', '1n', 'natural' },
  { '0n&2', '0n', '2', 'integer' },
  { '0n&0', '0n', '0', 'integer' },
  { '0n &1n', '0n', '1n', 'natural' },
  { '0n& 1n', '0n', '1n', 'natural' },
  { '0n & 1n', '0n', '1n', 'natural' },
}) do
  for _, newline in ipairs({ '\n', '\r\n' }) do
    local text = 'def probe():' .. newline .. '  ' .. case[1] .. newline
    check('natural binary operands ' .. case[1] .. (newline == '\n' and ' LF' or ' CRLF'), text, false, function(node)
      local body = node:named_child(0):field('body')[1]
      local expr = body and body:named_child(0)
      assert(expr and expr:type() == 'binary_expression', 'lost natural binary expression')
      local left, operator, right = expr:field('left'), expr:field('operator'), expr:field('right')
      assert(#left == 1 and left[1]:type() == 'natural'
        and vim.treesitter.get_node_text(left[1], text) == case[2], 'wrong natural left operand')
      assert(#operator == 1 and vim.treesitter.get_node_text(operator[1], text) == '&', 'wrong natural binary operator')
      assert(#right == 1 and right[1]:type() == case[4]
        and vim.treesitter.get_node_text(right[1], text) == case[3], 'wrong natural binary right operand')
      assert(vim.treesitter.get_node_text(body, text) == case[1], 'natural binary body lost source ownership')
    end)
  end
end
-- Scanner lookahead must stop the public body field at the natural literal;
-- trailing extras belong outside the body and its editor captures.
for _, expression in ipairs({ '0n', '00n', '1n+p' }) do
  for _, newline in ipairs({ '\n', '\r\n' }) do
    local text = ('def boundary() -> Nat:\n  ' .. expression
      .. '\n# unrelated trailing comment\ndef after() -> U32: 42\n'):gsub('\n', newline)
    check('natural trailing comment boundary ' .. expression .. (newline == '\n' and ' LF' or ' CRLF'),
      text, false, function(node)
        local def = node:named_child(0)
        local body = def:field('body')[1]
        local first = assert(text:find(expression, #('def boundary() -> Nat:'), true))
        local last = first + #expression - 1
        local _, _, a = body:start()
        local _, _, b = body:end_()
        assert(a == first - 1 and b == last
          and vim.treesitter.get_node_text(body, text) == expression, 'natural body absorbed trailing extras')
        for file, capture_name in pairs({ context = 'context.end', textobjects = 'function.inner' }) do
          local query = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/' .. file .. '.scm'), '\n'))
          local found = false
          for id, capture in query:iter_captures(def, text, 0, -1) do
            if query.captures[id] == capture_name then
              local _, _, start_byte = capture:start()
              local _, _, end_byte = capture:end_()
              if start_byte == first - 1 and end_byte == last then found = true end
            end
          end
          assert(found, 'lost exact natural boundary @' .. capture_name)
        end
      end)
  end
end
for _, case in ipairs({
  { '0n()', 'call_expression', 'function' },
  { '0n[0]', 'index_expression', 'array' },
}) do
  for _, newline in ipairs({ '\n', '\r\n' }) do
    local text = 'def probe():' .. newline .. '  ' .. case[1] .. newline
    check('natural postfix ownership ' .. case[1] .. (newline == '\n' and ' LF' or ' CRLF'),
      text, false, function(node)
        local body = node:named_child(0):field('body')[1]
        local expr = body:named_child(0)
        assert(expr:type() == case[2], 'lost natural postfix expression')
        local head = expr:field(case[3])
        assert(#head == 1 and head[1]:type() == 'natural'
          and vim.treesitter.get_node_text(head[1], text) == '0n', 'wrong natural postfix operand')
        if case[2] == 'call_expression' then
          local arguments = expr:field('arguments')
          assert(#arguments == 1 and #arguments[1]:field('argument') == 0
            and vim.treesitter.get_node_text(arguments[1], text) == '()', 'wrong natural empty-call arguments')
        else
          local index = expr:field('index')
          assert(#index == 1 and index[1]:type() == 'integer'
            and vim.treesitter.get_node_text(index[1], text) == '0', 'wrong natural index operand')
        end
        assert(vim.treesitter.get_node_text(body, text) == case[1], 'natural postfix lost body ownership')
      end)
  end
end
-- Verified with Bend.parse_term: these are interpreted as attempted family
-- applications, not chained numeric comparisons (the family head is invalid).
for _, expression in ipairs({ '1<2 > 3', '1<2 >= 3' }) do
  check('numeric family head refused ' .. expression, 'def f() -> T: ' .. expression .. '\n', true)
end
check('generic law clauses retain their body', 'law f:\n  for xs: List<&2, U32>\n  U32\n', false)
check('glued boolean comparisons', 'def f() -> U32: (1<2 && 2<3 : U32)\n', false)
check('unsafe suffix', '@unsafe def Value.get? () -> U32: 1\n', false)
check('unsafe suffix rejects space', 'def value ?() -> U32: 1\n', true)
check('unsafe suffix rejects newline', 'def value\n?() -> U32: 1\n', true)
check('unsafe suffix rejects comment', 'def value # comment\n?() -> U32: 1\n', true)
check('explicit Array.set keeps eliminator fallback', 'def f() -> T: \\{False: w => Array.set(U32, w, 0, 9); sx => v => v}\n', false, function(node)
  local q = vim.treesitter.query.parse('bend2', '(eliminator fallback: (lambda_expression)) @fallback')
  local n = 0
  for _ in q:iter_captures(node, '', 0, -1) do n = n + 1 end
  assert(n == 1, 'explicit Array.set absorbed the next eliminator row')
end)
check('parenthesized write keeps eliminator fallback', 'def f() -> T: \\{False: w => (w[0] <- 9); sx => v => v}\n', false, function(node)
  local q = vim.treesitter.query.parse('bend2', '(eliminator fallback: (lambda_expression)) @fallback')
  local n = 0
  for _ in q:iter_captures(node, '', 0, -1) do n = n + 1 end
  assert(n == 1, 'parenthesized write absorbed the next eliminator row')
end)
assert(#failures == 0, table.concat(failures, '\n'))
print(('Upgrade: %d compatibility checks passed.'):format(count))
vim.cmd('qa!')
