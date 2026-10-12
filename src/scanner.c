#include "tree_sitter/parser.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Order must match grammar.js. Layout is Bend's case-column / do-continuation
// rule, not Python indentation. All state is serialized for incremental parsing.
enum Token {
  FUNCTION_START, BLOCK_START, BODY_END, LAMBDA_START, MATCH_START, MATCH_END, CASE,
  DO_START, DO_END, DO_MORE, CALL_OPEN, INDEX_OPEN,
  PLUS, MINUS, GT, GE, SHR, MOD, PARALLEL, PARALLEL_START, PARALLEL_VALUE, PARALLEL_END,
  WRITE_START, WRITE_MORE, WRITE_END, IMPORT_START, IMPORT_END, INTEGER, NATURAL, FLOAT, IDENTIFIER,
  DEF_KEYWORD, TYPE_KEYWORD, LAW_KEYWORD, DECLARATION_NAME,
  STRING_START, STRING_NEWLINE, LT, GLUED_LT, GLUED_COMPARISON_END, ERROR_SENTINEL, GPU_OPEN,
  GPU_MODIFIER, CASE_BODY_START, DECORATOR_START, AT, UNSAFE_KEYWORD,
  PATTERN_SEPARATOR, SUCCESSOR_NATURAL, ZERO_NATURAL, NATURAL_PLUS, AMP, NATURAL_SUCCESSOR_END,
  MODULE_ALIAS, BODY_ENTRY, ARRAY_TYPE_END, CONTINUATION_ENTRY, HEADER_CHECKPOINT, CASE_PATTERN_END, CASE_HEADER_START, ROOT_LAYOUT, ARM_END, BLOCK_END, LAMBDA_END, GROUP_START, GROUP_END, FUNCTION_MATCH_START, FUNCTION_MATCH_END, FUNCTION_CASE, ARM_MATCH_START, ARM_MATCH_END, ARM_CASE, BLOCK_MATCH_START, BLOCK_MATCH_END, BLOCK_CASE, LAMBDA_MATCH_START, LAMBDA_MATCH_END, LAMBDA_CASE, ARRAY_LAYOUT,
};
// DONE frames retain a completed direct function/match as bounded past context.
// They are not active scopes: only the normal checkpoint following a consumed
// case keyword can reactivate them. LAYOUT remembers consumed root LF, not a
// prediction of a later case/declaration.
enum Kind { BODY, MATCH, DO, PAR, LAMBDA, WRITE, CASE_HEADER, BLOCK, PAR_HEADER, CASE_READY, CASE_ARM, MATCH_CLOSED_ARM, MATCH_DONE, BODY_DONE, MATCH_DONE_LAYOUT, GROUP, ARM_DONE, BLOCK_DONE, LAMBDA_DONE,
  FUNCTION_MATCH, FUNCTION_MATCH_DONE, FUNCTION_MATCH_LAYOUT,
  ARM_MATCH, ARM_MATCH_DONE, ARM_MATCH_LAYOUT,
  BLOCK_MATCH, BLOCK_MATCH_DONE, BLOCK_MATCH_LAYOUT,
  LAMBDA_MATCH, LAMBDA_MATCH_DONE, LAMBDA_MATCH_LAYOUT };
static bool parallel_frame(uint8_t kind) { return kind == PAR || kind == PAR_HEADER; }
static bool body_frame(uint8_t kind) { return kind == BODY || kind == CASE_ARM || kind == LAMBDA || kind == BLOCK || kind == GROUP; }
static bool owned_match(uint8_t kind) { return kind >= FUNCTION_MATCH && kind <= LAMBDA_MATCH_LAYOUT; }
static bool done_match(uint8_t kind) { return owned_match(kind) && (kind - FUNCTION_MATCH) % 3 != 0; }
static bool done_frame(uint8_t kind) {
  return done_match(kind) || kind == BODY_DONE || kind == ARM_DONE || kind == BLOCK_DONE || kind == LAMBDA_DONE;
}
static bool match_frame(uint8_t kind) { return kind == MATCH || kind == MATCH_CLOSED_ARM || owned_match(kind); }
static enum Token case_token(uint8_t kind) { return owned_match(kind) ? FUNCTION_CASE + (kind - FUNCTION_MATCH) / 3 * 3 : CASE; }
static enum Token match_end(uint8_t kind) { return owned_match(kind) ? FUNCTION_MATCH_END + (kind - FUNCTION_MATCH) / 3 * 3 : MATCH_END; }
typedef struct { uint32_t column, first; uint8_t kind; } Frame;
static bool case_enabled(const bool *v, const Frame *f) { return f && match_frame(f->kind) && v[case_token(f->kind)]; }
static bool match_end_enabled(const bool *v, const Frame *f) { return f && match_frame(f->kind) && v[match_end(f->kind)]; }
#define MAX_FRAMES 200
_Static_assert(MAX_FRAMES <= UINT8_MAX, "frame count must fit in one byte");
// Match frames use `first` in both normal and recovered-arm states. Other
// frames need five bytes, not nine. Reserve the exact size; never truncate.
typedef struct {
  uint8_t size;
  bool declaration_name, closed_string, decorator_name, header_checkpoint, case_header, array_checkpoint;
  uint32_t case_column; // Pending real case keyword, not a recovery-created frame.
  Frame frames[MAX_FRAMES];
} Scanner;

static bool space(int32_t c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static bool head(int32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool name(int32_t c) { return head(c) || (c >= '0' && c <= '9') || c == '.'; }
static void advance(TSLexer *l) { l->advance(l, false); }
static void skip_layout(TSLexer *l) {
  while (space(l->lookahead) || l->lookahead == '#') {
    if (l->lookahead == '#') {
      while (!l->eof(l) && l->lookahead != '\n') advance(l);
    } else advance(l);
  }
}
static bool reserved(const char *word) {
  const char *keywords[] = {"def", "type", "law", "match", "case", "do", "return", "for", "exs", "where", "is", "import", "Type", "Data", "Kind", "Quant"};
  for (unsigned i = 0; i < sizeof(keywords)/sizeof(*keywords); ++i)
    if (!strcmp(word, keywords[i])) return true;
  return false;
}
static bool read_name(TSLexer *l, char *word, unsigned capacity) {
  unsigned n = 0;
  bool valid = head(l->lookahead), after_dot = false;
  while (name(l->lookahead)) {
    if (after_dot && !head(l->lookahead)) valid = false;
    after_dot = l->lookahead == '.';
    if (n < capacity - 1) word[n++] = (char)l->lookahead;
    advance(l);
  }
  word[n] = 0;
  return valid && !after_dot;
}
// Bend speculatively reads `: T` and rewinds unless it is followed by `=`.
// At a lambda boundary the colon can instead belong to an enclosing annotation.
static bool typed_assignment(TSLexer *l) {
  unsigned depth = 0;
  advance(l); // colon
  while (!l->eof(l)) {
    int32_t c = l->lookahead;
    if (c == '"' || c == '\'') {
      advance(l);
      while (!l->eof(l) && l->lookahead != c) {
        if (l->lookahead == '\\') advance(l);
        if (!l->eof(l)) advance(l);
      }
      if (!l->eof(l)) advance(l);
      continue;
    }
    if (c == '#') {
      while (!l->eof(l) && l->lookahead != '\n') advance(l);
      continue;
    }
    if (c == '(' || c == '[' || c == '{') ++depth;
    if (c == ')' || c == ']' || c == '}') {
      if (!depth) return false;
      --depth;
    }
    if (!depth && c == ';') return false;
    advance(l);
    if (!depth && c == '=') {
      if (l->lookahead != '=' && l->lookahead != '>') return true;
      advance(l);
    }
  }
  return false;
}

static bool scan_number(TSLexer *l, const bool *v) {
  bool zero = true;
  do {
    zero &= l->lookahead == '0';
    advance(l);
  } while (l->lookahead >= '0' && l->lookahead <= '9');
  enum Token t = INTEGER;
  if (l->lookahead == 'n') {
    advance(l);
    // Literal and glued-successor heads share the public natural node. Their
    // tokens distinguish eligibility without a trailing zero-width boundary.
    t = l->lookahead == '+' ? (zero && v[ZERO_NATURAL] ? ZERO_NATURAL : SUCCESSOR_NATURAL) : NATURAL;
  } else if (l->lookahead == '.') {
    advance(l);
    if (l->lookahead < '0' || l->lookahead > '9') return false;
    t = FLOAT;
    do { advance(l); } while (l->lookahead >= '0' && l->lookahead <= '9');
    l->mark_end(l);
    if (l->lookahead == 'e' || l->lookahead == 'E') {
      advance(l);
      if (l->lookahead == '+' || l->lookahead == '-') advance(l);
      if (l->lookahead < '0' || l->lookahead > '9') {
        if (!v[FLOAT]) return false;
        l->result_symbol = FLOAT; return true;
      }
      do { advance(l); } while (l->lookahead >= '0' && l->lookahead <= '9');
    }
  }
  if (!v[t] || (t != FLOAT && name(l->lookahead))) return false;
  l->mark_end(l); l->result_symbol = t; return true;
}
// A delimiter checkpoint condenses a finished operand before native recovery.
// Non-delimiter continuations stay with the ordinary grammar reductions.
static bool successor_end(Scanner *s, TSLexer *l, bool newline) {
  int32_t c = l->lookahead;
  if (c == ';' && newline && s->size && s->frames[s->size-1].kind == CASE_ARM
      && l->get_column(l) < s->frames[s->size-1].column) return false;
  if (c == '=') {
    advance(l);
    if (l->lookahead == '=' || l->lookahead == '>') return false;
  } else if (!l->eof(l) && !(c && strchr(")],;:}", c))) return false;
  l->result_symbol = NATURAL_SUCCESSOR_END; return true;
}
static bool push(Scanner *s, uint8_t kind, uint32_t column) {
  if (s->size == MAX_FRAMES || s->case_header
      || (s->size && done_frame(s->frames[s->size-1].kind))) return false;
  unsigned bytes = 3 + 5 * (s->size + 1) + (match_frame(kind) ? 4 : 0);
  for (unsigned i = 0; i < s->size; ++i) bytes += match_frame(s->frames[i].kind) ? 4 : 0;
  if (bytes > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) return false;
  s->frames[s->size++] = (Frame){column, UINT32_MAX, kind};
  return true;
}
static void pop(Scanner *s) {
  --s->size;
  s->case_header = false; s->case_column = 0;
}
static bool case_keyword(Scanner *s, TSLexer *l, uint32_t column) {
  Frame *owner = s->size ? &s->frames[s->size-1] : NULL;
  if (column == UINT32_MAX || !owner || !match_frame(owner->kind)
      || column < owner->column || (owner->first != UINT32_MAX && column < owner->first)) return false;
  unsigned bytes = 7 + 5 * s->size;
  for (unsigned i = 0; i < s->size; ++i) bytes += match_frame(s->frames[i].kind) ? 4 : 0;
  if (bytes > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) return false;
  if (owner->first == UINT32_MAX) owner->first = column;
  s->declaration_name = s->decorator_name = s->header_checkpoint = false;
  s->case_header = true; s->case_column = column;
  l->mark_end(l); l->result_symbol = case_token(owner->kind); return true;
}
static bool string_start(Scanner *s, TSLexer *l) {
  // Preserve multiline strings; newline recovery requires no later real quote.
  advance(l); l->mark_end(l);
  while (!l->eof(l) && l->lookahead != '"') {
    if (l->lookahead == '\\') {
      advance(l);
      if (l->eof(l)) break;
    }
    advance(l);
  }
  s->closed_string = l->lookahead == '"';
  l->result_symbol = STRING_START; return true;
}
// Successful grammar entry serializes phase before an early lexical return.
// Only a discarded header is retired; entry allocates no new frame.
static bool body_entry(Scanner *s, TSLexer *l, enum Token token) {
  if (s->size && done_frame(s->frames[s->size-1].kind)) return false;
  if (s->size && s->frames[s->size-1].kind == PAR_HEADER) pop(s);
  l->result_symbol = token; return true;
}
static uint32_t body_column(const Scanner *s) {
  for (unsigned i = s->size; i; --i)
    if (body_frame(s->frames[i-1].kind)) return s->frames[i-1].column;
  return 0;
}
static bool only_body_end(const bool *v) {
  if (!v[BODY_END]) return false;
  for (unsigned i = 0; i <= ARRAY_LAYOUT; ++i)
    if (i != BODY_END && i != ROOT_LAYOUT && i != ARRAY_LAYOUT && v[i]) return false;
  return true;
}
static uint8_t complete_body(uint8_t kind) {
  return kind == BODY ? BODY_DONE : kind == CASE_ARM ? ARM_DONE : kind == BLOCK ? BLOCK_DONE : LAMBDA_DONE;
}
static uint8_t active_body(uint8_t kind) {
  return kind == BODY_DONE ? BODY : kind == ARM_DONE ? CASE_ARM : kind == BLOCK_DONE ? BLOCK : LAMBDA;
}
static inline enum Token frame_end_token(uint8_t kind) {
  if (owned_match(kind)) return match_end(kind);
  switch (kind) {
    case MATCH: case MATCH_CLOSED_ARM: return MATCH_END;
    case DO:    return DO_END;
    case PAR: case PAR_HEADER: return PARALLEL_END;
    case WRITE: return WRITE_END;
    case CASE_ARM: case CASE_HEADER: case CASE_READY: case ARM_DONE: return ARM_END;
    case BLOCK: case BLOCK_DONE: return BLOCK_END;
    case GROUP: return GROUP_END;
    case LAMBDA: case LAMBDA_DONE: return LAMBDA_END;
    default:    return BODY_END;
  }
}
void *tree_sitter_bend2_external_scanner_create(void) { return calloc(1, sizeof(Scanner)); }
void tree_sitter_bend2_external_scanner_destroy(void *p) { free(p); }
unsigned tree_sitter_bend2_external_scanner_serialize(void *p, char *b) {
  Scanner *s = p;
  unsigned n = 0;
  b[n++] = (char)s->size;
  b[n++] = (char)(s->declaration_name | (s->decorator_name << 1) | (s->header_checkpoint << 2) | (s->case_header << 3) | (s->array_checkpoint << 4));
  b[n++] = (char)s->closed_string;
  for (unsigned i = 0; i < s->size; ++i) {
    Frame f = s->frames[i];
    b[n++] = (char)f.kind;
    for (unsigned j = 0; j < 4; ++j) b[n++] = (char)(f.column >> (8*j));
    if (match_frame(f.kind))
      for (unsigned j = 0; j < 4; ++j) b[n++] = (char)(f.first >> (8*j));
  }
  if (s->case_header)
    for (unsigned j = 0; j < 4; ++j) b[n++] = (char)(s->case_column >> (8*j));
  return n;
}
void tree_sitter_bend2_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  Scanner *s = p;
  s->size = 0;
  s->declaration_name = s->closed_string = s->decorator_name = s->header_checkpoint = s->case_header = s->array_checkpoint = false;
  s->case_column = 0;
  if (n < 3 || n > TREE_SITTER_SERIALIZATION_BUFFER_SIZE || (uint8_t)b[0] > MAX_FRAMES
      || (uint8_t)b[1] > 31 || (uint8_t)b[2] > 1) return;
  unsigned at = 3;
  for (unsigned i = 0; i < (uint8_t)b[0]; ++i) {
    if (n - at < 5) return;
    Frame *f = &s->frames[i];
    f->kind = (uint8_t)b[at++]; f->column = 0; f->first = UINT32_MAX;
    if (f->kind > LAMBDA_MATCH_LAYOUT) return;
    for (unsigned j = 0; j < 4; ++j) f->column |= (uint32_t)(uint8_t)b[at++] << (8*j);
    if (match_frame(f->kind)) {
      if (n - at < 4) return;
      f->first = 0;
      for (unsigned j = 0; j < 4; ++j) f->first |= (uint32_t)(uint8_t)b[at++] << (8*j);
    }
  }
  for (unsigned i = 0; i < (uint8_t)b[0]; ++i) {
    Frame *f = &s->frames[i];
    if (f->kind == BODY_DONE && (i != 0 || f->column != 0)) return;
    if (owned_match(f->kind)) {
      uint8_t owner = (uint8_t[]){BODY, CASE_ARM, BLOCK, LAMBDA}[(f->kind-FUNCTION_MATCH)/3];
      if (!i) return;
      Frame *parent = &s->frames[i-1];
      uint8_t parent_kind = body_frame(parent->kind) ? parent->kind : active_body(parent->kind);
      if (parent_kind != owner || f->column != parent->column) return;
    }
    if (done_frame(f->kind) && ((b[1] & 6)
        || (i+1 < (uint8_t)b[0] && !done_frame(s->frames[i+1].kind)))) return;
    if (!done_frame(f->kind)) continue;
    bool match_done = done_match(f->kind);
    if (match_done) {
      if (!i || !(body_frame(s->frames[i-1].kind) || done_frame(s->frames[i-1].kind))) return;
    } else if (i + 1 >= (uint8_t)b[0] || !done_match(s->frames[i+1].kind)) return;
  }
  // An entered arm is the phase of its actual case header, never a stand-alone scope.
  for (unsigned i = 0; i < (uint8_t)b[0]; ++i) {
    Frame *f = &s->frames[i];
    if (f->kind != CASE_ARM) continue;
    if (!i || !match_frame(s->frames[i-1].kind) || !f->column) return;
    Frame *owner = &s->frames[i-1];
    if (owner->first == UINT32_MAX || f->column - 1 < owner->column || f->column - 1 < owner->first) return;
  }
  uint32_t case_column = 0;
  if (b[1] & 8) {
    if (n - at != 4 || !b[0] || !match_frame(s->frames[(uint8_t)b[0]-1].kind)
        || (b[1] & 7)) return;
    for (unsigned j = 0; j < 4; ++j) case_column |= (uint32_t)(uint8_t)b[at++] << (8*j);
  }
  if (b[1] & 8) {
    Frame *owner = &s->frames[(uint8_t)b[0]-1];
    if (owner->first == UINT32_MAX || case_column < owner->column || case_column < owner->first) return;
  }
  if (case_column == UINT32_MAX || at != n || ((b[1] & 4) && (b[0] || (b[1] & 2)))) return;
  s->size = (uint8_t)b[0];
  s->declaration_name = (b[1] & 1) != 0;
  s->decorator_name = (b[1] & 2) != 0;
  s->header_checkpoint = (b[1] & 4) != 0;
  s->case_header = (b[1] & 8) != 0;
  s->case_column = case_column;
  s->array_checkpoint = (b[1] & 16) != 0;
  s->closed_string = b[2] != 0;
}
bool tree_sitter_bend2_external_scanner_scan(void *p, TSLexer *l, const bool *v) {
  Scanner *s = p;
  if (!v[ERROR_SENTINEL] && v[ARRAY_LAYOUT] && s->array_checkpoint && space(l->lookahead)) {
    do { advance(l); } while (space(l->lookahead));
    s->array_checkpoint = false;
    l->mark_end(l); l->result_symbol = ARRAY_LAYOUT; return true;
  }
  s->array_checkpoint = false;
  bool completed_root = s->size >= 2 && s->frames[0].kind == BODY_DONE
    && !s->case_header && !s->header_checkpoint && !s->decorator_name;
  for (unsigned i = 0; i < s->size; ++i) completed_root &= done_frame(s->frames[i].kind);
  if (!v[ERROR_SENTINEL] && v[ROOT_LAYOUT] && completed_root && space(l->lookahead)) {
    do {
      if (l->lookahead == '\n')
        for (unsigned i = 0; i < s->size; ++i)
          if (done_match(s->frames[i].kind) && (s->frames[i].kind - FUNCTION_MATCH) % 3 == 1) ++s->frames[i].kind;
      advance(l);
    } while (space(l->lookahead));
    l->mark_end(l); l->result_symbol = ROOT_LAYOUT; return true;
  }
  l->mark_end(l); // Zero-width layout tokens must not include following whitespace.
  if (!v[ERROR_SENTINEL] && v[STRING_NEWLINE] && l->lookahead == '\n') {
    if (!s->closed_string) return false;
    advance(l); l->mark_end(l); l->result_symbol = STRING_NEWLINE; return true;
  }
  bool newline = l->get_column(l) == 0 || (s->size && owned_match(s->frames[s->size-1].kind) && (s->frames[s->size-1].kind - FUNCTION_MATCH) % 3 == 2), spaced = false;
  while (space(l->lookahead)) {
    newline |= l->lookahead == '\n'; spaced = true; l->advance(l, true);
  }
  if (!v[ERROR_SENTINEL] && v[NATURAL_SUCCESSOR_END] && l->lookahead == '#') {
    while (space(l->lookahead) || l->lookahead == '#') {
      if (l->lookahead == '#') {
        while (!l->eof(l) && l->lookahead != '\n') advance(l);
      } else {
        newline |= l->lookahead == '\n'; advance(l);
      }
    }
    return successor_end(s, l, newline);
  }
  if (l->lookahead == '#') return false; // Let the grammar retain comment nodes.
  uint32_t col = l->get_column(l);
  if (!v[ERROR_SENTINEL] && v[PATTERN_SEPARATOR] && l->lookahead == '"') {
    l->result_symbol = PATTERN_SEPARATOR; return true;
  }
  if (v[ERROR_SENTINEL] && v[STRING_START] && l->lookahead == '"'
      && !(newline && col < body_column(s))) return string_start(s, l);
  Frame *top = s->size ? &s->frames[s->size-1] : NULL;
  if (!v[ERROR_SENTINEL] && v[HEADER_CHECKPOINT] && s->header_checkpoint) {
    s->header_checkpoint = false;
    l->result_symbol = HEADER_CHECKPOINT; return true;
  }
  // All-valid recovery may recognize a real case word, but only this normal
  // grammar state allocates its header under the recorded owning match.
  if (!v[ERROR_SENTINEL] && v[CASE_HEADER_START] && s->case_header && top && match_frame(top->kind)) {
    if (done_match(top->kind)) {
      for (unsigned i = 0; i < s->size; ++i) {
        Frame *f = &s->frames[i];
        if (done_match(f->kind)) f->kind -= (f->kind - FUNCTION_MATCH) % 3;
        else if (done_frame(f->kind)) f->kind = active_body(f->kind);
      }
    }
    uint32_t column = s->case_column;
    s->case_header = false; s->case_column = 0;
    if (column == UINT32_MAX || !push(s, CASE_HEADER, column + 1)) return false;
    l->result_symbol = CASE_HEADER_START; return true;
  }
  if (!v[ERROR_SENTINEL] && !s->case_header && top && done_match(top->kind)) {
    for (unsigned i = s->size; i > 0; --i) {
      Frame *f = &s->frames[i-1];
      if (done_frame(f->kind)) continue;
      if (body_frame(f->kind) && i < s->size && done_match(s->frames[i].kind)
          && v[frame_end_token(f->kind)]) {
        enum Token end = frame_end_token(f->kind);
        f->kind = complete_body(f->kind);
        l->result_symbol = end; return true;
      }
      break;
    }
    // A token valid only in the enclosing ordinary expression/body state is
    // not another end of the completed terminal match.
    for (unsigned i = s->size; i > 0; --i) {
      Frame *f = &s->frames[i-1];
      if (done_frame(f->kind)) continue;
      if (body_frame(f->kind) && (i == s->size || !match_frame(s->frames[i].kind))
          && v[frame_end_token(f->kind)] && !case_enabled(v, top)) {
        s->size = i; top = f;
      }
      break;
    }
  }
  // The grammar has already completed a terminal body (not an extensible
  // expression). Close its actual function before lexing a root error.
  if (!v[ERROR_SENTINEL] && top && top->kind == BODY && only_body_end(v)) {
    pop(s); l->result_symbol = frame_end_token(top->kind); return true;
  }
  if (v[DECORATOR_START] && l->lookahead == '@') {
    bool close = v[ERROR_SENTINEL] && newline && top
      && !parallel_frame(top->kind) && !done_frame(top->kind) && v[frame_end_token(top->kind)];
    advance(l);
    if (!close) l->mark_end(l);
    skip_layout(l);
    char word[32];
    if (!read_name(l, word, sizeof(word)) || strcmp(word, "unsafe")) return false;
    skip_layout(l);
    if (!read_name(l, word, sizeof(word))
        || (strcmp(word, "def") && strcmp(word, "type") && strcmp(word, "law"))) return false;
    if (close) {
      enum Token end = frame_end_token(top->kind);
      pop(s); l->result_symbol = end; return true;
    }
    if (strcmp(word, "def")) return false; // Only def may have this decorator.
    s->size = 0;
    s->case_header = false; s->case_column = 0;
    s->header_checkpoint = s->declaration_name = false;
    s->decorator_name = true;
    l->result_symbol = DECORATOR_START; return true;
  }
  // An internal alias regex must not steal a fresh declaration keyword.
  if (!v[ERROR_SENTINEL] && v[MODULE_ALIAS] && head(l->lookahead)) {
    do { advance(l); } while (head(l->lookahead) || (l->lookahead >= '0' && l->lookahead <= '9'));
    l->mark_end(l); l->result_symbol = MODULE_ALIAS; return true;
  }
  // Recovery must not reinterpret a following declaration's name as a value
  // in the damaged body. Give headers distinct tokens but the same public CST.
  if (head(l->lookahead) && (v[DEF_KEYWORD] || v[TYPE_KEYWORD] || v[LAW_KEYWORD] || v[DECLARATION_NAME] || v[UNSAFE_KEYWORD]
      || (top && done_match(top->kind))
      || (top && parallel_frame(top->kind) && s->size >= 2 && v[frame_end_token(s->frames[s->size-2].kind)] && !v[PARALLEL_VALUE] && !v[PARALLEL_END])
      || (top && (top->kind == CASE_HEADER || top->kind == CASE_READY) && (v[CASE] || v[MATCH_END] || v[FUNCTION_CASE] || v[ARM_CASE] || v[BLOCK_CASE] || v[LAMBDA_CASE] || v[FUNCTION_MATCH_END] || v[ARM_MATCH_END] || v[BLOCK_MATCH_END] || v[LAMBDA_MATCH_END])))) {
    char word[32];
    bool valid_name = read_name(l, word, sizeof(word));
    if (v[UNSAFE_KEYWORD] && s->decorator_name && !strcmp(word, "unsafe")) {
      s->decorator_name = false;
      l->mark_end(l); l->result_symbol = UNSAFE_KEYWORD; return true;
    }
    if (newline && !strcmp(word, "case")) {
      for (unsigned i = s->size; i > 0; --i) {
        Frame *owner = &s->frames[i-1];
        if (!match_frame(owner->kind) || !case_enabled(v, owner) || col < owner->column
            || (owner->first != UINT32_MAX && col < owner->first)) continue;
        bool completed_children = true;
        for (unsigned j = i; j < s->size; ++j) completed_children &= done_frame(s->frames[j].kind);
        if (completed_children) {
          s->size = i; top = owner;
          return case_keyword(s, l, col);
        }
        break;
      }
    }
    if (newline && !strcmp(word, "case") && top
        && (v[ERROR_SENTINEL] || (parallel_frame(top->kind) && s->size >= 2 && v[frame_end_token(s->frames[s->size-2].kind)] && !v[PARALLEL_VALUE] && !v[PARALLEL_END])
            || ((top->kind == CASE_HEADER || top->kind == CASE_READY) && (v[CASE] || v[MATCH_END] || v[FUNCTION_CASE] || v[ARM_CASE] || v[BLOCK_CASE] || v[LAMBDA_CASE] || v[FUNCTION_MATCH_END] || v[ARM_MATCH_END] || v[BLOCK_MATCH_END] || v[LAMBDA_MATCH_END])))) {
      // A real sibling allowed by the same case-column rule as normal parsing
      // is a boundary for the damaged arm, not for
      // its owning match. Close only existing scopes above that match.
      for (unsigned i = s->size; i > 0; --i) {
        Frame *owner = &s->frames[i - 1];
        if (!match_frame(owner->kind) || col < owner->column
            || (owner->first != UINT32_MAX && col < owner->first)) continue;
        if ((top->kind == CASE_HEADER || top->kind == CASE_READY) && s->size >= 2 && &s->frames[s->size - 2] != owner) {
          // A damaged inner header has no body to finish. Close its real
          // inner match before handing the dedented arm back to the outer one.
          if (!v[match_end(s->frames[s->size-2].kind)]) return false;
          // The error probe is relexed from its original scanner state. The
          // resumed normal scan must close both header and actual inner match.
          enum Token end = match_end(s->frames[s->size-2].kind);
          s->size -= v[ERROR_SENTINEL] ? 1 : 2;
          l->result_symbol = end; return true;
        }
        if (((top->kind == CASE_HEADER || top->kind == CASE_READY) || top == owner) && v[case_token(owner->kind)]) {
          l->mark_end(l);
          owner->first = owner->first == UINT32_MAX ? col : owner->first;
          // No body exists to close: abandon the damaged header and restart
          // its sibling under the same owning match, leaving a native error.
          s->size = i;
          return case_keyword(s, l, col);
        }
        if (top != owner && parallel_frame(top->kind) && s->size >= i + 2) {
          Frame *body = &s->frames[s->size-2];
          enum Token end = frame_end_token(body->kind);
          if (!parallel_frame(body->kind) && v[end]) {
            pop(s); pop(s); l->result_symbol = end; return true;
          }
        }
        if (top != owner && !done_frame(top->kind)) {
          enum Token end = frame_end_token(top->kind);
          if (v[end]) {
            pop(s); l->result_symbol = end; return true;
          }
        }
        break;
      }
    }
    enum Token t = !strcmp(word, "def") ? DEF_KEYWORD : !strcmp(word, "type") ? TYPE_KEYWORD :
      !strcmp(word, "law") ? LAW_KEYWORD : ERROR_SENTINEL;
    if (t != ERROR_SENTINEL && newline && col == 0 && !s->case_header && top && done_match(top->kind)) {
      for (unsigned i = s->size; i > 0; --i) {
        Frame *f = &s->frames[i-1];
        if (done_frame(f->kind)) continue;
        if (v[frame_end_token(f->kind)]) {
          enum Token end = frame_end_token(f->kind);
          if (owned_match(f->kind)) ++f->kind;
          else s->size = i-1;
          l->result_symbol = end; return true;
        }
        break;
      }
    }
    if (t != ERROR_SENTINEL && v[ERROR_SENTINEL] && !newline && !s->declaration_name) return false;
    if (t != ERROR_SENTINEL && newline && col == 0 && top && parallel_frame(top->kind)
        && (!v[t] || v[ERROR_SENTINEL]) && s->size >= 2) {
      Frame *owner = &s->frames[s->size - 2];
      enum Token end = frame_end_token(owner->kind);
      if (!parallel_frame(owner->kind) && v[end]) {
        // A real outer header abandons an interrupted binding; it does not
        // finish imaginary values or decrement the live parallel arity.
        pop(s); pop(s); l->result_symbol = end; return true;
      }
    }
    if (t != ERROR_SENTINEL && newline && col == 0 && top && !parallel_frame(top->kind) && !done_frame(top->kind) && (!v[t] || v[ERROR_SENTINEL])) {
      if ((top->kind == MATCH || (owned_match(top->kind) && !done_match(top->kind))) && top->first != UINT32_MAX && v[ARM_END] && !match_end_enabled(v, top)) {
        // Pattern recovery can consume the arm's frame while the parser still
        // needs its end. A recorded case makes this a real arm boundary;
        // emit it once per owning match by persisting the state transition,
        // keeping the real match and outer body available for their own ends.
        s->declaration_name = true;
        top->kind = MATCH_CLOSED_ARM; l->result_symbol = ARM_END; return true;
      }
      // A damaged pattern may still be waiting for a body or a closer, with
      // no declaration token enabled. Close existing scopes before the
      // internal recovery lexer can consume this header as another word.
      enum Token end = frame_end_token(top->kind);
      if (v[end]) {
        // Closing an old scope does not consume a fresh declaration keyword.
        if (owned_match(top->kind)) ++top->kind; else pop(s);
        l->result_symbol = end; return true;
      }
    }
    // A viable fresh header takes precedence over stale normal-mode frames.
    // Otherwise an unfinished delimiter can cost the next declaration its CST.
    if (t != ERROR_SENTINEL && v[t]) {
      s->size = 0;
      s->case_header = false; s->case_column = 0;
      s->decorator_name = false;
      l->mark_end(l);
      // A missing name must not turn a later parameter into the declaration
      // name during recovery. Normal parsing still permits multiline headers.
      skip_layout(l);
      s->declaration_name = l->lookahead != '(';
      s->header_checkpoint = true;
      l->result_symbol = t; return true;
    }
    // A keyword skipped by native recovery must not lend its name to an
    // older declaration-name or expression state. Only the grammar checkpoint
    // following that actual keyword can release this pending lexical role.
    if (s->header_checkpoint || s->case_header) return false;
    if (v[DECLARATION_NAME] && (!v[ERROR_SENTINEL] || s->declaration_name) && valid_name && !reserved(word)) {
      s->size = 0;
      s->case_header = false; s->case_column = 0;
      s->declaration_name = false;
      l->mark_end(l); l->result_symbol = DECLARATION_NAME; return true;
    }
    if (v[IDENTIFIER] && valid_name && !reserved(word)) {
      l->mark_end(l); l->result_symbol = IDENTIFIER; return true;
    }
    if (!v[ERROR_SENTINEL] && v[IMPORT_START] && newline && !strcmp(word, "import") && space(l->lookahead)) {
      l->result_symbol = IMPORT_START; return true;
    }
    return false;
  }
  // Keep genuine GPU prefixes visible to recovery too; unlike a bare '!'
  // this token cannot invent an opener while recovering a damaged do/header.
  if (v[GPU_MODIFIER] && l->lookahead == '!') {
    advance(l);
    if (l->lookahead != '(') {
      if (!v[ERROR_SENTINEL] && top && v[frame_end_token(top->kind)] && (top->kind == BLOCK || top->kind == GROUP) && l->lookahead == ')') {
        pop(s); l->result_symbol = frame_end_token(top->kind); return true;
      }
      return false;
    }
    l->mark_end(l); l->result_symbol = GPU_MODIFIER; return true;
  }
  if (v[ERROR_SENTINEL]) {
    // Native recovery still closes an entered group at its actual delimiter;
    // its distinct end cannot satisfy an enclosing arm or lambda.
    if (top && top->kind == GROUP && l->lookahead == ')' && v[GROUP_END]) {
      pop(s); l->result_symbol = GROUP_END; return true;
    }
    // A real numeric lexeme may resume recovery within the current layout,
    // but must not extend a damaged inner expression across its dedent.
    if (l->lookahead >= '0' && l->lookahead <= '9'
        && !(newline && col < body_column(s))
        && !(top && top->kind == CASE_HEADER)) return scan_number(l, v);
    // Only actual, bounded scope closures are safe to synthesize at EOF. Never
    // push speculative frames while Tree-sitter is trying all recovery tokens.
    if (!top || !l->eof(l) || done_frame(top->kind)) return false;
    enum Token t = frame_end_token(top->kind);
    pop(s); l->result_symbol = t; return true;
  }
  if (s->header_checkpoint || s->case_header) return false;
  // An entered mandatory block reaches its initial body checkpoint even when
  // the value is absent. Native recovery can then report the missing term
  // without discarding the intact header before this block.
  if (v[BODY_ENTRY] && top && top->kind == BLOCK) return body_entry(s, l, BODY_ENTRY);
  if (v[IMPORT_END]) {
    if (!newline && !l->eof(l)) return false;
    l->result_symbol = IMPORT_END; return true;
  }
  if (v[IMPORT_START]) {
    if (!newline || l->lookahead != 'i') return false;
    l->mark_end(l);
    const char *word = "import";
    for (unsigned i = 0; word[i]; ++i) {
      if (l->lookahead != word[i]) return false;
      advance(l);
    }
    if (!space(l->lookahead)) return false;
    l->result_symbol = IMPORT_START; return true;
  }
  if (v[AT] && l->lookahead == '@') {
    advance(l); l->mark_end(l);
    if (newline && col == 0) {
      // A fresh decorated definition is not a dependent-type continuation.
      skip_layout(l);
      char word[32];
      read_name(l, word, sizeof(word));
      if (!strcmp(word, "unsafe")) {
        skip_layout(l);
        read_name(l, word, sizeof(word));
        if (!strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law")) return false;
      }
    }
    l->result_symbol = AT; return true;
  }
  // Infix '&' is a different role from a prefix quantity '&0'/'&1'/'&2'.
  if (v[AMP] && !v[GLUED_COMPARISON_END] && l->lookahead == '&') {
    advance(l);
    if (l->lookahead == '&') return false;
    l->mark_end(l); l->result_symbol = AMP; return true;
  }
  // A glued natural successor consumes exactly one '+', even before another
  // '+' or a numeric tail. Do not let arithmetic '+' / '++' steal this prefix.
  if (v[NATURAL_PLUS] && !spaced && l->lookahead == '+') {
    advance(l); l->mark_end(l); l->result_symbol = NATURAL_PLUS; return true;
  }
  // Keep the immediate GPU opener out of the regular '(' lexer rules:
  // sharing them changes recovery of malformed declaration headers.
  if (v[GPU_OPEN] && !spaced && l->lookahead == '(') {
    advance(l); l->mark_end(l); l->result_symbol = GPU_OPEN; return true;
  }
  if (!newline && ((v[CALL_OPEN] && l->lookahead == '(') || (v[INDEX_OPEN] && l->lookahead == '['))) {
    l->result_symbol = l->lookahead == '(' ? CALL_OPEN : INDEX_OPEN;
    advance(l); l->mark_end(l); return true;
  }
  if (l->lookahead == '<' && (v[LT] || v[GLUED_LT])) {
    advance(l);
    if (v[GLUED_COMPARISON_END] && (l->lookahead == '=' ||
        (spaced && !(l->lookahead && strchr("<->&", l->lookahead))))) {
      l->result_symbol = GLUED_COMPARISON_END; return true;
    }
    if (l->lookahead && strchr("<=->", l->lookahead)) return false;
    l->mark_end(l);
    if (l->lookahead == '&') {
      advance(l);
      if (l->lookahead == '>') return false;
    }
    enum Token t = spaced ? LT : GLUED_LT;
    if (!v[t]) return false;
    l->result_symbol = t; return true;
  }
  // A completed pattern before a mistaken ')' is not an unfinished pattern.
  // Its own native missing-colon error must not suppress the following number.
  if (v[CASE_PATTERN_END] && top && top->kind == CASE_HEADER && l->lookahead == ')') {
    top->kind = CASE_READY; l->result_symbol = CASE_PATTERN_END; return true;
  }
  if (v[CASE_BODY_START] && top && (top->kind == CASE_HEADER || top->kind == CASE_READY)) {
    top->kind = CASE_ARM;
    l->result_symbol = CASE_BODY_START; return true;
  }
  if (v[FUNCTION_START] || v[BLOCK_START] || v[GROUP_START] || v[LAMBDA_START] || v[DO_START]) {
    // A genuine declaration name clears prior frames. A live case/layout
    // stack here means recovery rewound to an old header's colon instead.
    if (v[FUNCTION_START] && s->size) return false;
    // Keep an immediate constructor continuation, as at the body checkpoint.
    if (v[CALL_OPEN] && l->lookahead
        && (strchr("&|*/.<!=", l->lookahead) || (!spaced && l->lookahead == '{'))) return false;
    if ((v[PLUS] && l->lookahead == '+') || (v[MINUS] && l->lookahead == '-')) {
      enum Token op = l->lookahead == '+' ? PLUS : MINUS;
      advance(l);
      if (!head(l->lookahead)) {
        if (l->lookahead == '>' || (op == PLUS && l->lookahead == '+')) return false;
        l->mark_end(l); l->result_symbol = op; return true;
      }
    }
    if (spaced && l->lookahead == '>' && (v[GT] || v[GE] || v[SHR])) {
      advance(l);
      enum Token op = GT;
      if (l->lookahead == '=') { op = GE; advance(l); }
      else if (l->lookahead == '>') { op = SHR; advance(l); }
      if (!v[op]) return false;
      l->mark_end(l); l->result_symbol = op; return true;
    }
    // A spaced-right '%' is an enabled infix, not the next rewrite body.
    if (v[MOD] && l->lookahead == '%') {
      advance(l);
      if (space(l->lookahead)) {
        l->mark_end(l); l->result_symbol = MOD; return true;
      }
    }
    if (head(l->lookahead)) {
      char word[32]; unsigned n = 0;
      while (name(l->lookahead)) {
        if (n < sizeof(word)-1) word[n++] = (char)l->lookahead;
        advance(l);
      }
      word[n] = 0;
      if (!strcmp(word, "for") || !strcmp(word, "exs") || !strcmp(word, "import") || !strcmp(word, "where")) return false;
    } else if (l->lookahead == '-') {
      advance(l);
      if (l->lookahead == '>') return false;
    } else if (l->lookahead == ';') {
      // Optional separators precede checkpoints; invalid first bytes do not.
      return false;
    }
    enum Token t = v[FUNCTION_START] ? FUNCTION_START : v[BLOCK_START] ? BLOCK_START : v[GROUP_START] ? GROUP_START : v[LAMBDA_START] ? LAMBDA_START : DO_START;
    if (!push(s, t == DO_START ? DO : t == LAMBDA_START ? LAMBDA : t == BLOCK_START ? BLOCK : t == GROUP_START ? GROUP : BODY,
        t == FUNCTION_START ? 0 : col)) return false;
    l->result_symbol = t; return true;
  }
  // A statement write starts with a real identifier token, not a zero-width
  // probe. Keep its end marked while inspecting the index; on failure the same
  // lexeme can be returned as an ordinary identifier without consuming suffixes.
  if (v[WRITE_START] && head(l->lookahead)) {
    char word[32];
    bool valid_name = read_name(l, word, sizeof(word)) && !reserved(word);
    if (!valid_name) return false;
    l->mark_end(l);
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r') advance(l);
    if (l->lookahead != '[') {
      if (!v[IDENTIFIER]) return false;
      l->result_symbol = IDENTIFIER; return true;
    }
    unsigned depth = 1; advance(l);
    while (depth && !l->eof(l)) {
      if (l->lookahead == '\'' || l->lookahead == '"') {
        int32_t quote = l->lookahead; advance(l);
        while (!l->eof(l) && l->lookahead != quote) {
          if (l->lookahead == '\\') advance(l);
          if (!l->eof(l)) advance(l);
        }
        if (!l->eof(l)) advance(l);
      } else if (l->lookahead == '#') {
        while (!l->eof(l) && l->lookahead != '\n') advance(l);
      } else {
        if (l->lookahead == '[') ++depth;
        if (l->lookahead == ']') --depth;
        advance(l);
      }
    }
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r') advance(l);
    bool write = l->lookahead == '<';
    if (write) { advance(l); write = l->lookahead == '-'; }
    if (!write) {
      if (!v[IDENTIFIER]) return false;
      l->result_symbol = IDENTIFIER; return true;
    }
    if (!push(s, WRITE, col)) return false;
    l->result_symbol = WRITE_START; return true;
  }
  if (!s->case_header && top && done_match(top->kind)) {
    for (unsigned i = s->size; i > 0; --i) {
      Frame *f = &s->frames[i-1];
      if (done_frame(f->kind)) continue;
      if (owned_match(f->kind) && v[match_end(f->kind)]) {
        enum Token end = match_end(f->kind);
        ++f->kind;
        l->result_symbol = end; return true;
      }
      if (body_frame(f->kind) && l->eof(l) && v[frame_end_token(f->kind)]) {
        enum Token end = frame_end_token(f->kind);
        s->size = i-1;
        l->result_symbol = end; return true;
      }
      break;
    }
  }
  enum Token caller_start = top && top->kind == BODY ? FUNCTION_MATCH_START
    : top && top->kind == CASE_ARM ? ARM_MATCH_START
    : top && top->kind == BLOCK ? BLOCK_MATCH_START
    : top && top->kind == LAMBDA ? LAMBDA_MATCH_START : MATCH_START;
  if (caller_start != MATCH_START && v[caller_start]) {
    if (!push(s, FUNCTION_MATCH + caller_start - FUNCTION_MATCH_START, body_column(s))) return false;
    l->result_symbol = caller_start; return true;
  }
  if (v[MATCH_START]) {
    if (!push(s, MATCH, body_column(s))) return false;
    l->result_symbol = MATCH_START; return true;
  }
  if (top && match_frame(top->kind) && (case_enabled(v, top) || match_end_enabled(v, top))) {
    if (case_enabled(v, top) && col >= top->column && (top->first == UINT32_MAX || col >= top->first) && l->lookahead == 'c') l->mark_end(l);
    bool is_case = true;
    const char *word = "case";
    for (unsigned i = 0; i < 4; ++i) {
      if (l->lookahead != word[i]) { is_case = false; break; }
      advance(l);
    }
    is_case &= !name(l->lookahead);
    bool eligible = is_case && col >= top->column && (top->first == UINT32_MAX || col >= top->first);
    if (eligible && case_enabled(v, top)) return case_keyword(s, l, col);
    if (!eligible && match_end_enabled(v, top) && !done_match(top->kind)) {
      enum Token end = match_end(top->kind);
      if (owned_match(top->kind)) ++top->kind;
      else pop(s);
      l->result_symbol = end; return true;
    }
    return false;
  }
  if (v[WRITE_MORE] && top && top->kind == WRITE && col == top->column && !l->eof(l)) {
    l->result_symbol = WRITE_MORE; return true;
  }
  if (v[DO_MORE] && top && top->kind == DO && col == top->column && !l->eof(l)) {
    l->result_symbol = DO_MORE; return true;
  }
  if ((v[PARALLEL] || v[PARALLEL_START]) && !newline && (head(l->lookahead) || (spaced && l->lookahead == '+'))) {
    if (l->lookahead == '+') {
      advance(l);
      if (!head(l->lookahead)) {
        if (v[PLUS] && l->lookahead != '+' && l->lookahead != '>') {
          l->mark_end(l); l->result_symbol = PLUS; return true;
        }
        return false;
      }
    }
    char word[32]; unsigned n = 0;
    while (name(l->lookahead)) {
      if (n < sizeof(word)-1) word[n++] = (char)l->lookahead;
      advance(l);
    }
    word[n] = 0;
    const char *reserved[] = {"def", "type", "law", "match", "case", "do", "return", "for", "exs", "where", "is", "import", "Type", "Data", "Kind", "Quant"};
    bool keyword = false;
    for (unsigned i = 0; i < sizeof(reserved)/sizeof(*reserved); ++i) keyword |= !strcmp(word, reserved[i]);
    if (!keyword) {
      if (v[PARALLEL_START]) {
        if (!push(s, PAR_HEADER, 2)) return false;
        l->result_symbol = PARALLEL_START;
      } else {
        if (!top || !parallel_frame(top->kind)) return false;
        if (top->column == UINT32_MAX) return false;
        ++top->column; l->result_symbol = PARALLEL;
      }
      return true;
    }
    if (top && v[frame_end_token(top->kind)] && body_frame(top->kind)) {
      s->declaration_name |= !strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law");
      pop(s); l->result_symbol = frame_end_token(top->kind); return true;
    }
    return false;
  }
  if ((v[PLUS] && l->lookahead == '+') || (v[MINUS] && l->lookahead == '-')) {
    enum Token t = l->lookahead == '+' ? PLUS : MINUS;
    advance(l);
    if (head(l->lookahead)) {
      if (t == PLUS && v[PATTERN_SEPARATOR]) {
        l->result_symbol = PATTERN_SEPARATOR; return true;
      }
      if (v[BODY_ENTRY] || v[CONTINUATION_ENTRY]) return body_entry(s, l, v[BODY_ENTRY] ? BODY_ENTRY : CONTINUATION_ENTRY);
      if (v[PARALLEL_END] && top && parallel_frame(top->kind) && !top->column) {
        pop(s); l->result_symbol = PARALLEL_END; return true;
      }
      if (spaced && top) {
        if (v[DO_END] && top->kind == DO) {
          pop(s); l->result_symbol = DO_END; return true;
        }
        if (v[frame_end_token(top->kind)] && body_frame(top->kind)) {
          pop(s); l->result_symbol = frame_end_token(top->kind); return true;
        }
      }
      return false;
    }
    if (l->lookahead == '>' || (t == PLUS && l->lookahead == '+')) return false;
    l->mark_end(l); l->result_symbol = t; return true;
  }
  if (spaced && l->lookahead == '>' && (v[GT] || v[GE] || v[SHR])) {
    advance(l);
    enum Token t = GT;
    if (l->lookahead == '=') { t = GE; advance(l); }
    else if (l->lookahead == '>') { t = SHR; advance(l); }
    if (!v[t]) return false;
    l->mark_end(l); l->result_symbol = t; return true;
  }
  if (v[MOD] && l->lookahead == '%') {
    advance(l);
    if (!space(l->lookahead)) {
      if (v[BODY_ENTRY] || v[CONTINUATION_ENTRY]) return body_entry(s, l, v[BODY_ENTRY] ? BODY_ENTRY : CONTINUATION_ENTRY);
      return false;
    }
    l->mark_end(l); l->result_symbol = MOD; return true;
  }
  if (v[PATTERN_SEPARATOR]) {
    int32_t c = l->lookahead;
    if (head(c)) {
      char word[32];
      if (!read_name(l, word, sizeof(word)) || reserved(word)) return false;
      l->result_symbol = PATTERN_SEPARATOR; return true;
    }
    // parse_term_ops treats even spaced ( and [ as postfix on the same line.
    // A comma bypasses this token; a newline genuinely starts another term.
    if ((c >= '0' && c <= '9') || c == '\'' || c == '"' || c == '\\' ||
        (newline && (c == '(' || c == '['))) {
      l->result_symbol = PATTERN_SEPARATOR; return true;
    }
    if (c == '+') {
      advance(l);
      if (head(l->lookahead)) {
        l->result_symbol = PATTERN_SEPARATOR; return true;
      }
      // An expression alternative may still own this arithmetic operator.
      if (v[PLUS] && l->lookahead != '+' && l->lookahead != '>') {
        l->mark_end(l); l->result_symbol = PLUS; return true;
      }
      return false;
    }
  }
  if (v[GLUED_COMPARISON_END]) {
    // Bend 2.0.32: a glued `<` cannot finish its first operand at a type
    // operator. Boolean operators do terminate it; high-precedence operators
    // and suffixes must be given a chance to extend that operand first.
    int32_t c = l->lookahead;
    if (c == '&' || c == '|') {
      advance(l);
      if (l->lookahead != c) return false;
    } else if (c && strchr("+-*/%.<[(!", c)) {
      return false;
    }
    l->result_symbol = GLUED_COMPARISON_END; return true;
  }
  if (v[NATURAL_SUCCESSOR_END]) {
    if (l->lookahead == '=') return successor_end(s, l, newline);
    if (successor_end(s, l, newline)) return true;
  }
  if (l->lookahead == ';' && (v[DO_MORE] || v[WRITE_MORE])) return false;
  if (l->lookahead == ':' && top && v[frame_end_token(top->kind)] && top->kind == LAMBDA) {
    if (typed_assignment(l)) return false;
    pop(s); l->result_symbol = frame_end_token(top->kind); return true;
  }
  // Commit grammar-classified closed types only at real delimiters, never
  // before a number, an identifier suffix, or invalid bytes such as K$ind.
  if (v[ARRAY_TYPE_END] && l->lookahead && strchr("*^=)],;:}", l->lookahead)) {
    if (l->lookahead == '=') {
      advance(l);
      if (l->lookahead == '=' || l->lookahead == '>') return false;
    }
    s->array_checkpoint = true; l->result_symbol = ARRAY_TYPE_END; return true;
  }
  if (v[CALL_OPEN] && l->lookahead && (strchr("<|&*/.!=:", l->lookahead) || (!spaced && l->lookahead == '{'))) return false;
  // Finish operators/postfixes before entering a body, without stealing ';'.
  if (v[BODY_ENTRY] || v[CONTINUATION_ENTRY]) {
    if (l->lookahead == ';' && !v[BODY_ENTRY]) return false;
    // These reserved words cannot begin a body. Inspect only their actual
    // lexeme, not an orphan line or a later possible declaration.
    if (l->lookahead && strchr("cdlt", l->lookahead)) {
      char word[32]; read_name(l, word, sizeof(word));
      if ((!strcmp(word, "case") && !v[CONTINUATION_ENTRY]) || !strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law")) return false;
    }
    return body_entry(s, l, v[BODY_ENTRY] ? BODY_ENTRY : CONTINUATION_ENTRY);
  }
  if (v[STRING_START] && l->lookahead == '"') return string_start(s, l);
  if (v[PARALLEL_VALUE] && top && parallel_frame(top->kind) && top->column) {
    top->kind = PAR; --top->column; l->result_symbol = PARALLEL_VALUE; return true;
  }
  if (v[IDENTIFIER] && head(l->lookahead)) {
    char word[32];
    if (!read_name(l, word, sizeof(word)) || reserved(word)) return false;
    l->mark_end(l); l->result_symbol = IDENTIFIER; return true;
  }
  if ((v[INTEGER] || v[NATURAL] || v[ZERO_NATURAL] || v[SUCCESSOR_NATURAL] || v[FLOAT])
      && l->lookahead >= '0' && l->lookahead <= '9') return scan_number(l, v);
  // Unknown lexical bytes are an error inside this live body, not layout.
  // Group bodies may still end before a native error preceding their real ')'.
  if (top && (top->kind == BODY || (top->kind == CASE_ARM && (!newline || col >= top->column)))
      && l->lookahead && !head(l->lookahead)
      && !(l->lookahead >= '0' && l->lookahead <= '9')
      && !strchr("'\"\\@?+-~&|*/%.<>=!{([)}],;:", l->lookahead)) return false;
  // Give ordinary grammar tokens a chance to extend the current expression.
  if (strchr("<{|&*/.!=:", l->lookahead) && l->lookahead) return false;
  if (v[PARALLEL_END] && top && parallel_frame(top->kind) && !top->column) {
    pop(s); l->result_symbol = PARALLEL_END; return true;
  }
  if (top && v[frame_end_token(top->kind)] && body_frame(top->kind)) {
    // A group owns its real closing delimiter, including its annotation.
    if (top->kind == GROUP && !l->eof(l) && l->lookahead != ')' && l->lookahead != ',') return false;
    bool arm = top->kind == CASE_ARM
      && (!newline || col >= top->column);
    if (arm && l->lookahead && strchr("~;\\@?'\"{([", l->lookahead)) return false;
    if (arm && l->lookahead && strchr(")]},", l->lookahead)) {
      bool outer = false;
      for (unsigned i = 0; i + 1 < s->size; ++i)
        outer |= (s->frames[i].kind == BLOCK || s->frames[i].kind == GROUP) || s->frames[i].kind == LAMBDA;
      if (!outer) return false;
    }
    if ((top->kind == BODY || top->kind == CASE_ARM) && l->lookahead >= '0' && l->lookahead <= '9'
        && (!newline || col > top->column || arm)) return false;
    if (head(l->lookahead)) {
      // The next state may expect only `)`, so no scanner runs there. Remember
      // a following declaration before a missing closer enters recovery.
      char word[32]; read_name(l, word, sizeof(word));
      // Let rejection own an unexpected continuation inside this body. A
      // dedented orphan must not corrupt the preceding complete declaration.
      if ((top->kind == BODY || top->kind == CASE_ARM) && !reserved(word) && (!newline || col > top->column || arm)) return false;
      s->declaration_name |= !strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law");
    }
    pop(s); l->result_symbol = frame_end_token(top->kind); return true;
  }
  if (v[WRITE_END] && top && top->kind == WRITE) {
    pop(s); l->result_symbol = WRITE_END; return true;
  }
  if (v[DO_END] && top && top->kind == DO) {
    pop(s); l->result_symbol = DO_END; return true;
  }
  return false;
}
