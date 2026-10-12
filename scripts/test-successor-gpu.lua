-- Full successor operands retain their real postfix caller through native errors.
-- Exact-EOF fresh checks; LF buffers additionally exercise three minimal repairs.
vim.treesitter.language.add('bend2', {path=vim.env.BEND2_PARSER or 'build/bend2.so'})
local function queries(lang)
  local out={}
  for _,f in ipairs({'highlights','tags','textobjects','locals','context','folds','indents'}) do
    out[f]=vim.treesitter.query.parse(lang,table.concat(vim.fn.readfile('queries/'..f..'.scm'),'\n'))
  end
  return out
end
local qs,base_qs=queries('bend2')
if vim.env.BEND2_BASE_PARSER then
  vim.treesitter.language.add('bend2_base',{path=vim.env.BEND2_BASE_PARSER,symbol_name='bend2'})
  base_qs=queries('bend2_base')
end
local function parse(s,lang) return vim.treesitter.get_string_parser(s,lang or 'bend2'):parse()[1]:root() end
local function point(s,at)
  local pre=s:sub(1,at); local _,row=pre:gsub('\n','')
  return row,#pre-(pre:match('.*\n()') or 1)+1
end
local function signature(n,s,at)
  if at and n:type()=='ERROR' then return nil end
  local function relocate(b) return at and b>at and b-1 or b end
  local a,b=relocate(select(3,n:start())),relocate(select(3,n:end_()))
  local sr,sc,er,ec=n:range()
  if at then sr,sc=point(s,a); er,ec=point(s,b) end
  local out={n:type(),a,b,sr,sc,er,ec,n:missing(),n:named(),n:extra()}
  for c,f in n:iter_children() do local x=signature(c,s,at); if x then out[#out+1]={f or '',x} end end
  return out
end
local function captures(n,source,at,compiled)
  local out={}
  local repaired=at and source:sub(1,at)..source:sub(at+2) or source
  for f,q in pairs(compiled or qs) do
    local rows={}
    for id,c in q:iter_captures(n,source,0,-1) do
      local a,b=select(3,c:start()),select(3,c:end_())
      if not at or a~=at or b~=at+1 then
        if at then a=a>at and a-1 or a; b=b>at and b-1 or b end
        local sr,sc,er,ec=c:range()
        if at then sr,sc=point(repaired,a); er,ec=point(repaired,b) end
        rows[#rows+1]={q.captures[id],c:type(),a,b,sr,sc,er,ec}
      end
    end
    table.sort(rows,function(a,b)return vim.json.encode(a)<vim.json.encode(b)end); out[f]=rows
  end
  return out
end
local function walk(n,f) f(n);for c in n:iter_children() do walk(c,f) end end
local specs={
  {'motive','def b()->T:%e:TERM;0'},
  {'named motive','def b()->T:%w@e:TERM;0'},
  {'nested motive','def b()->T:%e:%f:TERM;0;0'},
  {'proof','def b()->T:%TERM:T;0'},
  {'law type','law b:for v:TERM\nT'},
  {'template type','law b:for ~v:TERM\nT'},
  {'constraint','law b:for v:T where TERM\nT'},
  {'existential','law b:exs v:TERM\nT'},
  {'parameter','def b(p:TERM)->T:0'},
  {'return type','def b()->TERM:0'},
  {'typed let value','def b()->T:p:T=TERM;p'},
  {'group','def b()->T:%e:(TERM);0'},
  {'GPU argument','def b()->T:%e:h!(TERM);0'},
  {'array value','def b()->T:%e:[TERM:T ^ 2n];0'},
  {'array type','def b()->T:%e:[x:(TERM) ^ 2n];0'},
  {'sibling arm','type T is Data:A{} B{}\ndef b(x:T)->T:match x:\n  case A{}:%e:TERM;0\n  case B{}:h!(x)'},
}
local cases={}
local before='def before()->U32:1\nlaw prior:T\n'
local after='\ntype Next is Data:N{}\nlaw next_law:T\ndef after()->U32:42'
local function add(name,stem,prefix,head,args,nl,ending,neighbors)
  local function source(op)
    local text=stem:gsub('TERM',prefix..head..op..args)
    return ((neighbors and before or '')..text..(neighbors and after or '')..ending):gsub('\n',nl)
  end
  for _,op in ipairs({'-','+'}) do
    cases[#cases+1]={name=name..' '..prefix..head..op..args..' '..(nl=='\n' and 'LF' or 'CRLF')
      ..(ending=='' and ' EOF' or ' final LF')..(neighbors and ' neighbors' or ''),text=source(op),fixed=source(''),head=head,args=args:gsub('\n',nl),op=op}
  end
end
for _,spec in ipairs(specs) do for _,prefix in ipairs({'0n+','1n+','0n+1n+','1n+0n+'}) do
  for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do for _,neighbors in ipairs({false,true}) do
    add(spec[1],spec[2],prefix,'g','!(x)',nl,ending,neighbors)
  end end end
end end
for _,shape in ipairs({{'lib.g','!(h!(x))'},{'g','!(~T,x)'},{'g','!((x:T))'}}) do
  for _,prefix in ipairs({'0n+','1n+'}) do for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do
    local stem='def g(~k:Type,x:T)->T:x\ndef b()->T:%e:TERM;0'
    add('nested/template/annotation',stem,prefix,shape[1],shape[2],nl,ending,true)
  end end end
end
-- Operand layout and real closers are independent of parenthesis alignment.
for _,spec in ipairs({specs[1],specs[5],specs[8]}) do
  for _,prefix in ipairs({'0n+\n  ','1n+# operand\n  '}) do for _,args in ipairs({'!(x)','!(\n x\n)'}) do
    for _,nl in ipairs({'\n','\r\n'}) do for _,ending in ipairs({'','\n'}) do
      add('operand layout '..spec[1],spec[2],prefix,'g',args,nl,ending,true)
    end end
  end end
end
-- Recursion is the real syntax, not a scanner depth counter or source heuristic.
for _,depth in ipairs({8,64}) do add('recursive operand '..depth,'def b()->T:%e:TERM;0',('1n+'):rep(depth),'g','!(x)','\n','',false) end
if vim.env.BEND2_SUCCESSOR_CASES then vim.fn.writefile({vim.json.encode(cases)},vim.env.BEND2_SUCCESSOR_CASES) end
local failures,edits,results={},0,{}
for _,case in ipairs(cases) do
  local buf
  local ok,err=pcall(function()
    local fixed,broken=case.fixed,case.text
    local control=parse(fixed); assert(not control:has_error(),'invalid control')
    if base_qs then
      local base=parse(fixed,'bend2_base'); assert(not base:has_error(),'baseline rejects control')
      assert(vim.deep_equal(signature(control,fixed),signature(base,fixed)) and
        vim.deep_equal(captures(control,fixed),captures(base,fixed,nil,base_qs)),
        'changed accepted control CST/fields/points/seven queries')
    end
    local at=assert(broken:find(case.head..case.op..case.args,1,true))+#case.head-1
    assert(broken:sub(1,at)..broken:sub(at+2)==fixed,'not a true one-byte repair')
    local function check(n)
      assert(n:has_error(),'syntax-invalid source became clean')
      local errors=0
      walk(n,function(c)
        local sr,sc=point(broken,select(3,c:start())); local er,ec=point(broken,select(3,c:end_()))
        assert(vim.deep_equal({c:range()},{sr,sc,er,ec}),'wrong actual broken-node points')
        if c:type()=='ERROR' or c:missing() then
          errors=errors+1
          assert(not c:missing() and c:type()=='ERROR' and select(3,c:start())==at and select(3,c:end_())==at+1,'error stole a real operand/delimiter/body')
        end
      end)
      assert(errors==1,'not one native localized error')
      -- Removing only the rejected byte must restore every actual public owner,
      -- including the nearest successor value, GPU argument closers and siblings.
      assert(vim.deep_equal(signature(n,fixed,at),signature(control,fixed)),'changed real owner/field/node/range')
      assert(vim.deep_equal(captures(n,broken,at),captures(control,fixed)),'changed one of seven query capture sets')
      local found=false
      walk(n,function(c)
        if c:type()=='call_expression' and select(3,c:start())==at-#case.head then
          local fn,args=c:field('function')[1],c:field('arguments')[1]
          assert(fn:type()=='identifier' and vim.treesitter.get_node_text(fn,broken)==case.head,'wrong callee alias')
          assert(c:parent():type()=='natural_successor' and c:parent():field('value')[1]:id()==c:id(),'not the nearest successor value')
          assert(args:named_child(0):type()=='gpu_call' and args:child(args:child_count()-1):type()==')','lost real GPU arguments closer')
          found=true
        end
      end)
      assert(found,'lost actual atomic GPU caller')
    end
    local fresh=parse(broken); check(fresh)
    if fixed:sub(-1)=='\n' then
      buf=vim.api.nvim_create_buf(false,true)
      vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(fixed:sub(1,-2),'\n',{plain=true}))
      local function bytes() return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')..'\n' end
      assert(bytes()==fixed,'wrong initial buffer bytes')
      local parser=vim.treesitter.get_parser(buf,'bend2')
      assert(vim.deep_equal(signature(parser:parse()[1]:root(),fixed),signature(control,fixed)),
        'wrong initial buffer tree')
      local sr,sc=point(fixed,at)
      for _=1,3 do
        vim.api.nvim_buf_set_text(buf,sr,sc,sr,sc,{case.op})
        assert(bytes()==broken,'wrong inserted buffer bytes')
        local n=parser:parse()[1]:root();check(n)
        assert(vim.deep_equal(signature(n,broken),signature(fresh,broken)) and vim.deep_equal(captures(n,broken),captures(fresh,broken)),'fresh/incremental differs')
        vim.api.nvim_buf_set_text(buf,sr,sc,sr,sc+1,{''})
        assert(bytes()==fixed,'wrong repaired buffer bytes')
        n=parser:parse()[1]:root()
        assert(vim.deep_equal(signature(n,fixed),signature(control,fixed)) and vim.deep_equal(captures(n,fixed),captures(control,fixed)),'repair differs')
        edits=edits+2
      end
    end
  end)
  if buf then vim.api.nvim_buf_delete(buf,{force=true}) end
  results[#results+1]={name=case.name,pass=ok,error=not ok and tostring(err) or nil}
  print((ok and 'PASS ' or 'FAIL ')..case.name..(ok and '' or ': '..tostring(err)))
  if not ok then failures[#failures+1]=tostring(err) end
end
if vim.env.BEND2_SUCCESSOR_REPORT then
  vim.fn.writefile({vim.json.encode({cases=#cases,passed=#cases-#failures,edits=edits,results=results})},
    vim.env.BEND2_SUCCESSOR_REPORT)
end
assert(#failures==0,table.concat(failures,'\n'))
print(('Successor GPU: %d exact vectors, %d minimal buffer edits; full repaired-owner CST and seven queries.'):format(#cases,edits))
vim.cmd('qa!')
