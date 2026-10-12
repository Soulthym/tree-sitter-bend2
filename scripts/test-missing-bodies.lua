-- Both mandatory bodies stay erroneous without swallowing the next declaration.
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
local cases={}
for _,clause in ipairs({'for v:','for ~v:','exs v:T where '}) do
  for _,next in ipairs({'law n:T','def n()->T:x','type N is Data:N{}'}) do
    for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do
      for _,flavor in ipairs({'minimal','neighbors','named GPU motive'}) do
        local prefix=flavor=='neighbors' and 'type T is Data:A{} B{}\ndef before()->U32:1\nlaw prior:T\n' or ''
        local suffix=flavor=='neighbors' and '\ndef after(x:T)->T:match x:\n  case A{}:h!(x)\n  case B{}:x' or ''
        local term=flavor=='named GPU motive' and '%w@e:g!(x)' or '%e:T'
        local stem=prefix..'law b:'..clause..term
        cases[#cases+1]={name=clause..' '..next..' '..flavor..' '..(nl=='\n' and 'LF' or 'CRLF')..(ending=='' and ' exact EOF' or ''),
          text=(stem..'\n'..next..suffix..ending):gsub('\n',nl),
          fixed=(stem..';0\nT\n'..next..suffix..ending):gsub('\n',nl),
          next_name=next:sub(1,4)=='type' and 'N' or 'n', field=clause:sub(1,3)=='exs' and 'constraint' or 'type',
          motive=flavor=='named GPU motive' and 'g!(x)' or 'T', named=flavor=='named GPU motive'}
      end
    end end
  end
end
-- Retain the pre-entry summary too: a rejected second separator must not
-- make a header borrow the following declaration or sibling match arm.
for _,body in ipairs({'%q:%e:T;;x','a=>%q:%e:T;;x','y=%q:%e:T;;x;y','%q:T;%e:%e:T;;x'}) do
  for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do
    local text='type T is Data:A{} B{} C{}\ndef prior()->U32:0\ndef b(x:T)->T:match x:\n  case A{}:'..body
      ..'\n  case B{}:h!(x)\n  case C{}:x\nlaw next:T\ndef after()->U32:42'..ending
    cases[#cases+1]={name='pre-entry separator '..body..' '..(nl=='\n' and 'LF' or 'CRLF')..(ending=='' and ' exact EOF' or ''),
      text=text:gsub('\n',nl),fixed=text:gsub('T;;x','T;0;x'):gsub('\n',nl),guard=true}
  end end
end
if vim.env.BEND2_MISSING_CASES then vim.fn.writefile({vim.json.encode(cases)},vim.env.BEND2_MISSING_CASES) end
local function edit(buf,a,b)
  local first,last=0,0
  while first<math.min(#a,#b) and a:byte(first+1)==b:byte(first+1) do first=first+1 end
  while last<math.min(#a,#b)-first and a:byte(#a-last)==b:byte(#b-last) do last=last+1 end
  local sr,sc=pos(a,first); local er,ec=pos(a,#a-last)
  vim.api.nvim_buf_set_text(buf,sr,sc,er,ec,vim.split(b:sub(first+1,#b-last),'\n',{plain=true}))
end
local failures={}; local edits=0
for _,case in ipairs(cases) do
  local ok,err=pcall(function()
    local broken,fixed=case.text,case.fixed
    local clean=parse(fixed); assert(not clean:has_error(),'invalid control')
    local expected=definitions(clean,fixed)
    local function check(n)
      assert(n:has_error(),'actual missing bodies falsely clean')
      local defs=definitions(n,broken)
      for name,c in pairs(expected) do if name~='b' then
        local d=assert(defs[name],'lost neighbor '..name)
        local a,b=assert(broken:find(vim.treesitter.get_node_text(c,fixed),1,true))
        exact(d,broken,a-1,b)
        assert(not d:has_error() and vim.deep_equal(sig(d),sig(c))
          and vim.deep_equal(captures(d,broken),captures(c,fixed)),'changed neighbor fields/captures '..name)
      end end
      local d=assert(defs.b,'lost edited law'); assert(d:has_error())
      if case.guard then
        for _,f in ipairs({'name','parameters','return_type'}) do
          assert(vim.deep_equal(sig(field(d,f)),sig(field(expected.b,f))),'changed edited function header '..f)
        end
        local function arms(n,s)
          local out={}; walk(n,function(c) if c:type()=='case_clause' then out[vim.treesitter.get_node_text(field(c,'pattern'),s)]=c end end); return out
        end
        local actual,control=arms(d,broken),arms(expected.b,fixed)
        for _,pattern in ipairs({'B{}','C{}'}) do
          local c=assert(actual[pattern],'lost sibling '..pattern); local ref=control[pattern]
          local a,b=assert(broken:find(vim.treesitter.get_node_text(ref,fixed),1,true)); exact(c,broken,a-1,b)
          assert(not c:has_error() and vim.deep_equal(sig(c),sig(ref)) and vim.deep_equal(captures(c,broken),captures(ref,fixed)),'changed sibling fields/captures')
          assert(c:parent():type()=='match_expression' and select(3,c:parent():start())==select(3,ref:parent():start()),'changed actual match owner')
        end
        assert(actual['B{}']:parent():id()==actual['C{}']:parent():id(),'separated real siblings')
        local a=assert(broken:find('case A{}:',1,true))-1
        local b=assert(broken:find('\n',a+1,true))
        walk(n,function(c) if c:missing() or c:type()=='ERROR' then
          assert(select(3,c:start())>=a and select(3,c:end_())<=b-1,'separator error crossed healthy owner')
        end end)
        return
      end
      local a=assert(broken:find('law b:',1,true))-1
      exact(field(d,'name'),broken,a+4,a+5)
      local clauses={}; for c in d:iter_children() do if c:type()=='law_clause' then clauses[#clauses+1]=c end end
      assert(#clauses==1,'lost clause owner'); local clause=clauses[1]
      local v=assert(broken:find('v:',a+7,true)); exact(field(clause,'name'),broken,v-1,v)
      local r=field(clause,case.field); assert(r:type()=='rewrite_expression','changed rewrite caller')
      assert(r:parent():id()==clause:id(),'wrong clause field owner')
      local proof=field(r,'proof'); assert(not proof:has_error())
      local p=assert(broken:find('e:',select(3,r:start())+1,true)); exact(proof,broken,p-1,p)
      local motive=field(r,'motive'); local ma,mb=assert(broken:find(case.motive,p+2,true)); exact(motive,broken,ma-1,mb)
      assert(not motive:has_error(),'damaged intact motive')
      if case.named then
        exact(field(r,'name'),broken,select(3,r:start())+1,select(3,r:start())+2)
        local args=field(motive,'arguments'); exact(args,broken,ma,mb)
        exact(args:child(args:child_count()-1),broken,mb-1,mb)
        assert(args:named_child(0):type()=='gpu_call','lost actual GPU opener')
      end
      exact(d,broken,a,mb)
      for _,owner in ipairs({d,r}) do
        local body=field(owner,'body'); exact(body,broken,mb,mb); assert(body:has_error(),'missing body lost its diagnostic')
        assert(body:parent():id()==owner:id(),'missing body borrowed caller')
      end
      local missing=0
      walk(n,function(c)
        if c:missing() or c:type()=='ERROR' then
          assert(c:missing() and c:type()=='Type','non-native or nonlocal missing-body error')
          assert(select(3,c:start())==mb and select(3,c:end_())==mb,'missing body borrowed source')
          missing=missing+1
        end
      end)
      assert(missing==2,'expected two actual missing values')
      capture('tags',d,broken,'name',a+4,a+5)
      for file,name in pairs({folds='fold',context='context',locals='local.scope',indents='indent.begin'}) do
        capture(file,d,broken,name,a,mb)
      end
    end
    local fresh=parse(broken); check(fresh)
    -- String parsers establish exact EOF. Neovim buffers implicitly append LF;
    -- native tree_edit evidence separately covers all no-final-LF edits.
    if broken:sub(-1)=='\n' then
      local buf=vim.api.nvim_create_buf(false,true)
      vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
      local parser=vim.treesitter.get_parser(buf,'bend2'); parser:parse()
      for _=1,3 do
        edit(buf,fixed,broken); local n=parser:parse()[1]:root(); check(n)
        assert(vim.deep_equal(sig(n),sig(fresh)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)),'fresh/incremental mismatch')
        edit(buf,broken,fixed); n=parser:parse()[1]:root()
        assert(vim.deep_equal(sig(n),sig(clean)) and vim.deep_equal(captures(n,fixed),captures(clean,fixed)),'repair mismatch')
        edits=edits+2
      end
      vim.api.nvim_buf_delete(buf,{force=true})
    end
  end)
  print((ok and 'PASS ' or 'FAIL ')..case.name..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end
assert(#failures==0,table.concat(failures,'\n'))
print(('Missing bodies: %d exact sources, %d minimal buffer edits, fields/ranges/captures and both real mandatory owners.'):format(#cases,edits))
vim.cmd('qa!')
