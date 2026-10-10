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
  PATTERN_SEPARATOR, SUCCESSOR_NATURAL, ZERO_NATURAL, NATURAL_PLUS,
};
enum Kind { BODY, MATCH, DO, PAR, LAMBDA, WRITE, CASE_HEADER, BLOCK, MATCH_CLOSED_ARM };
static bool match_frame(uint8_t kind) { return kind == MATCH || kind == MATCH_CLOSED_ARM; }
typedef struct { uint32_t column, first; uint8_t kind; } Frame;
#define MAX_FRAMES 200
_Static_assert(MAX_FRAMES <= UINT8_MAX, "frame count must fit in one byte");
// Match frames use `first` in both normal and recovered-arm states. Other
// frames need five bytes, not nine. Reserve the exact size; never truncate.
typedef struct { uint8_t size; bool declaration_name, closed_string, decorator_name; Frame frames[MAX_FRAMES]; } Scanner;

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
static bool push(Scanner *s, uint8_t kind, uint32_t column) {
  if (s->size == MAX_FRAMES) return false;
  unsigned bytes = 3 + 5 * (s->size + 1) + (match_frame(kind) ? 4 : 0);
  for (unsigned i = 0; i < s->size; ++i) bytes += match_frame(s->frames[i].kind) ? 4 : 0;
  if (bytes > TREE_SITTER_SERIALIZATION_BUFFER_SIZE) return false;
  s->frames[s->size++] = (Frame){column, UINT32_MAX, kind};
  return true;
}
static uint32_t body_column(const Scanner *s) {
  for (unsigned i = s->size; i; --i)
    if (s->frames[i-1].kind == BODY || s->frames[i-1].kind == LAMBDA || s->frames[i-1].kind == BLOCK) return s->frames[i-1].column;
  return 0;
}
static inline enum Token frame_end_token(uint8_t kind) {
  switch (kind) {
    case MATCH: case MATCH_CLOSED_ARM: return MATCH_END;
    case DO:    return DO_END;
    case PAR:   return PARALLEL_END;
    case WRITE: return WRITE_END;
    default:    return BODY_END;
  }
}
void *tree_sitter_bend2_external_scanner_create(void) { return calloc(1, sizeof(Scanner)); }
void tree_sitter_bend2_external_scanner_destroy(void *p) { free(p); }
unsigned tree_sitter_bend2_external_scanner_serialize(void *p, char *b) {
  Scanner *s = p;
  unsigned n = 0;
  b[n++] = (char)s->size;
  b[n++] = (char)(s->declaration_name | (s->decorator_name << 1));
  b[n++] = (char)s->closed_string;
  for (unsigned i = 0; i < s->size; ++i) {
    Frame f = s->frames[i];
    b[n++] = (char)f.kind;
    for (unsigned j = 0; j < 4; ++j) b[n++] = (char)(f.column >> (8*j));
    if (match_frame(f.kind))
      for (unsigned j = 0; j < 4; ++j) b[n++] = (char)(f.first >> (8*j));
  }
  return n;
}
void tree_sitter_bend2_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  Scanner *s = p;
  s->size = 0;
  s->declaration_name = s->closed_string = s->decorator_name = false;
  if (n < 3 || n > TREE_SITTER_SERIALIZATION_BUFFER_SIZE || (uint8_t)b[0] > MAX_FRAMES
      || (uint8_t)b[1] > 3 || (uint8_t)b[2] > 1) return;
  unsigned at = 3;
  for (unsigned i = 0; i < (uint8_t)b[0]; ++i) {
    if (n - at < 5) return;
    Frame *f = &s->frames[i];
    f->kind = (uint8_t)b[at++]; f->column = 0; f->first = UINT32_MAX;
    if (f->kind > MATCH_CLOSED_ARM) return;
    for (unsigned j = 0; j < 4; ++j) f->column |= (uint32_t)(uint8_t)b[at++] << (8*j);
    if (match_frame(f->kind)) {
      if (n - at < 4) return;
      f->first = 0;
      for (unsigned j = 0; j < 4; ++j) f->first |= (uint32_t)(uint8_t)b[at++] << (8*j);
    }
  }
  if (at != n) return;
  s->size = (uint8_t)b[0];
  s->declaration_name = (b[1] & 1) != 0;
  s->decorator_name = (b[1] & 2) != 0;
  s->closed_string = b[2] != 0;
}
bool tree_sitter_bend2_external_scanner_scan(void *p, TSLexer *l, const bool *v) {
  Scanner *s = p;
  l->mark_end(l); // Zero-width layout tokens must not include following whitespace.
  if (!v[ERROR_SENTINEL] && v[STRING_NEWLINE] && l->lookahead == '\n') {
    if (!s->closed_string) return false;
    advance(l); l->mark_end(l); l->result_symbol = STRING_NEWLINE; return true;
  }
  bool newline = l->get_column(l) == 0, spaced = false;
  while (space(l->lookahead)) {
    newline |= l->lookahead == '\n'; spaced = true; l->advance(l, true);
  }
  if (l->lookahead == '#') return false; // Let the grammar retain comment nodes.
  uint32_t col = l->get_column(l);
  if (!v[ERROR_SENTINEL] && v[STRING_START] && l->lookahead == '"') {
    // Probe once per string, keeping the token's end at its opening quote.
    // Valid multiline strings remain valid. If no unescaped closing quote
    // exists, a newline becomes a recovery boundary rather than swallowing
    // every following declaration. Lookahead also invalidates this token when
    // an incremental edit removes or restores a distant closing quote.
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
  Frame *top = s->size ? &s->frames[s->size-1] : NULL;
  if (v[DECORATOR_START] && l->lookahead == '@') {
    bool close = v[ERROR_SENTINEL] && newline && top
      && top->kind != PAR && v[frame_end_token(top->kind)];
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
      --s->size; l->result_symbol = end; return true;
    }
    if (strcmp(word, "def")) return false; // Only def may have this decorator.
    s->size = 0;
    s->decorator_name = true;
    l->result_symbol = DECORATOR_START; return true;
  }
  // Recovery must not reinterpret a following declaration's name as a value
  // in the damaged body. Give headers distinct tokens but the same public CST.
  if (head(l->lookahead) && (v[DEF_KEYWORD] || v[TYPE_KEYWORD] || v[LAW_KEYWORD] || v[DECLARATION_NAME] || v[UNSAFE_KEYWORD]
      || (top && top->kind == CASE_HEADER && (v[CASE] || v[MATCH_END])))) {
    char word[32];
    bool valid_name = read_name(l, word, sizeof(word));
    if (v[UNSAFE_KEYWORD] && s->decorator_name && !strcmp(word, "unsafe")) {
      s->decorator_name = false;
      l->mark_end(l); l->result_symbol = UNSAFE_KEYWORD; return true;
    }
    if (newline && !strcmp(word, "case") && top && top->kind != PAR
        && (v[ERROR_SENTINEL] || (top->kind == CASE_HEADER && (v[CASE] || v[MATCH_END])))) {
      // A same-column sibling arm is a boundary for the damaged arm, not for
      // its owning match. Close only existing scopes above that match.
      for (unsigned i = s->size; i > 0; --i) {
        Frame *owner = &s->frames[i - 1];
        if (owner->kind != MATCH || (owner->first != col
            && !(owner->first == UINT32_MAX && col >= owner->column))) continue;
        if (top->kind == CASE_HEADER && s->size >= 2 && &s->frames[s->size - 2] != owner) {
          // A damaged inner header has no body to finish. Close its real
          // inner match before handing the dedented arm back to the outer one.
          if (!v[MATCH_END]) return false;
          // The error probe is relexed from its original scanner state. The
          // resumed normal scan must close both header and actual inner match.
          s->size -= v[ERROR_SENTINEL] ? 1 : 2;
          l->result_symbol = MATCH_END; return true;
        }
        if ((top->kind == CASE_HEADER || top == owner) && v[CASE]) {
          l->mark_end(l);
          owner->first = owner->first == UINT32_MAX ? col : owner->first;
          // No body exists to close: abandon the damaged header and restart
          // its sibling under the same owning match, leaving a native error.
          s->size = i;
          if (!push(s, CASE_HEADER, col + 1)) return false;
          l->result_symbol = CASE; return true;
        }
        if (top != owner) {
          enum Token end = frame_end_token(top->kind);
          if (v[end]) {
            --s->size; l->result_symbol = end; return true;
          }
        }
        break;
      }
    }
    enum Token t = !strcmp(word, "def") ? DEF_KEYWORD : !strcmp(word, "type") ? TYPE_KEYWORD :
      !strcmp(word, "law") ? LAW_KEYWORD : ERROR_SENTINEL;
    if (t != ERROR_SENTINEL && v[ERROR_SENTINEL] && !newline && !s->declaration_name) return false;
    if (t != ERROR_SENTINEL && newline && col == 0 && top && top->kind != PAR && (!v[t] || v[ERROR_SENTINEL])) {
      if (top->kind == MATCH && top->first != UINT32_MAX && v[BODY_END] && !v[MATCH_END]) {
        // Pattern recovery can consume the arm's frame while the parser still
        // needs its end. A recorded case makes this a real arm boundary;
        // emit it once per owning match by persisting the state transition,
        // keeping the real match and outer body available for their own ends.
        s->declaration_name = true;
        top->kind = MATCH_CLOSED_ARM; l->result_symbol = BODY_END; return true;
      }
      // A damaged pattern may still be waiting for a body or a closer, with
      // no declaration token enabled. Close existing scopes before the
      // internal recovery lexer can consume this header as another word.
      enum Token end = frame_end_token(top->kind);
      if (v[end]) {
        // The next state may wait for a missing closer without scanning the
        // header again; remember its name just as ordinary BODY_END does.
        s->declaration_name = true;
        --s->size; l->result_symbol = end; return true;
      }
    }
    // A viable fresh header takes precedence over stale normal-mode frames.
    // Otherwise an unfinished delimiter can cost the next declaration its CST.
    if (t != ERROR_SENTINEL && v[t]) {
      s->size = 0;
      s->decorator_name = false;
      l->mark_end(l);
      // A missing name must not turn a later parameter into the declaration
      // name during recovery. Normal parsing still permits multiline headers.
      skip_layout(l);
      s->declaration_name = l->lookahead != '(';
      l->result_symbol = t; return true;
    }
    if (v[DECLARATION_NAME] && (!v[ERROR_SENTINEL] || s->declaration_name) && valid_name && !reserved(word)) {
      s->size = 0;
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
      if (!v[ERROR_SENTINEL] && v[BODY_END] && top && top->kind == BLOCK && l->lookahead == ')') {
        --s->size; l->result_symbol = BODY_END; return true;
      }
      return false;
    }
    l->mark_end(l); l->result_symbol = GPU_MODIFIER; return true;
  }
  if (v[ERROR_SENTINEL]) {
    // Real lexemes are safe recovery anchors too. Otherwise an invalid byte
    // can swallow the next intact literal before any parser state can resume.
    if (l->lookahead >= '0' && l->lookahead <= '9') return scan_number(l, v);
    // Only actual, bounded scope closures are safe to synthesize at EOF. Never
    // push speculative frames while Tree-sitter is trying all recovery tokens.
    if (!top || !l->eof(l)) return false;
    enum Token t = frame_end_token(top->kind);
    --s->size; l->result_symbol = t; return true;
  }
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
  if (v[CASE_BODY_START] && top && top->kind == CASE_HEADER) {
    top->kind = BODY;
    l->result_symbol = CASE_BODY_START; return true;
  }
  if (v[FUNCTION_START] || v[BLOCK_START] || v[LAMBDA_START] || v[DO_START]) {
    // A genuine declaration name clears prior frames. A live case/layout
    // stack here means recovery rewound to an old header's colon instead.
    if (v[FUNCTION_START] && s->size) return false;
    if (v[CALL_OPEN] && l->lookahead && strchr("&|*/.<", l->lookahead)) return false;
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
    } else if (!strchr("+@&\\\\%{(['\"?", l->lookahead) && !(l->lookahead >= '0' && l->lookahead <= '9')) {
      return false;
    }
    enum Token t = v[FUNCTION_START] ? FUNCTION_START : v[BLOCK_START] ? BLOCK_START : v[LAMBDA_START] ? LAMBDA_START : DO_START;
    if (!push(s, t == DO_START ? DO : t == LAMBDA_START ? LAMBDA : t == BLOCK_START ? BLOCK : BODY,
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
  if (v[MATCH_START]) {
    if (!push(s, MATCH, body_column(s))) return false;
    l->result_symbol = MATCH_START; return true;
  }
  if ((v[CASE] || v[MATCH_END]) && top && match_frame(top->kind)) {
    // A case owns its keyword, not the whitespace after the previous body.
    // MATCH_END must instead remain at the previous body's end.
    if (v[CASE] && col >= top->column && (top->first == UINT32_MAX || col >= top->first) && l->lookahead == 'c') l->mark_end(l);
    bool is_case = true;
    const char *word = "case";
    for (unsigned i = 0; i < 4; ++i) {
      if (l->lookahead != word[i]) { is_case = false; break; }
      advance(l);
    }
    is_case &= !name(l->lookahead);
    bool eligible = is_case && col >= top->column && (top->first == UINT32_MAX || col >= top->first);
    if (eligible && v[CASE]) {
      l->mark_end(l);
      if (!push(s, CASE_HEADER, col + 1)) return false;
      top->first = top->first == UINT32_MAX ? col : top->first;
      l->result_symbol = CASE; return true;
    }
    if (!eligible && v[MATCH_END]) {
      --s->size; l->result_symbol = MATCH_END; return true;
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
        if (!push(s, PAR, 2)) return false;
        l->result_symbol = PARALLEL_START;
      } else {
        if (!top || top->kind != PAR) return false;
        ++top->column; l->result_symbol = PARALLEL;
      }
      return true;
    }
    if (v[BODY_END] && top && (top->kind == BODY || top->kind == LAMBDA || top->kind == BLOCK)) {
      s->declaration_name |= !strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law");
      --s->size; l->result_symbol = BODY_END; return true;
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
      if (v[PARALLEL_END] && top && top->kind == PAR && !top->column) {
        --s->size; l->result_symbol = PARALLEL_END; return true;
      }
      if (spaced && top) {
        if (v[DO_END] && top->kind == DO) {
          --s->size; l->result_symbol = DO_END; return true;
        }
        if (v[BODY_END] && (top->kind == BODY || top->kind == LAMBDA || top->kind == BLOCK)) {
          --s->size; l->result_symbol = BODY_END; return true;
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
    if (!space(l->lookahead)) return false;
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
    if ((c >= '0' && c <= '9') || c == '\'' || c == '"' ||
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
  if (l->lookahead == ';' && (v[DO_MORE] || v[WRITE_MORE])) return false;
  if (l->lookahead == ':' && v[BODY_END] && top && top->kind == LAMBDA) {
    if (typed_assignment(l)) return false;
    --s->size; l->result_symbol = BODY_END; return true;
  }
  if (v[CALL_OPEN] && l->lookahead && (strchr("<|&*/.!=:", l->lookahead) || (!spaced && l->lookahead == '{'))) return false;
  if (v[PARALLEL_VALUE] && top && top->kind == PAR && top->column) {
    --top->column; l->result_symbol = PARALLEL_VALUE; return true;
  }
  if (v[IDENTIFIER] && head(l->lookahead)) {
    char word[32];
    if (!read_name(l, word, sizeof(word)) || reserved(word)) return false;
    l->mark_end(l); l->result_symbol = IDENTIFIER; return true;
  }
  if ((v[INTEGER] || v[NATURAL] || v[ZERO_NATURAL] || v[SUCCESSOR_NATURAL] || v[FLOAT])
      && l->lookahead >= '0' && l->lookahead <= '9') return scan_number(l, v);
  // Give ordinary grammar tokens a chance to extend the current expression.
  if (strchr("<{|&*/.!=:", l->lookahead) && l->lookahead) return false;
  if (v[PARALLEL_END] && top && top->kind == PAR && !top->column) {
    --s->size; l->result_symbol = PARALLEL_END; return true;
  }
  if (v[BODY_END] && top && (top->kind == BODY || top->kind == LAMBDA || top->kind == BLOCK)) {
    if (head(l->lookahead)) {
      // The next state may expect only `)`, so no scanner runs there. Remember
      // a following declaration before a missing closer enters recovery.
      char word[32]; read_name(l, word, sizeof(word));
      s->declaration_name |= !strcmp(word, "def") || !strcmp(word, "type") || !strcmp(word, "law");
    }
    --s->size; l->result_symbol = BODY_END; return true;
  }
  if (v[WRITE_END] && top && top->kind == WRITE) {
    --s->size; l->result_symbol = WRITE_END; return true;
  }
  if (v[DO_END] && top && top->kind == DO) {
    --s->size; l->result_symbol = DO_END; return true;
  }
  return false;
}
