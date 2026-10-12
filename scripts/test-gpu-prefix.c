// Actual ABI-15 masks: GPU lexing never fabricates a scope or changes recovery state.
#define main scanner_unit_main
#include "test-scanner.c"
#undef main
extern const TSLanguage *tree_sitter_bend2(void);
int main(void) {
  assert(scanner_unit_main() == 0);
  const TSLanguage *lang = tree_sitter_bend2();
  unsigned max = 0, masks = 0, checks = 0;
  for (unsigned i = 0; i < lang->state_count; ++i)
    if (lang->lex_modes[i].external_lex_state > max) max = lang->lex_modes[i].external_lex_state;
  const bool *open = NULL;
  for (unsigned m = 1; m <= max; ++m) {
    const bool *v = lang->external_scanner.states + m * lang->external_token_count;
    if (v[GPU_OPEN] && !v[ERROR_SENTINEL]) open = v;
  }
  assert(open);
  const bool *all = lang->external_scanner.states + lang->external_token_count;
  for (unsigned i = 0; i < lang->external_token_count; ++i) assert(all[i]);
  for (unsigned m = 1; m <= max; ++m) {
    const bool *v = lang->external_scanner.states + m * lang->external_token_count;
    if (!v[GPU_MODIFIER]) continue;
    ++masks;
    for (unsigned capacity = 0; capacity < 2; ++capacity) {
      Scanner s = {0}; if (capacity) while (push(&s, GROUP, 7)) {};
      char before[TREE_SITTER_SERIALIZATION_BUFFER_SIZE], after[TREE_SITTER_SERIALIZATION_BUFFER_SIZE];
      unsigned n = tree_sitter_bend2_external_scanner_serialize(&s, before);
      for (unsigned cycle = 0; cycle < 3; ++cycle) {
        Probe p = probe("!(x)");
        assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
        assert(p.lexer.result_symbol == GPU_MODIFIER && p.end == 1);
        assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n));
        round_trip(&s); ++checks;
        p = probe("(x)"); assert(tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, open));
        assert(p.lexer.result_symbol == GPU_OPEN && p.end == 1);
        assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n));
        round_trip(&s); ++checks;
      }
      for (unsigned bad = 0; bad < 4; ++bad) {
        Probe p = probe((const char *[]){"!x", "! (x)", "!\r\n(x)", "!!(x)"}[bad]);
        assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, v));
        assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n));
        ++checks;
      }
      Probe p = probe("(x)"); assert(!tree_sitter_bend2_external_scanner_scan(&s, &p.lexer, all));
      assert(tree_sitter_bend2_external_scanner_serialize(&s, after) == n && !memcmp(before, after, n)); ++checks;
    }
  }
  printf("GPU: %u actual masks, %u checks; normal real openers, all-valid inert ownership, three cycles and full bounds.\n", masks, checks);
  return 0;
}
