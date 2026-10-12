-- Recovery must not borrow an earlier callee, a declaration opener, or a call level.
vim.treesitter.language.add('bend2', { path = vim.env.BEND2_PARSER or 'build/bend2.so' })
local queries = {}
for _, file in ipairs({ 'highlights', 'tags', 'textobjects', 'context', 'folds', 'locals', 'indents' }) do
  queries[file] = vim.treesitter.query.parse('bend2', table.concat(vim.fn.readfile('queries/'..file..'.scm'), '\n'))
end
local function parse(s) return vim.treesitter.get_string_parser(s, 'bend2'):parse()[1]:root() end
local function sig(n, origin)
  origin = origin or n
  local row, col, byte = origin:start(); local a, ac, ab = n:start(); local b, bc, bb = n:end_()
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
local function pos(s, at)
  local p=s:sub(1,at); local _,row=p:gsub('\n',''); return row,#p-(p:match('.*\n()') or 1)+1
end
local function exact(n, s, a, b)
  assert(n and not n:missing(), 'missing real node')
  local sr,sc=pos(s,a); local er,ec=pos(s,b)
  assert(select(3,n:start())==a and select(3,n:end_())==b
    and vim.deep_equal({n:range()},{sr,sc,er,ec}), 'wrong range/owner '..n:type())
end
local function field(n, name) local f=n:field(name); assert(#f==1, 'lost field '..name); return f[1] end
local function walk(n, check) check(n); for c in n:iter_children() do walk(c,check) end end
local function definitions(n,s)
  local out={}; for c in n:iter_children() do
    local name=c:field('name')[1]; if name then out[vim.treesitter.get_node_text(name,s)]=c end
  end; return out
end
local function capture(file,n,s,name,a,b)
  for id,c in queries[file]:iter_captures(n,s,0,-1) do
    if queries[file].captures[id]==name and select(3,c:start())==a and select(3,c:end_())==b then return end
  end
  error('lost '..file..' @'..name)
end
local specs={
  { name='type stale callee', text='type B is Data: B{v:1n$+g!(v)}', fixed='type B is Data: B{v:1n+g!(v)}', kind='type' },
  { name='parameter opener', text='def b(x:1n$+g!(v))->U32:0', fixed='def b(x:1n+g!(v))->U32:0', kind='parameter' },
  { name='bare invalid prefix', text='def b(x:1n!+g!(v))->U32:0', fixed='def b(x:1n+g!(v))->U32:0', kind='parameter' },
  { name='nested invalid modifier', text='def b()->U32:%e:g!(!(0));0', fixed='def b()->U32:%e:g!((0));0', kind='nested' },
}
local prefix='type T is Data: A{} C{}\ndef before(x:T)->U32:match x:\n  case A{}:1\n  case C{}:2\nlaw prior:T\n'
local suffix='\ntype Next is Data: Next{}\nlaw next_law:T\ndef after(x:T)->U32:match x:\n  case A{}:42\n  case C{}:43\n'
local cases={}
for _,spec in ipairs(specs) do for _,neighbors in ipairs({false,true}) do for _,nl in ipairs({'\n','\r\n'}) do
  cases[#cases+1]={ name=spec.name..(neighbors and ' neighbors' or ' minimal')..(nl=='\n' and ' LF' or ' CRLF'),
    kind=spec.kind, text=((neighbors and prefix or '')..spec.text..(neighbors and suffix or '\n')):gsub('\n',nl),
    fixed=((neighbors and prefix or '')..spec.fixed..(neighbors and suffix or '\n')):gsub('\n',nl) }
end end end
for _,head in ipairs({'g','lib.g'}) do for _,nl in ipairs({'\n','\r\n'}) do
  local function source(term) return (prefix..'def b(x:T)->U32:match x:\n  case A{}:%e:'..term..';0\n  case C{}:42'..suffix):gsub('\n',nl) end
  cases[#cases+1]={ name='nested match '..head..(nl=='\n' and ' LF' or ' CRLF'), kind='nested',
    text=source(head..'!(!(0))'), fixed=source(head..'!((0))') }
end end
if vim.env.BEND2_OWNER_CASES then vim.fn.writefile({vim.json.encode(cases)},vim.env.BEND2_OWNER_CASES) end
local function edit(buf,a,b)
  local first,last=0,0
  while first<math.min(#a,#b) and a:byte(first+1)==b:byte(first+1) do first=first+1 end
  while last<math.min(#a,#b)-first and a:byte(#a-last)==b:byte(#b-last) do last=last+1 end
  local sr,sc=pos(a,first); local er,ec=pos(a,#a-last)
  vim.api.nvim_buf_set_text(buf,sr,sc,er,ec,vim.split(b:sub(first+1,#b-last),'\n',{plain=true}))
end
local failures={}
for _,case in ipairs(cases) do
  local ok,err=pcall(function()
    local broken,fixed=case.text,case.fixed; assert(#broken==#fixed+1, 'not a one-byte repair')
    local clean=parse(fixed); assert(not clean:has_error(), 'invalid control')
    local expected=definitions(clean,fixed)
    local function check(n)
      assert(n:has_error(), 'invalid source became clean'); local defs=definitions(n,broken)
      for name,c in pairs(expected) do if name~='b' and name~='B' then
        local d=assert(defs[name], 'lost neighbor '..name)
        assert(not d:has_error() and vim.deep_equal(sig(d),sig(c))
          and vim.deep_equal(captures(d,broken),captures(c,fixed)), 'changed neighbor fields/captures '..name)
      end end
      local d=assert(defs[case.kind=='type' and 'B' or 'b'], 'lost edited declaration')
      local a=select(3,d:start()); assert(d:has_error())
      local fn=field(d,'name'); exact(fn,broken,a+4+(case.kind=='type' and 1 or 0),a+5+(case.kind=='type' and 1 or 0))
      if case.kind=='type' then
        exact(d,broken,a,a+30); exact(field(d,'kind'),broken,a+10,a+14)
        local ctor; for c in d:iter_children() do if c:type()=='constructor_definition' then ctor=c end end
        exact(ctor,broken,a+16,a+30); exact(field(ctor,'name'),broken,a+16,a+17)
        exact(ctor:child(1),broken,a+17,a+18); exact(ctor:child(ctor:child_count()-1),broken,a+29,a+30)
        local p=ctor:named_child(1); exact(field(p,'name'),broken,a+18,a+19); exact(field(p,'type'),broken,a+20,a+22)
        walk(d,function(c)
          if c:type()=='ERROR' or c:missing() then assert(select(3,c:start())>=a+20 and select(3,c:end_())<=a+29, 'error crossed real constructor/header') end
          if c:type()=='call_expression' then assert(vim.treesitter.get_node_text(field(c,'function'),broken)~='Data', 'borrowed kind as callee') end
        end)
        capture('highlights',d,broken,'type.definition',a+5,a+6)
        capture('tags',d,broken,'definition.type',a,a+30)
        capture('tags',ctor,broken,'definition.class',a+16,a+30)
        capture('textobjects',d,broken,'class.inner',a+16,a+30)
      elseif case.kind=='parameter' then
        exact(d,broken,a,a+25); local params=field(d,'parameters')
        -- Preserve the actual opener/x; do not promise to solve the inherited first-closer ambiguity.
        assert(select(3,params:start())==a+5, 'parameters borrowed GPU opener')
        exact(params:child(0),broken,a+5,a+6)
        local p=params:named_child(0); exact(field(p,'name'),broken,a+6,a+7); exact(field(p,'type'),broken,a+8,a+10)
        exact(field(d,'return_type'),broken,a+20,a+23); exact(field(d,'body'),broken,a+24,a+25)
        capture('highlights',d,broken,'variable.parameter',a+6,a+7)
        capture('textobjects',d,broken,'parameter.outer',a+6,a+10)
        capture('indents',d,broken,'indent.align',a+5,select(3,params:end_()))
        walk(d,function(c)
          if c:type()=='ERROR' or c:missing() then assert(select(3,c:start())>=a+8 and select(3,c:end_())<=a+18, 'parameter error crossed intact header/body') end
        end)
      else
        local start,last=assert(broken:find('!(!(0))',a+1,true)); local call
        walk(d,function(c) if c:type()=='call_expression' and select(3,c:end_())==last then call=c end end)
        assert(call, 'lost outer call'); local args=field(call,'arguments'); exact(args,broken,start-1,last)
        assert(call:parent():type()=='rewrite_expression' and field(call:parent(),'motive'):id()==call:id(), 'wrong call level')
        local callee=field(call,'function'); assert(not callee:has_error()); local ca=select(3,callee:start())
        local gpu=args:named_child(0); exact(gpu,broken,start-1,start+1)
        exact(gpu:child(0),broken,start-1,start); exact(gpu:child(1),broken,start,start+1)
        local group=field(args,'argument'); exact(group,broken,start+2,last-1); assert(not group:has_error())
        exact(group:child(0),broken,start+2,start+3); exact(group:child(group:child_count()-1),broken,last-2,last-1)
        exact(args:child(args:child_count()-1),broken,last-1,last)
        capture('highlights',call,broken,'function.call',ca,start-1)
        capture('highlights',call,broken,'keyword.modifier',start-1,start)
        capture('tags',call,broken,'reference.call',ca,last)
        walk(d,function(c)
          if c:type()=='ERROR' or c:missing() then exact(c,broken,start+1,start+2) end
        end)
        local arms={}; walk(d,function(c) if c:type()=='case_clause' then arms[#arms+1]=c end end)
        if #arms>0 then
          assert(#arms==2 and arms[1]:parent():id()==arms[2]:parent():id(), 'changed sibling match owner')
          local controls={}; walk(expected.b,function(c) if c:type()=='case_clause' then controls[#controls+1]=c end end)
          assert(not arms[2]:has_error() and vim.deep_equal(sig(arms[2]),sig(controls[2]))
            and vim.deep_equal(captures(arms[2],broken),captures(controls[2],fixed)), 'lost sibling fields/captures')
        else
          exact(field(d,'parameters'),broken,a+5,a+7); exact(field(d,'return_type'),broken,a+9,a+12)
          exact(field(call:parent(),'proof'),broken,a+14,a+15); exact(field(call:parent(),'body'),broken,a+25,a+26)
        end
      end
      for file,name in pairs({folds='fold',context='context',locals='local.scope',indents='indent.begin'}) do
        capture(file,d,broken,name,select(3,d:start()),select(3,d:end_()))
      end
    end
    local fresh=parse(broken); check(fresh)
    local buf=vim.api.nvim_create_buf(false,true)
    vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
    local parser=vim.treesitter.get_parser(buf,'bend2'); parser:parse()
    for _=1,3 do
      edit(buf,fixed,broken); local n=parser:parse()[1]:root(); check(n)
      assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)), 'incremental ownership differs')
      edit(buf,broken,fixed); local repaired=parser:parse()[1]:root()
      assert(vim.deep_equal(sig(repaired),sig(clean)) and vim.deep_equal(captures(repaired,fixed),captures(clean,fixed)), 'repair differs')
    end
    vim.api.nvim_buf_delete(buf,{force=true})
  end)
  print((ok and 'PASS ' or 'FAIL ')..case.name..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end
-- '%' followed by whitespace is arithmetic syntax. Bend's annotation
-- requirement is semantic; it must not cost either completed rewrite body.
local retained = {}
for _, nl in ipairs({'\n','\r\n'}) do for _, trailing in ipairs({false,true}) do
  for _, placement in ipairs({'minimal','neighbors','match'}) do
    local term='def b()->T:%e:%f:x% y;0;0'
    if placement=='match' then
      term='def b(x:T)->T:match x:\n  case A{}:%e:%f:x% y;0;0\n  case C{}:h!(x)'
    end
    local text=((placement~='minimal' and prefix or '')..term
      ..(placement~='minimal' and suffix:sub(1,-2) or '')..(trailing and '\n' or '')):gsub('\n',nl)
    local at=assert(text:find('x% y',1,true)) -- 1-based x is 0-based operator.
    retained[#retained+1]={name='rewrite bodies '..placement..' '..(nl=='\n' and 'LF' or 'CRLF')
      ..(trailing and ' final LF' or ' EOF'),text=text,fixed=text:sub(1,at)..'&'..text:sub(at+2),at=at}
  end
end end
local mod_count=#retained
for i=1,mod_count do
  local c=retained[i]
  local text=c.text:gsub('x%% y','A{x}')
  retained[#retained+1]={name=c.name:gsub('rewrite bodies','constructor bodies'),
    text=text,fixed=text:gsub('A{x}','A(x)'),constructor=true}
end
if vim.env.BEND2_REWRITE_CASES then vim.fn.writefile({vim.json.encode(retained)},vim.env.BEND2_REWRITE_CASES) end
for _,case in ipairs(retained) do
  local ok,err=pcall(function()
    local broken,fixed=case.text,case.fixed; local clean=parse(fixed)
    assert(not clean:has_error(),'invalid one-byte control')
    local function check(n)
      assert(not n:has_error(),'header dispatch lost completed rewrite owners')
      if not case.constructor then
      local actual=sig(n)
      local function operator(t)
        if t[1]=='%' and t[2]==case.at and t[3]==case.at+1 then t[1]='&' end
        for i=11,#t do operator(t[i][2]) end
      end
      operator(actual)
      assert(vim.deep_equal(actual,sig(clean)),'changed field/node/delimiter/match boundaries beyond operator')
      local got=captures(n,broken)
      for _,rows in pairs(got) do for _,row in ipairs(rows) do
        if row[2]=='%' and row[3]==case.at and row[4]==case.at+1 then row[2]='&' end
      end end
      assert(vim.deep_equal(got,captures(clean,fixed)),'lost actual query captures')
      else
        local got,controls=definitions(n,broken),definitions(clean,fixed)
        for name,d in pairs(controls) do if name~='b' then
          assert(got[name] and vim.deep_equal(sig(got[name]),sig(d))
            and vim.deep_equal(captures(got[name],broken),captures(d,fixed)),'changed constructor neighbor')
        end end
        for _,name in ipairs({'name','parameters','return_type'}) do
          assert(vim.deep_equal(sig(field(got.b,name)),sig(field(controls.b,name))),'changed constructor header')
        end
        local first,last=assert(broken:find('A{x}',1,true))
        local function unaffected(caps)
          for _,rows in pairs(caps) do for i=#rows,1,-1 do
            if rows[i][3]>=first-1 and rows[i][4]<=last then table.remove(rows,i) end
          end end
          return caps
        end
        assert(vim.deep_equal(unaffected(captures(n,broken)),unaffected(captures(clean,fixed))),
          'changed query ranges outside constructor/call control')
        local expected={}
        walk(clean,function(c) if c:type()=='rewrite_expression' then expected[select(3,c:start())]=c end end)
        walk(n,function(c) if c:type()=='rewrite_expression' then
          local control=assert(expected[select(3,c:start())])
          for _,name in ipairs({'proof','body'}) do
            local a,b=field(c,name),field(control,name)
            assert(vim.deep_equal(sig(a),sig(b)) and select(3,a:start())==select(3,b:start())
              and select(3,a:end_())==select(3,b:end_()),'changed intact constructor rewrite field '..name)
          end
          assert(select(3,c:end_())==select(3,control:end_()),'constructor rewrite boundary changed')
          local motive=field(c,'motive')
          if motive:type()=='constructor_expression' then
            local a,b=assert(broken:find('A{x}',1,true))
            exact(motive,broken,a-1,b); exact(field(motive,'name'),broken,a-1,a)
            exact(motive:child(1),broken,a,a+1); exact(motive:child(motive:child_count()-1),broken,b-1,b)
          end
        end end)
      end
      local count=0
      walk(n,function(c) if c:type()=='rewrite_expression' then
        count=count+1
        local body=field(c,'body'); assert(vim.treesitter.get_node_text(body,broken)=='0')
        exact(body,broken,select(3,c:end_())-1,select(3,c:end_()))
        capture('locals',n,broken,'local.scope',select(3,c:start()),select(3,c:end_()))
      end end)
      assert(count==2,'lost nested rewrite bodies')
    end
    local fresh=parse(broken); check(fresh)
    -- Buffer parsers add a final LF; exact EOF edits are checked natively too.
    if fixed:sub(-1)=='\n' then
      local buf=vim.api.nvim_create_buf(false,true)
      vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
      local parser=vim.treesitter.get_parser(buf,'bend2'); parser:parse()
      for _=1,3 do
        edit(buf,fixed,broken); local n=parser:parse()[1]:root(); check(n)
        assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)))
        edit(buf,broken,fixed); local n=parser:parse()[1]:root()
        assert(vim.deep_equal(sig(n),sig(clean)) and vim.deep_equal(captures(n,fixed),captures(clean,fixed)))
      end
      vim.api.nvim_buf_delete(buf,{force=true})
    end
  end)
  print((ok and 'PASS ' or 'FAIL ')..case.name..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end
assert(#failures==0,table.concat(failures,'\n'))
print(('GPU owners: %d vectors, LF/CRLF, three minimal edits/restores, exact fields/ranges/captures and sibling owners.'):format(#cases + #retained))
vim.cmd('qa!')
