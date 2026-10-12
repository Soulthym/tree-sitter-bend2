-- Retained introduced failures: intact callers must survive a bad proof/value.
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or 'build/bend2.so' })
-- Optional release-baseline comparison; the package command needs only Neovim.
local function load_queries(lang)
  local out = {}
  for _, file in ipairs({ 'highlights', 'tags', 'textobjects', 'context', 'folds', 'locals', 'indents' }) do
    out[file] = vim.treesitter.query.parse(lang, table.concat(vim.fn.readfile('queries/'..file..'.scm'), '\n'))
  end
  return out
end
local queries, base_queries = load_queries('bend2')
if vim.env.BEND2_BASE_PARSER then
  vim.treesitter.language.add('bend2_base', { path = vim.env.BEND2_BASE_PARSER, symbol_name = 'bend2' })
  base_queries = load_queries('bend2_base')
end
local function parse(s, lang) return vim.treesitter.get_string_parser(s, lang or 'bend2'):parse()[1]:root() end
local function walk(n, f) f(n); for c in n:iter_children() do walk(c, f) end end
local function field(n, key) local f = n and n:field(key); assert(f and #f == 1, 'lost field '..key); return f[1] end
local function definition(n, s, name)
  for c in n:iter_children() do
    local f = c:field('name')[1]
    if f and c:type():match('_definition$') and vim.treesitter.get_node_text(f, s) == name then return c end
  end
  error('lost declaration '..name)
end
local function sig(n, origin)
  origin = origin or n
  local row, col, byte = origin:start(); local a, ac, ab = n:start(); local b, bc, bb = n:end_()
  local out = { n:type(), ab-byte, bb-byte, a-row, ac-(a==row and col or 0), b-row,
    bc-(b==row and col or 0), n:missing(), n:named(), n:extra() }
  for c, f in n:iter_children() do out[#out+1] = { f or '', sig(c, origin) } end
  return out
end
local function captures(n, s, qs, scope)
  local origin=scope or n
  local out = {}; local row, col, base = origin:start()
  for file, q in pairs(qs or queries) do
    local rows = {}
    for id, c in q:iter_captures(n, s, 0, -1) do
      local a, ac, ab = c:start(); local b, bc, bb = c:end_()
      -- Zero-width missing siblings at the end are not healthy-field captures.
      if not scope or (ab<bb and ab>=base and bb<=select(3,scope:end_())) then
        rows[#rows+1] = { q.captures[id], c:type(), ab-base, bb-base, a-row,
          ac-(a==row and col or 0), b-row, bc-(b==row and col or 0) }
      end
    end
    table.sort(rows, function(a,b) return vim.json.encode(a)<vim.json.encode(b) end); out[file] = rows
  end
  return out
end
local function pos(s, at)
  local p = s:sub(1, at); local _, row = p:gsub('\n', ''); return row, #p-(p:match('.*\n()') or 1)+1
end
local function exact(n, s, a, b)
  local sr, sc = pos(s, a); local er, ec = pos(s, b)
  assert(n and not n:missing() and select(3,n:start())==a and select(3,n:end_())==b
    and vim.deep_equal({n:range()}, {sr,sc,er,ec}), 'wrong actual range/owner')
end
local function control(s)
  local clean = parse(s); assert(not clean:has_error(), 'invalid exact repair')
  if base_queries then
    local base = parse(s, 'bend2_base'); assert(not base:has_error(), 'baseline rejects exact repair')
    assert(vim.deep_equal(sig(clean),sig(base)) and vim.deep_equal(captures(clean,s),captures(base,s,base_queries)),
      'valid control changed CST/fields/seven queries')
  end
  return clean
end
local cases, results = {}, {}
local specs = {
  { 'next law', 'law b:for v:a=>%$:T;0\nT\nlaw n:T', '$', 'e', 'neighbor' },
  { 'nested proof law body', 'law b:for v:%$:%f:T;0;0\nT', '$', 'e', 'body' },
  { 'outer law body', 'law b:for v:%e:T;v=$;v\nT', '$', '0', 'body' },
  { 'retained rewrite scope', 'def b()->T:%e:T;v=$;v\nlaw n:T', '$', '0', 'scope' },
  { 'successor GPU arguments', 'def b()->T:%e:0n+g-!(x);0', '-', '', 'gpu' },
}
local failures, total, edits = {}, 0, 0
for _, spec in ipairs(specs) do for _, nl in ipairs({ '\n', '\r\n' }) do for _, ending in ipairs({ '', '\n' }) do
  total = total+1
  local broken = (spec[2]..ending):gsub('\n', nl)
  local at = assert(broken:find(spec[3], spec[5]=='gpu' and assert(broken:find('g-',1,true)) or 1, true))-1
  local fixed = broken:sub(1,at)..spec[4]..broken:sub(at+#spec[3]+1)
  local label = spec[1]..' '..(nl=='\n' and 'LF' or 'CRLF')..(ending=='' and ' EOF' or ' final LF')
  cases[#cases+1] = { name=label, family=spec[5], group='original', text=broken, fixed=fixed }
  local buf, native_error, control_clean, cycles = nil, false, false, 0
  local ok, err = pcall(function()
    local clean = control(fixed); control_clean=true
    local function unchanged(n, ref)
      assert(not n:has_error() and vim.deep_equal(sig(n),sig(ref)), 'changed healthy CST/fields')
      assert(vim.deep_equal(captures(n,broken),captures(ref,fixed)), 'changed healthy captures')
    end
    local function check(n)
      assert(n:has_error(), 'actual syntax error disappeared')
      if spec[5]=='neighbor' then
        local d = definition(n,broken,'n'); local ref = definition(clean,fixed,'n')
        local a, b = assert(broken:find('law n:T',1,true)); exact(d,broken,a-1,b); unchanged(d,ref)
      elseif spec[5]=='body' then
        local d = definition(n,broken,'b'); local ref = definition(clean,fixed,'b')
        local body = field(d,'body'); local a = assert(broken:find(nl..'T',1,true))+#nl-1
        exact(body,broken,a,a+1); assert(body:parent():id()==d:id(), 'borrowed law body')
        unchanged(body,field(ref,'body')); unchanged(field(d,'name'),field(ref,'name'))
      elseif spec[5]=='scope' then
        local r, ref
        walk(n,function(c) if c:type()=='rewrite_expression' and select(3,c:start())==11 then r=c end end)
        walk(clean,function(c) if c:type()=='rewrite_expression' and select(3,c:start())==11 then ref=c end end)
        assert(r and ref, 'lost rewrite owner')
        exact(r,broken,select(3,ref:start()),select(3,ref:end_()))
        for _, name in ipairs({ 'proof', 'motive' }) do
          unchanged(field(r,name),field(ref,name))
          assert(field(r,name):parent():id()==r:id(), 'borrowed rewrite field')
        end
        local found = false
        for id, c in queries.locals:iter_captures(n,broken,0,-1) do
          if queries.locals.captures[id]=='local.scope' and c:id()==r:id() then found=true end
        end
        assert(found, 'lost actual rewrite local scope')
      else
        local args, ref; local a, b = assert(broken:find('!(x)',1,true))
        walk(n,function(c) if c:type()=='arguments' and select(3,c:start())==a-1 then args=c end end)
        walk(clean,function(c) if c:type()=='arguments' and select(3,c:start())==a-2 then ref=c end end)
        assert(args and ref, 'lost actual GPU arguments'); exact(args,broken,a-1,b); unchanged(args,ref)
        assert(args:parent():type()=='call_expression' and args:parent():field('arguments')[1]:id()==args:id(), 'wrong call owner')
        exact(args:named_child(0),broken,a-1,a+1)
        local closer = args:child(args:child_count()-1); exact(closer,broken,b-1,b)
        assert(closer:type()==')' and closer:parent():id()==args:id(), 'borrowed real closer')
      end
    end
    local fresh = parse(broken); native_error=fresh:has_error(); check(fresh)
    -- String parsers check exact EOF; buffers necessarily add a final LF.
    if ending~='' then
      buf = vim.api.nvim_create_buf(false,true)
      vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
      local function bytes() return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')..'\n' end
      assert(bytes()==fixed, 'wrong initial buffer bytes')
      local parser = vim.treesitter.get_parser(buf,'bend2'); parser:parse()
      local row, col = pos(broken,at)
      for _=1,3 do
        vim.api.nvim_buf_set_text(buf,row,col,row,col+#spec[4],{spec[3]})
        assert(bytes()==broken, 'wrong inserted bytes')
        local n = parser:parse()[1]:root(); check(n)
        assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)), 'incremental mismatch')
        vim.api.nvim_buf_set_text(buf,row,col,row,col+#spec[3],{spec[4]})
        assert(bytes()==fixed, 'wrong restored bytes')
        n = parser:parse()[1]:root()
        assert(vim.deep_equal(sig(n),sig(clean)) and vim.deep_equal(captures(n,fixed),captures(clean,fixed)), 'repair mismatch')
        edits=edits+2; cycles=cycles+2
      end
    end
  end)
  if buf then vim.api.nvim_buf_delete(buf,{force=true}) end
  results[#results+1] = {name=label,group='original',family=spec[5],pass=ok,error=ok and nil or tostring(err),
    native_error=native_error,control_clean=control_clean,buffer_edits=cycles}
  print((ok and 'PASS ' or 'FAIL ')..label..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end end end

-- Literal port of test-rewrite-owners.py --all: preserve all 116 identities,
-- including overlaps with the original minimal cases (do not deduplicate).
local prefix = 'type T is Data:A{v:T} B{} C{}\ndef before()->U32:0\nlaw prior:T\n'
local suffix = '\ntype Next is Data:N{}\ndef after()->U32:42'
local clauses = { 'for v:', 'for ~v:', 'for v:T where ', 'for ~v:T where ', 'exs v:' }
local function add(family, name, text, fixed, clause)
  cases[#cases+1] = { family=family, name=name, text=text, fixed=fixed, clause=clause, group='reference' }
end
for _, spec in ipairs({
  { 'next-law', 'a=>%$:T;0\nT\nlaw n:T', 'e' },
  { 'borrowed-body', '%e:T;v=$;v\nT', '0' },
  { 'lost-law', '%$:%f:T;0;0\nT', 'e' },
}) do
  for _, clause in ipairs(clauses) do
    -- The 16 constraint nested-proof losses are inherited, not new green promises.
    if spec[1]~='lost-law' or not clause:find('where',1,true) then
      for _, nl in ipairs({ '\n', '\r\n' }) do for _, ending in ipairs({ '', '\n' }) do
        for _, neighbors in ipairs({ false, true }) do
          local text = ((neighbors and prefix or '')..'law b:'..clause..spec[2]
            ..(neighbors and suffix or '')..ending):gsub('\n',nl)
          local at = assert(text:find('$',1,true))
          add(spec[1], {spec[1],clause,nl=='\n' and "'\\n'" or "'\\r\\n'",ending~='',neighbors},
            text,text:sub(1,at-1)..spec[3]..text:sub(at+1),clause)
        end
      end end
    end
  end
end
for _, nl in ipairs({ '\n', '\r\n' }) do for _, ending in ipairs({ '', '\n' }) do
  for _, neighbors in ipairs({ false, true }) do
    local text = ((neighbors and prefix or '')..'def b()->T:%e:T;v=$;v\nlaw n:T'
      ..(neighbors and suffix or '')..ending):gsub('\n',nl)
    add('lost-rewrite', {'lost-rewrite',nl=='\n' and "'\\n'" or "'\\r\\n'",ending~='',neighbors},text,text:gsub('%$','0'))
  end
end end
-- Exactly four known newline-motive guards; no enlarged EOF matrix.
for _, clause in ipairs({ 'for v:', 'for ~v:' }) do for _, nl in ipairs({ '\n', '\r\n' }) do
  local text = ('def before()->U32:1\nlaw b:'..clause
    ..'%e:\nT\ntype Next is Data:Next{}\nlaw after:T\ndef next()->U32:42'):gsub('\n',nl)
  local at = assert(text:find('%e:'..nl..'T',1,true))+#('%e:'..nl..'T')-1
  add('guard', {'newline-motive guard',clause,nl=='\n' and "'\\n'" or "'\\r\\n'"},
    text,text:sub(1,at)..';0'..nl..'T'..text:sub(at+1),clause)
end end
assert(#cases==136, 'lost original/reference specimens')
if vim.env.BEND2_REWRITE_CASES then vim.fn.writefile({vim.json.encode(cases)},vim.env.BEND2_REWRITE_CASES) end

local function capture(root, s, file, name, node)
  for id,c in queries[file]:iter_captures(root,s,0,-1) do
    if queries[file].captures[id]==name and c:id()==node:id() then
      exact(c,s,select(3,node:start()),select(3,node:end_())); return
    end
  end
  error('lost '..file..' @'..name..' '..node:type())
end
local function top(n) while n:parent() do n=n:parent() end; return n end
local function clause(d)
  local out={}; for c in d:iter_children() do if c:type()=='law_clause' then out[#out+1]=c end end
  assert(#out==1,'lost/ambiguous actual law clause'); return out[1]
end
local function rewrite(root, at)
  local out; walk(root,function(c) if c:type()=='rewrite_expression' and select(3,c:start())==at then out=c end end)
  assert(out,'lost actual rewrite owner'); return out
end
local function edit(buf,a,b)
  local first,last=0,0
  while first<math.min(#a,#b) and a:byte(first+1)==b:byte(first+1) do first=first+1 end
  while last<math.min(#a,#b)-first and a:byte(#a-last)==b:byte(#b-last) do last=last+1 end
  local sr,sc=pos(a,first); local er,ec=pos(a,#a-last)
  vim.api.nvim_buf_set_text(buf,sr,sc,er,ec,vim.split(b:sub(first+1,#b-last),'\n',{plain=true}))
  return {first,#a-last,#b-last}
end
for i=21,#cases do
  local case=cases[i]; local broken,fixed=case.text,case.fixed
  local buf, native_error, control_clean, cycles = nil, false, false, 0
  local ok,err=pcall(function()
    local clean=control(fixed); control_clean=true
    local fresh=parse(broken); native_error=fresh:has_error()
    assert(native_error,'actual syntax error disappeared')
    local function unchanged(n,ref)
      assert(not n:has_error() and vim.deep_equal(sig(n),sig(ref)), 'changed healthy CST/fields')
      assert(vim.deep_equal(captures(top(n),broken,nil,n),captures(top(ref),fixed,nil,ref)),
        'changed healthy seven-query ranges')
    end
    local function intact(n,ref)
      exact(n,broken,select(3,ref:start()),select(3,ref:end_())); unchanged(n,ref)
    end
    local function owned(owner,key)
      local n=field(owner,key); assert(n:parent():id()==owner:id(),'borrowed field '..key); return n
    end
    local function check(root)
      assert(root:has_error(),'actual syntax error disappeared')
      -- Every preceding/following declaration, not just law n or root.has_error.
      for ref in clean:iter_children() do
        local f=ref:field('name')[1]
        if f and ref:type():match('_definition$') and vim.treesitter.get_node_text(f,fixed)~='b' then
          local name=vim.treesitter.get_node_text(f,fixed); local n=definition(root,broken,name)
          local a,b=assert(broken:find(vim.treesitter.get_node_text(ref,fixed),1,true))
          exact(n,broken,a-1,b); unchanged(n,ref)
          assert(n:parent():id()==root:id(),'borrowed neighboring declaration')
        end
      end
      if case.family=='next-law' then return end
      local r, rr
      if case.family=='lost-rewrite' then
        -- The reference promises the retained rewrite, not a function wrapper.
        r=rewrite(root,assert(broken:find('%e:T',1,true))-1)
        rr=rewrite(clean,assert(fixed:find('%e:T',1,true))-1)
        exact(r,broken,select(3,rr:start()),select(3,rr:end_()))
        for _,key in ipairs({'proof','motive'}) do intact(owned(r,key),field(rr,key)) end
        capture(root,broken,'locals','local.scope',r)
        return
      end
      local d=definition(root,broken,'b'); local ref=definition(clean,fixed,'b')
      assert(d:type()==ref:type() and d:parent():id()==root:id(),'lost actual declaration owner')
      intact(owned(d,'name'),field(ref,'name'))
      local c,rc=clause(d),clause(ref)
      assert(c:parent():id()==d:id(),'borrowed law clause')
      for _,key in ipairs({'name','quantity'}) do
        assert(#c:field(key)==#rc:field(key),'changed clause '..key)
        if #rc:field(key)>0 then intact(owned(c,key),field(rc,key)) end
      end
      capture(root,broken,'tags','name',field(d,'name'))
      if case.family=='lost-law' then
        exact(d,broken,select(3,ref:start()),select(3,ref:end_()))
        local body=owned(d,'body'); intact(body,field(ref,'body'))
        assert(vim.treesitter.get_node_text(body,broken)=='T','borrowed real law body')
        capture(root,broken,'textobjects','class.inner',body)
        capture(root,broken,'context','context.end',body)
        local at=assert(broken:find('%f:T;0',1,true))-1
        local inner=rewrite(root,at); intact(inner,rewrite(clean,at))
        return
      end
      local key=case.clause:find('where',1,true) and 'constraint' or 'type'
      if key=='constraint' then intact(owned(c,'type'),field(rc,'type')) end
      r,rr=owned(c,key),field(rc,key)
      assert(r:type()=='rewrite_expression','lost clause type/constraint rewrite')
      if case.family=='guard' then
        for _,key in ipairs({'proof','motive'}) do intact(owned(r,key),field(rr,key)) end
        local at=select(3,field(r,'motive'):end_())
        exact(d,broken,select(3,ref:start()),at); exact(r,broken,select(3,rr:start()),at)
        exact(c,broken,select(3,rc:start()),at)
        for _,owner in ipairs({d,r}) do
          local body=owned(owner,'body'); exact(body,broken,at,at)
          local missing={}; walk(body,function(c) if c:missing() then missing[#missing+1]=c end end)
          assert(#missing==1 and missing[1]:type()=='Type','lost native mandatory missing Type')
        end
        local sr,sc=pos(broken,at)
        local errors=0; walk(root,function(c) if c:missing() or c:type()=='ERROR' then
          assert(c:missing() and c:type()=='Type' and select(3,c:start())==at and select(3,c:end_())==at,
            'nonlocal/non-native guard diagnostic')
          assert(vim.deep_equal({c:range()},{sr,sc,sr,sc}),'wrong native missing-value points'); errors=errors+1
        end end); assert(errors==2,'expected both actual mandatory missing values')
      else
        exact(d,broken,select(3,ref:start()),select(3,ref:end_()))
        exact(r,broken,select(3,rr:start()),select(3,rr:end_()))
        exact(c,broken,select(3,rc:start()),select(3,rc:end_()))
        local body=owned(d,'body'); intact(body,field(ref,'body'))
        assert(vim.treesitter.get_node_text(body,broken)=='T','borrowed real law body')
        capture(root,broken,'textobjects','class.inner',body)
        capture(root,broken,'context','context.end',body)
        for _,key in ipairs({'proof','motive'}) do intact(owned(r,key),field(rr,key)) end
      end
      capture(root,broken,'locals','local.scope',r)
    end
    check(fresh)
    -- Neovim adds a virtual final LF even with 'eol'=false. String parsers
    -- cover exact EOF; native tree_edit evidence is kept separately, not claimed here.
    if broken:sub(-1)=='\n' then
      buf=vim.api.nvim_create_buf(false,true)
      vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
      local function bytes() return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')..'\n' end
      assert(bytes()==fixed,'wrong initial buffer bytes')
      local parser=vim.treesitter.get_parser(buf,'bend2')
      assert(vim.deep_equal(sig(parser:parse()[1]:root()),sig(clean)),'wrong initial buffer CST')
      for _=1,3 do
        local e=edit(buf,fixed,broken)
        assert(e[2]-e[1]==1 and e[3]-e[1]==1,'not minimal one-byte damage')
        assert(bytes()==broken,'wrong inserted buffer bytes')
        local n=parser:parse()[1]:root(); check(n)
        assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)),
          'incremental/fresh mismatch')
        edit(buf,broken,fixed); assert(bytes()==fixed,'wrong restored buffer bytes')
        n=parser:parse()[1]:root(); assert(not n:has_error(),'repair retains error')
        assert(vim.deep_equal(sig(n),sig(clean)) and vim.deep_equal(captures(n,fixed),captures(clean,fixed)), 'repair mismatch')
        cycles=cycles+2; edits=edits+2
      end
    end
  end)
  if buf then vim.api.nvim_buf_delete(buf,{force=true}) end
  total=total+1
  results[#results+1]={name=case.name,family=case.family,group=case.group,pass=ok,error=ok and nil or tostring(err),
    native_error=native_error,control_clean=control_clean,buffer_edits=cycles}
  local label=vim.json.encode(case.name)
  print((ok and 'PASS ' or 'FAIL ')..label..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=label..': '..tostring(err) end
end
if vim.env.BEND2_REWRITE_REPORT then
  vim.fn.writefile({vim.json.encode({cases=total,passed=total-#failures,failures=#failures,buffer_edits=edits,results=results})},
    vim.env.BEND2_REWRITE_REPORT)
end
print(('Rewrite recovery: %d/%d strict sources, %d minimal buffer edits; exact repairs, fields/owners/seven-query ranges.'):format(
  total-#failures,total,edits))
assert(#failures==0,table.concat(failures,'\n'))
vim.cmd('qa!')
