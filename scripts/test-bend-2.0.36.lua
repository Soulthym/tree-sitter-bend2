-- Bend v2.0.36 witnesses; raw TSTree edits keep literal EOF exact.
-- BEND2_UPSTREAM defaults to ../bend and must match the pinned release.
vim.treesitter.language.add('bend2', {path=vim.env.BEND2_PARSER or 'build/bend2.so'})
local upstream=vim.env.BEND2_UPSTREAM or vim.fn.getcwd()..'/../bend'
local qs={}; for _,f in ipairs({'highlights','locals','tags','folds','context','textobjects','indents'}) do
  qs[f]=vim.treesitter.query.parse('bend2',table.concat(vim.fn.readfile('queries/'..f..'.scm'),'\n'))
end
local function sig(n)
  local out={n:type(),{n:start()},{n:end_()},n:named(),n:missing(),n:extra()}
  for c,f in n:iter_children() do out[#out+1]={f or '',sig(c)} end;return out
end
local function captures(n,s)
  local out={};for f,q in pairs(qs) do local rows={}
    for id,c in q:iter_captures(n,s,0,-1) do rows[#rows+1]={q.captures[id],c:type(),{c:start()},{c:end_()},vim.treesitter.get_node_text(c,s)} end
    table.sort(rows,function(a,b)return vim.json.encode(a)<vim.json.encode(b)end);out[f]=rows
  end;return out
end
local function point(s,b) local pre=s:sub(1,b);local _,r=pre:gsub('\n','');return r,#pre-(pre:match('.*\n()') or 1)+1 end
local function walk(n,f) f(n);for c in n:iter_children() do walk(c,f) end end
local function exact(n,s,part,from)
  local a,b=assert(s:find(part,from or 1,true));assert(select(3,n:start())==a-1 and select(3,n:end_())==b,'range '..part)
  local sr,sc=point(s,a-1);local er,ec=point(s,b);assert(vim.deep_equal({n:range()},{sr,sc,er,ec}),'point '..part)
end
local function field(n,f) local ns=n:field(f);assert(#ns==1,'field '..f);return ns[1] end
local function validate(n,s,err)
  assert(n:has_error()==err,'wrong acceptance');walk(n,function(c)
    local sr,sc=point(s,select(3,c:start()));local er,ec=point(s,select(3,c:end_()))
    assert(vim.deep_equal({c:range()},{sr,sc,er,ec}),'point mismatch')
  end)
  local lambda_count=0
  walk(n,function(c)
    if c:type()=='lambda_expression' and field(c,'parameter'):type()=='parenthesized_expression' then
      lambda_count=lambda_count+1;local p=field(c,'parameter');local body=field(p,'body');local t=field(p,'type')
      assert(t:type()=='identifier','annotation owner');local first=p:child(0);local last=p:child(p:child_count()-1)
      assert(first:type()=='(' and last:type()==')' and not first:missing() and not last:missing(),'actual binder delimiters')
      assert(last:parent():id()==p:id() and body:parent():id()==p:id(),'binder ownership')
      local name=body:named_child(0);if name:type()=='reusable_expression' then name=name:named_child(0) end
      assert(name:type()=='identifier','name pattern binder')
      for file,role in pairs({highlights='variable.parameter',locals='local.definition'}) do
        local found=false;for id,x in qs[file]:iter_captures(c,s,0,-1) do if qs[file].captures[id]==role and x:id()==name:id() then found=true end end
        assert(found,'missing annotated binder '..file..' @'..role)
      end
      assert(field(c,'body'):parent():id()==c:id(),'lambda body owner')
    end
    if c:type()=='case_clause' then
      local m=c:parent();assert(m:type()=='match_expression','case outside actual match')
      local pattern=field(c,'pattern');local body=field(c,'body');assert(pattern:parent():id()==c:id() and body:parent():id()==c:id(),'arm fields')
      local _,case_col=c:start();local _,match_col=m:start();assert(case_col>0 and match_col>=0,'case layout')
    end
  end)
  if s:find('(x: Nat)',1,true) or s:find('(+x: Nat)',1,true) or s:find('kind_terms_result_marker',1,true) then assert(lambda_count>0,'lost lambda') end
end
local function fresh(s) return vim._create_ts_parser('bend2'):parse(nil,s) end
local function transition(parser,tree,from,to)
  local a,z=0,0;while a<math.min(#from,#to) and from:byte(a+1)==to:byte(a+1) do a=a+1 end
  while z<math.min(#from,#to)-a and from:byte(#from-z)==to:byte(#to-z) do z=z+1 end
  local er,ec=point(from,#from-z);local nr,nc=point(to,#to-z);local sr,sc=point(from,a)
  tree=tree:edit(a,#from-z,#to-z,sr,sc,er,ec,nr,nc);return parser:parse(tree,to)
end
local before='import Base\ndef before() -> U32: 1\n'
local after='\ntype Next is Data: N{}\nlaw next_law: U32\ndef after() -> U32: 42'
local cases={
  {name='annotated binder',text=before..'def probe() -> Nat -> Nat: (x: Nat) => x'..after},
  {name='reusable annotated binder',text=before..'def probe() -> Nat -> Nat: (+x: Nat) => x'..after},
  {name='law grouped body',text=before..'law probe: (x: Nat) => (x : Nat)'..after},
  {name='missing lambda body',text=before..'law probe: (x: Nat) =>',error=true,repair=' x'},
  {name='wrong binder',text=before..'law probe: (x + 1 : Nat) => x'..after,error=true},
  {name='triple outer sibling',text='import Base\ndef probe(a: Bool, b: Bool, c: Bool) -> U32:\n  match a:\n    case False{}:\n      match b:\n        case False{}:\n          match c:\n            case False{}: 0\n    case True{}: 2'..after},
  {name='triple two branches',text='import Base\ndef probe(a: Bool, b: Bool, c: Bool) -> U32:\n  match a:\n    case False{}:\n      match b:\n        case False{}:\n          match c:\n            case False{}: 0\n        case True{}:\n          match c:\n            case False{}: 1\n    case True{}: 2'..after},
}
for _,f in ipairs({'convoy_dependent','kind_terms'}) do cases[#cases+1]={name=f,text=table.concat(vim.fn.readfile(upstream..'/tests/check/'..f..'.bend','b'),'\n'):gsub('\n$','')} end
local results,failures,edits={}, {},0
for _,case in ipairs(cases) do for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do
  local s=(case.text..ending):gsub('\n',nl);local label=case.name..(nl=='\n' and ' LF' or ' CRLF')..(ending=='' and ' EOF' or ' final LF')
  local ok,err=pcall(function()
    local parser=vim._create_ts_parser('bend2');local tree=parser:parse(nil,s);local ref=fresh(s);validate(ref:root(),s,case.error or false)
    assert(vim.deep_equal(sig(tree:root()),sig(ref:root())),'initial exact parse differs')
    if case.name=='missing lambda body' then
      -- Missing tokens insert at the consumed arrow, before trailing extras.
      local at=assert(s:find('=>',1,true))+1
      local count=0;walk(ref:root(),function(c)if c:missing() or c:type()=='ERROR' then count=count+1;assert(c:missing() and select(3,c:start())==at and select(3,c:end_())==at,'missing body borrowed source')end end)
      assert(count==1,'missing body diagnostic count')
    end
    if case.name=='wrong binder' then
      local at,last=assert(s:find('=> x',1,true));local errors=0
      walk(ref:root(),function(c)if c:missing() or c:type()=='ERROR' then
        errors=errors+1;assert(c:type()=='ERROR' and not c:missing(),'binder rejection synthesized a token')
        assert(select(3,c:start())==at-1 and select(3,c:end_())==last,'wrong binder error crossed the real group')
      end end);assert(errors==1,'binder rejection error count')
    end
    local function declaration(name)
      for c in ref:root():iter_children() do local x=c:field('name')[1];if x and vim.treesitter.get_node_text(x,s)==name then return c end end
      error('lost declaration '..name)
    end
    for _,name in ipairs({'before','Next','next_law','after'}) do if s:find(name,1,true) then
      local d=declaration(name);assert(not d:has_error(),'damaged neighbor '..name)
      local a,b=assert(s:find(name=='Next' and 'type Next is Data: N{}' or name=='next_law' and 'law next_law: U32' or name=='before' and 'def before() -> U32: 1' or 'def after() -> U32: 42',1,true));exact(d,s,s:sub(a,b),a)
    end end
    local function arms(m,expected,value)
      assert(m:type()=='match_expression' and vim.treesitter.get_node_text(field(m,'value'),s)==value,'wrong match owner '..value)
      local rows={};for c in m:iter_children() do if c:type()=='case_clause' then rows[#rows+1]=c end end
      assert(#rows==expected,'case count under '..value);return rows
    end
    if case.name:find('triple',1,true) or case.name=='convoy_dependent' then
      local d=declaration(case.name=='convoy_dependent' and 'pick_deep' or 'probe');local root=arms(field(d,'body'):named_child(0),2,'a')
      local twice=case.name~='triple outer sibling';local middle=arms(field(root[1],'body'):named_child(0),twice and 2 or 1,'b')
      for _,row in ipairs(middle) do arms(field(row,'body'):named_child(0),case.name=='convoy_dependent' and 2 or 1,'c') end
      assert(vim.treesitter.get_node_text(field(root[2],'pattern'),s)=='True{}','outer sibling borrowed')
    end
    if case.name=='kind_terms' then
      local d=declaration('main');local binders={};walk(d,function(c)if c:type()=='lambda_expression' then
        local param=field(c,'parameter');assert(param:type()=='parenthesized_expression','typed lambda kind')
        binders[vim.treesitter.get_node_text(param,s)]=vim.treesitter.get_node_text(field(c,'body'),s)
        assert(c:parent():type()=='constructor_expression','lambda escaped Mk/MkDuo argument')
      end end);assert(vim.deep_equal(binders,{['(y: Nat)']='1n',['(z: Nat)']='z'}),'full kind_terms lambda owners')
    end
    local at=math.floor(#s/2);local change=s:sub(1,at)..' '..s:sub(at+1)
    if case.repair then change=s..case.repair end
    for _=1,3 do
      tree=transition(parser,tree,s,change);local f=fresh(change)
      assert(vim.deep_equal(sig(tree:root()),sig(f:root())) and vim.deep_equal(captures(tree:root(),change),captures(f:root(),change)),'edited full CST/seven queries differ')
      tree=transition(parser,tree,change,s);validate(tree:root(),s,case.error or false)
      assert(vim.deep_equal(sig(tree:root()),sig(ref:root())) and vim.deep_equal(captures(tree:root(),s),captures(ref:root(),s)),'repaired full CST/seven queries differ');edits=edits+2
    end
    results[#results+1]={name=label,source=s,error=case.error or false,cst=sig(ref:root()),captures=captures(ref:root(),s)}
  end)
  if not ok then failures[#failures+1]=label..': '..tostring(err);print('FAIL '..failures[#failures]) else print('PASS '..label) end
end end end
if vim.env.BEND2_REPORT then
  vim.fn.writefile({vim.json.encode({results=results,failures=failures,edits=edits})},vim.env.BEND2_REPORT)
end
assert(#failures==0,table.concat(failures,'\n'));print(('v36: %d cases, %d exact-string edits, full CST/fields/points/seven queries passed.'):format(#results,edits));vim.cmd('qa!')
