// Standalone serialization/bounds regression; no Tree-sitter runtime needed.
#include <assert.h>
#include <stdio.h>
#include "../src/scanner.c"

static void round_trip(Scanner *s) {
  char buffer[TREE_SITTER_SERIALIZATION_BUFFER_SIZE + 16];
  memset(buffer, 0x5a, sizeof(buffer));
  unsigned n = tree_sitter_bend2_external_scanner_serialize(s, buffer);
  assert(n <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE);
  for (unsigned i = n; i < sizeof(buffer); ++i) assert(buffer[i] == 0x5a);
  Scanner restored = {0};
  tree_sitter_bend2_external_scanner_deserialize(&restored, buffer, n);
  assert(restored.size == s->size);
  assert(restored.declaration_name == s->declaration_name);
  assert(restored.closed_string == s->closed_string);
  assert(restored.decorator_name == s->decorator_name);
  assert(restored.header_checkpoint == s->header_checkpoint);
  assert(restored.case_header == s->case_header);
  assert(restored.case_column == s->case_column);
  assert(restored.array_checkpoint == s->array_checkpoint);
  for (unsigned i = 0; i < s->size; ++i) {
    assert(restored.frames[i].kind == s->frames[i].kind);
    assert(restored.frames[i].column == s->frames[i].column);
    assert(restored.frames[i].first == s->frames[i].first);
  }
  char again[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
  assert(tree_sitter_bend2_external_scanner_serialize(&restored, again) == n);
  assert(memcmp(buffer, again, n) == 0);
  for (unsigned length = 0; length < n; ++length) {
    tree_sitter_bend2_external_scanner_deserialize(&restored, buffer, length);
    assert(restored.size == 0);
  }
}
// Mock lexer for grammar-owned, zero-width phase transitions.
typedef struct { TSLexer lexer; const char *text; unsigned at, end; } Probe;
static void probe_advance(TSLexer *l, bool skip) {
  (void)skip; Probe *p = (Probe *)l;
  if (p->text[p->at]) ++p->at;
  l->lookahead = p->text[p->at];
}
static void probe_mark(TSLexer *l) { Probe *p = (Probe *)l; p->end = p->at; }
static uint32_t probe_column(TSLexer *l) {
  Probe *p = (Probe *)l; uint32_t col = 0;
  for (unsigned i = 0; i < p->at; ++i) col = p->text[i] == '\n' ? 0 : col + 1;
  return col;
}
static bool probe_eof(const TSLexer *l) { return !l->lookahead; }
static Probe probe(const char *text) {
  return (Probe){.text = text, .lexer = {.lookahead = text[0], .advance = probe_advance,
    .mark_end = probe_mark, .get_column = probe_column, .eof = probe_eof}};
}
static void checkpoint_tests(void) {
  bool v[ARRAY_LAYOUT + 1] = {0}; v[BODY_ENTRY] = true;
  for (unsigned phase = PAR; phase <= PAR_HEADER; phase += PAR_HEADER - PAR) {
    Scanner s = {0}; assert(push(&s, BODY, 0) && push(&s, phase, 2));
    Probe p = probe("Type");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == BODY_ENTRY && p.end == 0 && p.at == 0);
    assert(s.size == (phase == PAR_HEADER ? 1 : 2));
    round_trip(&s);
    for (unsigned i = 0; i < 300; ++i) {
      p = probe("Type"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
      assert(s.size == (phase == PAR_HEADER ? 1 : 2));
      assert(s.frames[0].kind == BODY && s.frames[0].column == 0 && s.frames[0].first == UINT32_MAX);
      if (phase == PAR) assert(s.frames[1].kind == PAR && s.frames[1].column == 2 && s.frames[1].first == UINT32_MAX);
      assert(!s.declaration_name && !s.closed_string && !s.decorator_name);
      round_trip(&s);
    }
  }
  // Live value phases retain the full serialized payload, including flags.
  for (unsigned flags = 0; flags < 8; ++flags) {
    for (unsigned i = 0; i < 3; ++i) {
      uint32_t counts[] = {0, 1, UINT32_MAX};
      Scanner s = {.declaration_name = flags & 1, .decorator_name = flags & 2, .closed_string = flags & 4};
      assert(push(&s, BODY, 7) && push(&s, PAR, counts[i]));
      char before[TREE_SITTER_SERIALIZATION_BUFFER_SIZE], after[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
      unsigned n = tree_sitter_bend2_external_scanner_serialize(&s, before);
      Probe p = probe("Type");
      assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
      assert(p.lexer.result_symbol == BODY_ENTRY && p.at == 0 && p.end == 0);
      assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n));
      round_trip(&s);
    }
  }
  Scanner s = {0}; assert(push(&s, BODY, 0) && push(&s, PAR_HEADER, 2));
  v[ERROR_SENTINEL] = true; Probe p = probe("Type");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 2 && s.frames[1].kind == PAR_HEADER); round_trip(&s);
  v[ERROR_SENTINEL] = false;
  for (unsigned literal = 0; literal < 2; ++literal) {
    s = (Scanner){0}; assert(push(&s, BODY, 0) && push(&s, PAR_HEADER, 2));
    p = probe(literal ? "\"s\"" : "Type");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == BODY_ENTRY && p.end == 0 && s.size == 1);
    char state[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
    unsigned bytes = tree_sitter_bend2_external_scanner_serialize(&s, state);
    Scanner restored = {0}; tree_sitter_bend2_external_scanner_deserialize(&restored, state, bytes);
    bool terms[ARRAY_LAYOUT + 1] = {0}; terms[WRITE_START] = terms[IDENTIFIER] = terms[STRING_START] = true;
    p = probe(literal ? "\"s\"" : "Type");
    bool ok = tree_sitter_bend2_external_scanner_scan(&restored, &p.lexer, terms);
    assert(ok == (literal != 0));
    if (ok) assert(p.lexer.result_symbol == STRING_START && p.end == 1);
    assert(restored.size == 1 && restored.frames[0].kind == BODY); round_trip(&restored);
  }
  puts("BODY_ENTRY: zero-width, only stale header retired, actual values retained, error-mode inert, 300 entries bounded, phase persists before string/builtin lexing.");
}
static void ownership_tests(void) {
  bool all[ARRAY_LAYOUT + 1]; memset(all, 1, sizeof(all));
  bool v[ARRAY_LAYOUT + 1] = {0};
  Scanner s = {0}; v[DEF_KEYWORD] = true;
  Probe p = probe("def after");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == DEF_KEYWORD && s.header_checkpoint && s.declaration_name);
  round_trip(&s);
  memset(v, 0, sizeof(v)); v[DECLARATION_NAME] = v[IDENTIFIER] = true;
  p = probe("after"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  p = probe("after"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
  assert(s.header_checkpoint); round_trip(&s);
  memset(v, 0, sizeof(v)); v[HEADER_CHECKPOINT] = true;
  p = probe("after"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(!s.header_checkpoint && p.at == 0 && p.end == 0); round_trip(&s);
  memset(v, 0, sizeof(v)); v[DECLARATION_NAME] = true;
  p = probe("after"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == DECLARATION_NAME && p.end == 5); round_trip(&s);

  s = (Scanner){.header_checkpoint = true};
  p = probe("@unsafe def after");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
  assert(p.lexer.result_symbol == DECORATOR_START && s.decorator_name && !s.header_checkpoint);
  round_trip(&s);
  s = (Scanner){0};
  memset(v, 0, sizeof(v)); v[HEADER_CHECKPOINT] = true;
  p = probe("after"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));

  // Initial entry retains an invalid byte's actual owner; a let continuation
  // does not steal the grammar's legal optional semicolon.
  assert(push(&s, BODY, 0));
  memset(v, 0, sizeof(v)); v[BODY_ENTRY] = true;
  p = probe(";"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == BODY_ENTRY && p.end == 0 && s.size == 1);
  memset(v, 0, sizeof(v)); v[CONTINUATION_ENTRY] = true;
  p = probe(";"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  round_trip(&s);

  // A recovery case word records its real column, but allocates no frame.
  assert(push(&s, MATCH, 0)); s.frames[1].first = 0;
  p = probe("case A{}"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
  assert(p.lexer.result_symbol == CASE && s.size == 2 && s.case_header && !s.case_column);
  round_trip(&s);
  memset(v, 0, sizeof(v)); v[CASE_HEADER_START] = true;
  p = probe(" A{}"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == CASE_HEADER_START && s.size == 3 && !s.case_header);
  assert(s.frames[2].kind == CASE_HEADER && s.frames[2].column == 1); round_trip(&s);
  p = probe("0n"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
  memset(v, 0, sizeof(v)); v[CASE_PATTERN_END] = true;
  p = probe(")"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.frames[2].kind == CASE_READY && p.end == 0); round_trip(&s);
  p = probe("0n"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
  assert(p.lexer.result_symbol == NATURAL && s.size == 3); round_trip(&s);

  // Pending and live PAR phases are abandoned only at an actual outer word;
  // normal body entry still retains every byte of a live value phase above.
  for (unsigned phase = PAR; phase <= PAR_HEADER; phase += PAR_HEADER - PAR) {
    for (unsigned error_mode = 0; error_mode < 2; ++error_mode) {
      s = (Scanner){0}; assert(push(&s, BODY, 0) && push(&s, phase, 2));
      memset(v, 0, sizeof(v)); v[BODY_END] = true;
      p = probe("def after"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, error_mode ? all : v));
      assert(p.lexer.result_symbol == BODY_END && !s.size && p.end == 0); round_trip(&s);
    }
  }
  // Same-column real siblings retire interrupted phases under their recorded
  // match, never interpreting missing parallel values as completed values.
  for (unsigned phase = PAR; phase <= PAR_HEADER; phase += PAR_HEADER - PAR) {
    s = (Scanner){0};
    assert(push(&s, BODY, 0) && push(&s, MATCH, 0) && push(&s, BODY, 5) && push(&s, phase, 2));
    s.frames[1].first = 4;
    memset(v, 0, sizeof(v)); v[BODY_END] = true;
    p = probe("    case B{}");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == BODY_END && s.size == 2 && p.end == 0);
    round_trip(&s);
  }
  s = (Scanner){0}; assert(push(&s, BODY, 0) && push(&s, PAR_HEADER, 2));
  memset(v, 0, sizeof(v)); v[BODY_ENTRY] = true;
  p = probe("case B{}"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 2 && s.frames[1].kind == PAR_HEADER); round_trip(&s);
  for (unsigned literal = 0; literal < 5; ++literal) {
    const char *inputs[] = {"(", "[", "x", ";", "$"};
    s = (Scanner){0}; assert(push(&s, BODY, 0));
    p = probe(inputs[literal]); (void)tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all);
    assert(s.size <= 1); round_trip(&s);
  }

  // New flags/payload have semantic validation, not just a byte-length check.
  char bytes[TREE_SITTER_SERIALIZATION_BUFFER_SIZE]; Scanner restored = {0};
  s = (Scanner){.header_checkpoint = true}; round_trip(&s);
  s.decorator_name = true;
  unsigned n = tree_sitter_bend2_external_scanner_serialize(&s, bytes);
  tree_sitter_bend2_external_scanner_deserialize(&restored, bytes, n);
  assert(!restored.size && !restored.header_checkpoint && !restored.decorator_name);
  s = (Scanner){0}; assert(push(&s, BODY, 0)); s.header_checkpoint = true;
  n = tree_sitter_bend2_external_scanner_serialize(&s, bytes);
  tree_sitter_bend2_external_scanner_deserialize(&restored, bytes, n); assert(!restored.size);
  for (unsigned invalid = 0; invalid < 2; ++invalid) {
    s = (Scanner){0}; assert(push(&s, invalid ? MATCH : BODY, 0));
    s.case_header = true; s.case_column = invalid ? UINT32_MAX : 0;
    n = tree_sitter_bend2_external_scanner_serialize(&s, bytes);
    tree_sitter_bend2_external_scanner_deserialize(&restored, bytes, n);
    assert(!restored.size && !restored.case_header && !restored.case_column);
  }
  s = (Scanner){0}; assert(push(&s, MATCH, 10)); s.frames[0].first = 20;
  s.case_header = true; s.case_column = 19;
  n = tree_sitter_bend2_external_scanner_serialize(&s, bytes);
  tree_sitter_bend2_external_scanner_deserialize(&restored, bytes, n);
  assert(!restored.size && !restored.case_header);
  s = (Scanner){0}; assert(push(&s, PAR_HEADER, UINT32_MAX));
  memset(v, 0, sizeof(v)); v[PARALLEL] = true;
  p = probe(" x"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.frames[0].column == UINT32_MAX); round_trip(&s);
  s = (Scanner){0}; while (push(&s, MATCH, 0)) {};
  p = probe("case"); assert(case_keyword(&s, &p.lexer, 70000)); round_trip(&s);
  assert(tree_sitter_bend2_external_scanner_serialize(&s, bytes) == TREE_SITTER_SERIALIZATION_BUFFER_SIZE);
  puts("Ownership: fresh keyword/name checkpoint, initial/continuation semicolons, normal-only case frames, closed patterns, interrupted PAR owners and validated pending payloads passed.");
}
static void terminal_body_tests(void) {
  bool v[ARRAY_LAYOUT + 1] = {0}; v[BODY_END] = v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = true;
  Scanner s = {0}; assert(push(&s, BODY, 0)); Probe p = probe("$");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == BODY_END && !s.size && !p.end); round_trip(&s);
  assert(push(&s, BODY, 0)); v[CALL_OPEN] = true; p = probe("$");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v)); assert(s.size == 1); round_trip(&s);
  memset(v, 1, sizeof(v)); p = probe("$");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v)); assert(s.size == 1); round_trip(&s);
  puts("Terminal body: exact normal end mask closes the function; extensible-expression and all-valid masks do not.");
}
static void arm_phase_tests(void) {
  Scanner s = {0}; assert(push(&s, BODY, 0) && push(&s, MATCH, 0));
  s.frames[1].first = 4; assert(push(&s, CASE_HEADER, 5));
  bool v[ARRAY_LAYOUT + 1] = {0}; v[CASE_BODY_START] = true;
  Probe p = probe("     x"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.frames[2].kind == CASE_ARM && s.size == 3); round_trip(&s);
  memset(v, 0, sizeof(v)); v[ARM_END] = true;
  for (unsigned i = 0; i < 5; ++i) {
    const char *invalid[] = {"     ;", "     )", "     ]", "     ^", "     $"};
    p = probe(invalid[i]); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(s.size == 3 && s.frames[2].kind == CASE_ARM); round_trip(&s);
  }
  p = probe("\n;"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == ARM_END && s.size == 2); round_trip(&s);
  char bytes[TREE_SITTER_SERIALIZATION_BUFFER_SIZE]; Scanner restored = {0};
  assert(push(&s, CASE_ARM, 5)); unsigned n = tree_sitter_bend2_external_scanner_serialize(&s, bytes);
  // Kind is bounded; its actual match owner and case column are validated too.
  for (unsigned i = 0; i < 3; ++i) {
    Scanner bad = s;
    if (i == 0) bad.frames[1].kind = BODY;
    if (i == 1) bad.frames[2].column = 0;
    if (i == 2) bad.frames[1].first = UINT32_MAX;
    n = tree_sitter_bend2_external_scanner_serialize(&bad, bytes);
    tree_sitter_bend2_external_scanner_deserialize(&restored, bytes, n);
    assert(!restored.size && !restored.case_header && !restored.header_checkpoint);
  }
  puts("CASE_ARM: normal-owned phase, five-byte payload, actual owner validation, suffix stays inside arm, dedented semicolon closes it.");
}
static void completed_owner_tests(void) {
  Scanner s = {0}; assert(push(&s, BODY, 0) && push(&s, FUNCTION_MATCH, 0)); s.frames[1].first = 4;
  bool v[ARRAY_LAYOUT + 1] = {0}, all[ARRAY_LAYOUT + 1]; memset(all, 1, sizeof(all));
  v[FUNCTION_MATCH_END] = v[FUNCTION_CASE] = true; Probe p = probe("\nx");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == FUNCTION_MATCH_END && !p.end && s.frames[1].kind == FUNCTION_MATCH_DONE); round_trip(&s);
  memset(v, 0, sizeof(v)); v[BODY_END] = v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = true; p = probe("\nx");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == BODY_END && !p.end && s.frames[0].kind == BODY_DONE); round_trip(&s);
  for (unsigned crlf = 0; crlf < 2; ++crlf) {
    Scanner copy = s; p = probe(crlf ? "\r\n    x" : "\n    x");
    assert(tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, v));
    assert(p.lexer.result_symbol == ROOT_LAYOUT && p.end == (crlf ? 6 : 5));
    assert(copy.frames[1].kind == FUNCTION_MATCH_LAYOUT); round_trip(&copy);
    char b[TREE_SITTER_SERIALIZATION_BUFFER_SIZE]; assert(tree_sitter_bend2_external_scanner_serialize(&copy, b) == 17);
    for (unsigned i = 0; i < 3; ++i) {
      memset(v, 0, sizeof(v)); v[i == 0 ? BODY_ENTRY : i == 1 ? BLOCK_START : LAMBDA_START] = true;
      p = probe("x"); assert(!tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, v));
      assert(copy.size == 2); round_trip(&copy);
    }
    assert(!push(&copy, PAR_HEADER, 2)); assert(!push(&copy, WRITE, 0));
    p = probe(""); assert(!tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, all)); round_trip(&copy);
    p = probe("    case B{}"); assert(tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, all));
    assert(p.lexer.result_symbol == FUNCTION_CASE && copy.case_header && copy.size == 2);
    assert(copy.frames[0].kind == BODY_DONE && copy.frames[1].kind == FUNCTION_MATCH_LAYOUT); round_trip(&copy);
    p = probe(" B{}"); assert(!tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, all));
    memset(v, 0, sizeof(v)); v[CASE_HEADER_START] = true; p = probe(" B{}");
    assert(tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, v));
    assert(copy.frames[0].kind == BODY && copy.frames[1].kind == FUNCTION_MATCH && copy.frames[2].kind == CASE_HEADER); round_trip(&copy);
    memset(v, 0, sizeof(v)); v[BODY_END] = v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = true;
  }
  for (unsigned i = 0; i < 6; ++i) {
    Scanner bad = s, restored = {0}; char b[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
    if (i == 0) bad.frames[0].column = 1;
    if (i == 1) bad.frames[1].column = 1;
    if (i == 2) bad.frames[0].kind = BLOCK;
    if (i == 3) bad.frames[1].kind = MATCH;
    if (i == 4) { bad.frames[2] = (Frame){0, UINT32_MAX, BLOCK}; bad.size = 3; }
    if (i == 5) bad.decorator_name = true;
    unsigned n = tree_sitter_bend2_external_scanner_serialize(&bad, b);
    tree_sitter_bend2_external_scanner_deserialize(&restored, b, n); assert(!restored.size);
  }
  for (unsigned decorated = 0; decorated < 2; ++decorated) {
    Scanner copy = s; p = probe(decorated ? "@unsafe def after" : "def after");
    assert(tree_sitter_bend2_external_scanner_scan(&copy, &p.lexer, all));
    assert(p.lexer.result_symbol == (decorated ? DECORATOR_START : DEF_KEYWORD) && !copy.size); round_trip(&copy);
  }
  puts("Root owner: real LF/CRLF extra, 17-byte completed pair, no duplicate ends/borrowed entries, actual case normal reactivation, fresh headers and malformed snapshots passed.");
}
static void pending_completion_tests(void) {
  Scanner s = {0}; bool v[ARRAY_LAYOUT + 1] = {0}; Probe p;
  assert(push(&s, BODY, 0) && push(&s, FUNCTION_MATCH, 0)); s.frames[1].first = 4;
  s.frames[1].kind = FUNCTION_MATCH_DONE; p = probe("case B{}");
  assert(case_keyword(&s, &p.lexer, 4)); round_trip(&s);
  v[BODY_END] = true; p = probe("");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 2 && s.case_header); round_trip(&s);
  for (unsigned i = 0; i <= ARRAY_LAYOUT; ++i) v[i] = true;
  p = probe(""); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 2 && s.case_header); round_trip(&s);
  memset(v, 0, sizeof(v)); v[CASE_HEADER_START] = true; p = probe(" B{}");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 3 && !s.case_header && s.frames[1].kind == FUNCTION_MATCH); round_trip(&s);
  puts("Pending real case: neither a foreign normal caller end nor all-valid EOF can retire its checkpoint; the normal case-header checkpoint remains reachable.");
}
static void nested_completed_tests(void) {
  Scanner s = {0}; bool v[ARRAY_LAYOUT + 1] = {0}; Probe p;
  assert(push(&s, BODY, 0) && push(&s, FUNCTION_MATCH, 0)); s.frames[1].first = 4;
  assert(push(&s, CASE_ARM, 5) && push(&s, ARM_MATCH, 5)); s.frames[3].first = 8;
  const enum Token ends[] = {ARM_MATCH_END, ARM_END, FUNCTION_MATCH_END, BODY_END};
  for (unsigned i = 0; i < 4; ++i) {
    memset(v, 0, sizeof(v)); v[ends[i]] = true; v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = true;
    p = probe("\n2"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == ends[i] && s.size == 4); round_trip(&s);
  }
  assert(s.frames[0].kind == BODY_DONE && s.frames[2].kind == ARM_DONE);
  memset(v, 0, sizeof(v)); v[ROOT_LAYOUT] = true; p = probe("\r\n2");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v) && p.end == 2); round_trip(&s);
  memset(v, 0, sizeof(v)); v[ARM_CASE] = true; p = probe("\n        case B{}");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == ARM_CASE && s.case_header && s.size == 4); round_trip(&s);
  memset(v, 0, sizeof(v)); v[CASE_HEADER_START] = true; p = probe(" B{}");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.frames[0].kind == BODY && s.frames[1].kind == FUNCTION_MATCH
    && s.frames[2].kind == CASE_ARM && s.frames[3].kind == ARM_MATCH && s.size == 5); round_trip(&s);
  puts("Nested completion: four real ends retain the actual ancestor chain; only root layout progresses; a real inner case reactivates all actual ancestors.");
}
static void block_entry_tests(void) {
  bool v[ARRAY_LAYOUT + 1] = {0}; v[BODY_ENTRY] = v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = true;
  const char *starts[] = {"def after", "type After", "law after", "x", "Type"};
  for (unsigned i = 0; i < sizeof(starts)/sizeof(*starts); ++i) {
    Scanner s = {0}; assert(push(&s, BLOCK, 0));
    char before[TREE_SITTER_SERIALIZATION_BUFFER_SIZE], after[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
    unsigned n = tree_sitter_bend2_external_scanner_serialize(&s, before);
    Probe p = probe(starts[i]);
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == BODY_ENTRY && !p.at && !p.end);
    assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n));
    round_trip(&s);
  }
  // Neither another caller nor all-valid recovery may borrow this checkpoint.
  Scanner s = {0}; assert(push(&s, BODY, 0)); Probe p = probe("def after");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  memset(v, 1, sizeof(v)); s = (Scanner){0}; assert(push(&s, BLOCK, 0)); p = probe("$");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(s.size == 1); round_trip(&s);
  puts("Block entry: normal mandatory checkpoint precedes a missing value; no source consumed, state unchanged, other callers/error-mode inert.");
}
static void block_operator_tests(void) {
  const struct { const char *text; enum Token token; unsigned end; } cases[] = {
    {" +1", PLUS, 2}, {" -1", MINUS, 2}, {" > 1", GT, 2},
    {" >= 1", GE, 3}, {" >> 1", SHR, 3}, {"% y", MOD, 1},
  };
  for (unsigned i = 0; i < sizeof(cases)/sizeof(*cases); ++i) {
    Scanner s = {0}; bool v[ARRAY_LAYOUT + 1] = {0}; v[BLOCK_START] = v[cases[i].token] = true;
    Probe p = probe(cases[i].text);
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == cases[i].token && p.end == cases[i].end && !s.size); round_trip(&s);
  }
  for (unsigned i = 0; i < 2; ++i) {
    Scanner s = {0}; bool v[ARRAY_LAYOUT + 1] = {0}; v[BLOCK_START] = v[PLUS] = true;
    Probe p = probe(i ? " +>" : " ++");
    assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v) && !s.size); round_trip(&s);
  }
  Scanner s = {0}; bool v[ARRAY_LAYOUT + 1] = {0}; v[BLOCK_START] = v[PLUS] = true;
  Probe p = probe(" +x"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == BLOCK_START && !p.end && s.size == 1 && s.frames[0].kind == BLOCK); round_trip(&s);
  memset(v, 0, sizeof(v)); v[BLOCK_START] = v[MOD] = true;
  s = (Scanner){0}; p = probe("%e:T;0");
  assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
  assert(p.lexer.result_symbol == BLOCK_START && !p.end && s.size == 1); round_trip(&s);
  memset(v, 1, sizeof(v)); s = (Scanner){0}; p = probe("% y");
  assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v) && !s.size); round_trip(&s);
  puts("Block operators: enabled arithmetic/comparisons retain their operands without allocating a body; glued reusable names still enter it.");
}
static void nested_sibling_end_tests(void) {
  for (unsigned crlf = 0; crlf < 2; ++crlf) {
    Scanner s = {0};
    assert(push(&s, BODY, 0) && push(&s, FUNCTION_MATCH, 0)); s.frames[1].first = 4;
    assert(push(&s, CASE_ARM, 5) && push(&s, ARM_MATCH, 5)); s.frames[3].first = 8;
    assert(push(&s, CASE_ARM, 9) && push(&s, ARM_MATCH, 9)); s.frames[5].first = 12;
    s.frames[4].kind = ARM_DONE; s.frames[5].kind = ARM_MATCH_DONE; round_trip(&s);
    bool all[ARRAY_LAYOUT + 1]; memset(all, 1, sizeof(all));
    Probe p = probe(crlf ? "\r\n    case B{}" : "\n    case B{}");
    Scanner recovery = s;
    assert(!tree_sitter_bend2_external_scanner_scan(&recovery, &p.lexer, all));
    assert(!memcmp(&s, &recovery, sizeof(s))); round_trip(&recovery);
    bool v[ARRAY_LAYOUT + 1] = {0};
    v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = v[ARM_MATCH_END] = v[ARM_CASE] = true;
    p = probe(crlf ? "\r\n    case B{}" : "\n    case B{}");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == ARM_MATCH_END && !p.end && s.size == 6);
    assert(s.frames[3].kind == ARM_MATCH_DONE && s.frames[1].kind == FUNCTION_MATCH); round_trip(&s);
    memset(v, 0, sizeof(v)); v[ROOT_LAYOUT] = v[ARRAY_LAYOUT] = v[ARM_END] = true;
    p = probe(crlf ? "\r\n    case B{}" : "\n    case B{}");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == ARM_END && s.frames[2].kind == ARM_DONE); round_trip(&s);
    memset(v, 0, sizeof(v)); v[FUNCTION_MATCH_END] = v[FUNCTION_CASE] = true;
    p = probe(crlf ? "\r\n    case B{}" : "\n    case B{}");
    assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
    assert(p.lexer.result_symbol == FUNCTION_CASE && s.size == 2 && s.case_header); round_trip(&s);
  }
  puts("Nested sibling: normal ancestor end, real outer arm/case, LF/CRLF and all-valid inert ownership passed.");
}
int main(void) {
  nested_sibling_end_tests();
  block_entry_tests();
  block_operator_tests();
  pending_completion_tests();
  nested_completed_tests();
  completed_owner_tests();
  terminal_body_tests();
  arm_phase_tests();
  ownership_tests();
  checkpoint_tests();
  Scanner s = {0};
  s.declaration_name = s.closed_string = s.decorator_name = true;
  for (unsigned i = 0; i < 200; ++i) {
    assert(push(&s, BODY, UINT32_MAX - i));
    round_trip(&s);
  }
  assert(!push(&s, BODY, 0));
  round_trip(&s);
  for (unsigned kind = BODY; kind <= MATCH_CLOSED_ARM; ++kind) {
    memset(&s, 0, sizeof(s));
    if (kind == CASE_ARM) {
      while (push(&s, MATCH, 0)) {
        s.frames[s.size-1].first = 4;
        if (!push(&s, CASE_ARM, 5)) break;
        round_trip(&s);
      }
      assert(s.size >= 100); round_trip(&s); continue;
    }
    while (push(&s, kind, UINT32_MAX)) {
      if (kind == MATCH || kind == MATCH_CLOSED_ARM)
        s.frames[s.size - 1].first = s.size % 2 ? UINT32_MAX : 70000;
      round_trip(&s);
    }
    assert(s.size >= 100);
    round_trip(&s);
  }
  for (unsigned flags = 0; flags < 8; ++flags) {
    memset(&s, 0, sizeof(s));
    s.declaration_name = flags & 1;
    s.decorator_name = flags & 2;
    s.closed_string = flags & 4;
    assert(push(&s, CASE_HEADER, 7) && push(&s, BLOCK, 9));
    round_trip(&s);
  }
  char invalid[] = {1, 3, 1, LAMBDA_MATCH_LAYOUT + 1, 0, 0, 0, 0};
  tree_sitter_bend2_external_scanner_deserialize(&s, invalid, sizeof(invalid));
  assert(!s.size && !s.declaration_name && !s.decorator_name && !s.closed_string);
  invalid[0] = 0; invalid[1] = 32;
  tree_sitter_bend2_external_scanner_deserialize(&s, invalid, 3);
  assert(!s.size && !s.declaration_name && !s.decorator_name && !s.closed_string);
  puts("Scanner: deep stacks, all frame kinds/flags, full-width columns, bounded serialization and truncated states passed.");
  return 0;
}
