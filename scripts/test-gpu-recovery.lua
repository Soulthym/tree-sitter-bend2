-- Native ERRORs must preserve the actual atomic callee and GPU delimiters.
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or 'build/bend2.so' })
local queries = {}
for _, file in ipairs({ 'highlights', 'tags', 'textobjects', 'context', 'folds', 'locals', 'indents' }) do
  queries[file] = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/' .. file .. '.scm'), '\n'))
end
local function parse(s) return vim.treesitter.get_string_parser(s, 'bend2'):parse()[1]:root() end
local function sig(n, origin)
  origin = origin or n
  local row, col, byte = origin:start()
  local a, ac, ab = n:start(); local b, bc, bb = n:end_()
  local out = { n:type(), ab-byte, bb-byte, a-row, ac-(a==row and col or 0), b-row,
    bc-(b==row and col or 0), n:missing(), n:named(), n:extra() }
  for c, f in n:iter_children() do out[#out+1] = { f or '', sig(c, origin) } end
  return out
end
local function captures(n, s)
  local out = {}; local base = select(3, n:start())
  for file, q in pairs(queries) do
    local rows = {}
    for id, c in q:iter_captures(n, s, 0, -1) do
      rows[#rows+1] = { q.captures[id], c:type(), select(3,c:start())-base, select(3,c:end_())-base }
    end
    table.sort(rows, function(a,b) return vim.json.encode(a)<vim.json.encode(b) end); out[file] = rows
  end
  return out
end
local function range(n, s, fragment, from)
  local a,b = assert(s:find(fragment, from or 1, true)); assert(n and not n:missing(), 'missing real '..fragment)
  assert(select(3,n:start())==a-1 and select(3,n:end_())==b, 'wrong range '..fragment)
  return a,b
end
local function capture(file, n, s, name, a, b)
  for id,c in queries[file]:iter_captures(n,s,0,-1) do
    if queries[file].captures[id]==name and select(3,c:start())==a-1 and select(3,c:end_())==b then return end
  end
  error('lost '..file..' @'..name)
end
local function declarations(n,s)
  local out = {}; for c in n:iter_children() do
    local name=c:field('name')[1]; if name then out[vim.treesitter.get_node_text(name,s)] = c end
  end; return out
end
local specs = {
  { 'clause', 'law b: for v:TERM\nT', 'law_clause', 'type' },
  { 'template', 'law b: for ~v:TERM\nT', 'law_clause', 'type' },
  { 'constraint', 'law b: for v:T where TERM\nT', 'law_clause', 'constraint' },
  { 'rewrite', 'def b()->T: %e:TERM;x', 'rewrite_expression', 'motive' },
  { 'nested rewrite', 'def b(x:T)->T:\n  match x:\n    case A{}: %e:TERM;x\n    case B{}: h!(x)', 'rewrite_expression', 'motive' },
}
local cases = {}
for _, spec in ipairs(specs) do for _, head in ipairs({ 'g', 'lib.g' }) do for _, op in ipairs({ '-', '+' }) do
  for _, nl in ipairs({ '\n', '\r\n' }) do
    local prefix='type T is Data: A{} B{}\ndef before()->U32:1\n'; local suffix='\ntype Next is Data: Next{}\nlaw next_law:T\ndef after()->U32:42\n'
    local function source(term) return (prefix..spec[2]:gsub('TERM',term)..suffix):gsub('\n',nl) end
    cases[#cases+1] = { name=spec[1]..' '..head..op..(nl=='\n' and ' LF' or ' CRLF'),
      text=source(head..op..'!(x)'), fixed=source(head..'!(x)'), head=head, op=op, owner=spec[3], field=spec[4] }
  end
end end end
for _, head in ipairs({ 'g', 'lib.g' }) do for _, op in ipairs({ '-', '+' }) do
  for _, nl in ipairs({ '\n', '\r\n' }) do
    local function source(term) return ('def b()->T: %e:' .. term .. ';x\n'):gsub('\n', nl) end
    cases[#cases+1] = { name='rewrite EOF '..head..op..(nl=='\n' and ' LF' or ' CRLF'),
      text=source(head..op..'!(x)'), fixed=source(head..'!(x)'), head=head, op=op,
      owner='rewrite_expression', field='motive', eof=true }
  end
end end
if vim.env.BEND2_GPU_CASES then vim.fn.writefile({ vim.json.encode(cases) }, vim.env.BEND2_GPU_CASES) end
local function pos(s,at)
  local p=s:sub(1,at); local _,row=p:gsub('\n',''); return row,#p-(p:match('.*\n()') or 1)+1
end
local function edit(buf,a,b)
  local first,last=0,0
  while first<math.min(#a,#b) and a:byte(first+1)==b:byte(first+1) do first=first+1 end
  while last<math.min(#a,#b)-first and a:byte(#a-last)==b:byte(#b-last) do last=last+1 end
  local sr,sc=pos(a,first); local er,ec=pos(a,#a-last)
  vim.api.nvim_buf_set_text(buf,sr,sc,er,ec,vim.split(b:sub(first+1,#b-last),'\n',{plain=true}))
end
local failures = {}
for _, case in ipairs(cases) do
  local ok, err=pcall(function()
    local fixed,broken=case.fixed,case.text; local control=parse(fixed); assert(not control:has_error(), 'invalid control')
    local expected=declarations(control,fixed)
    local function check(n)
      assert(n:has_error(), 'mistake falsely clean'); local defs=declarations(n,broken)
      for _,name in ipairs(case.eof and {} or { 'T','before','Next','next_law','after' }) do
        assert(defs[name] and not defs[name]:has_error(), 'lost neighbor '..name)
        range(defs[name],broken,vim.treesitter.get_node_text(expected[name],fixed))
        assert(vim.deep_equal(sig(defs[name]),sig(expected[name])), 'changed neighboring CST')
        assert(vim.deep_equal(captures(defs[name],broken),captures(expected[name],fixed)), 'changed neighbor captures')
      end
      local def=assert(defs.b, 'lost edited declaration'); assert(def:has_error())
      for _,field in ipairs({ 'name','parameters','return_type' }) do
        local a,b=def:field(field),expected.b:field(field); assert(#a==#b)
        for i,c in ipairs(a) do assert(not c:has_error()); range(c,broken,vim.treesitter.get_node_text(b[i],fixed),select(3,b[i]:start())+1) end
      end
      local a,b=assert(broken:find(case.head..case.op..'!(x)',1,true)); local call
      local function find(c)
        if c:type()=='call_expression' and select(3,c:start())==a-1 and select(3,c:end_())==b then call=c end
        for child in c:iter_children() do find(child) end
      end
      find(def); assert(call, 'lost real GPU call')
      assert(call:parent():type()==case.owner and call:parent():field(case.field)[1]:id()==call:id(), 'changed expression field owner')
      local fn,args=call:field('function')[1],call:field('arguments')[1]
      range(fn,broken,case.head,a); range(args,broken,'!(x)',a+#case.head)
      assert(not fn:has_error() and not args:has_error(), 'corrupt GPU children')
      local gpu=args:named_child(0); range(gpu,broken,'!(',a+#case.head)
      range(gpu:child(0),broken,'!',a+#case.head); range(gpu:child(1),broken,'(',a+#case.head)
      range(args:field('argument')[1],broken,'x',a+#case.head); range(args:child(args:child_count()-1),broken,')',b)
      capture('highlights',call,broken,'function.call',a,a+#case.head-1)
      capture('highlights',call,broken,'keyword.modifier',a+#case.head+1,a+#case.head+1)
      capture('tags',call,broken,'reference.call',a,b); capture('tags',call,broken,'name',a,a+#case.head-1)
      capture('textobjects',call,broken,'call.outer',a,b); capture('textobjects',call,broken,'call.inner',b-1,b-1)
      -- ERROR is the rejected operator, never the real modifier/opener/closer.
      local function errors(c)
        if c:type()=='ERROR' or c:missing() then
          assert(select(3,c:start())==a+#case.head-1 and select(3,c:end_())==a+#case.head, 'nonlocal or synthesized error')
        end
        for child in c:iter_children() do errors(child) end
      end
      errors(n)
      if case.owner=='rewrite_expression' and broken:find('case B{}',1,true) then
        local q=vim.treesitter.query.parse('bend2','(case_clause pattern: (constructor_expression name: (identifier) @name)) @arm')
        local arms={}; for id,c in q:iter_captures(n,broken,0,-1) do if q.captures[id]=='arm' then arms[#arms+1]=c end end
        assert(#arms==2 and arms[1]:parent():id()==arms[2]:parent():id(), 'changed sibling match owner')
        local sibling=arms[2]; range(sibling,broken,'case B{}: h!(x)'); assert(not sibling:has_error())
        local clean={}; for id,c in q:iter_captures(control,fixed,0,-1) do if q.captures[id]=='arm' then clean[#clean+1]=c end end
        assert(vim.deep_equal(sig(sibling),sig(clean[2])) and vim.deep_equal(captures(sibling,broken),captures(clean[2],fixed)))
      end
    end
    local fresh=parse(broken); check(fresh)
    local buf=vim.api.nvim_create_buf(false,true)
    vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
    local parser=vim.treesitter.get_parser(buf,'bend2'); parser:parse()
    for _=1,3 do
      edit(buf,fixed,broken); local n=parser:parse()[1]:root(); check(n)
      assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)), 'fresh/incremental mismatch')
      edit(buf,broken,fixed); local repaired=parser:parse()[1]:root()
      assert(vim.deep_equal(sig(repaired),sig(control)) and vim.deep_equal(captures(repaired,fixed),captures(control,fixed)), 'repair mismatch')
    end
    vim.api.nvim_buf_delete(buf,{force=true})
  end)
  print((ok and 'PASS ' or 'FAIL ')..case.name..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end
assert(#failures==0, table.concat(failures,'\n'))
print(('GPU: %d LF/CRLF vectors, three minimal repairs, exact fields/ranges/captures and sibling owners.'):format(#cases))
vim.cmd('qa!')
