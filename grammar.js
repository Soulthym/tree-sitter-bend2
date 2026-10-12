/**
 * @file Concrete syntax for Bend 2 (see README.md for the pinned reference).
 * @author Thybault Alabarbe <thybault.alabarbe@gmail.com>
 * @license MIT
 */
/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const args = (rule, separator = ',') => repeat(seq(rule, optional(separator)));

export default grammar({
  name: 'bend2',
  extras: $ => [/[ \t\r\n]+/, $.comment, $._root_layout, $._array_layout],
  // Names are scanned as whole lexemes: contextual keyword extraction can turn
  // `def` into an identifier when recovering from a missing closing delimiter.
  externals: $ => [
    $._function_start, $._block_start, $._body_end, $._lambda_start,
    $._match_start, $._match_end, $._case,
    $._do_start, $._do_end, $._do_more,
    $._call_open, $._index_open,
    $._plus, $._minus, $._gt, $._ge, $._shr, $._mod,
    $._parallel, $._parallel_start, $._parallel_value, $._parallel_end,
    $._write_start, $._write_more, $._write_end, $._import_start, $._import_end,
    $.integer, $.natural, $.float, $.identifier,
    $._def_keyword, $._type_keyword, $._law_keyword, $._declaration_name,
    $._string_start, $._string_newline,
    $._lt, $._glued_lt, $._glued_comparison_end, $._error_sentinel, $._gpu_open,
    $._gpu_modifier, $._case_body_start, $._decorator_start, $._at, $._unsafe_keyword,
    $._pattern_separator, $._successor_natural, $._zero_natural, $._natural_plus, $._amp, $._natural_successor_end, $.module_alias,
    $._body_entry, $._array_type_end, $._continuation_entry, $._header_checkpoint, $._case_pattern_end, $._case_header_start, $._root_layout, $._arm_end, $._block_end, $._lambda_end, $._group_start, $._group_end, $._function_match_start, $._function_match_end, $._function_case_word, $._arm_match_start, $._arm_match_end, $._arm_case_word, $._block_match_start, $._block_match_end, $._block_case_word, $._lambda_match_start, $._lambda_match_end, $._lambda_case_word, $._array_layout,
  ],
  // Keep atomic callers available through infix shifts in block headers and
  // full successor operands. Other contexts retain their ordinary reductions.
  inline: $ => [$._header_expression, $._natural, $._array_terminal_atom],
  conflicts: $ => [
    [$._plain_lambda_match, $._owned_lambda_match],
    [$._plain_block_match, $._owned_block_match],
    [$._plain_arm_match, $._owned_arm_match],
    [$._plain_function_match, $._owned_function_match],

    [$._array_value_prefix, $._array_value_type],


    [$._owned_arm_match],
    [$._named_binding, $._name_parenthesized],

    [$.type_application, $._atom],
    [$._destructuring_pattern, $._atom],
    [$._name_pattern, $._atom],
    [$._pattern_list, $.list_expression],
    [$._pattern_constructor, $.constructor_expression],
  ],
  rules: {
    source_file: $ => seq(repeat($.import_statement), repeat($._declaration)),
    _declaration: $ => choice($.function_definition, $.type_definition, $.law_definition),
    import_statement: $ => seq($._import_start, 'import', choice('Base', seq(
      field('path', $.import_path), 'as', field('alias', $.module_alias))), $._import_end),
    import_path: $ => /(?:\.\/|(?:\.\.\/)+|\/|0x[0-9a-f]+\/|[^\s/]+@[^\s/]+\/)?(?:[A-Za-z_][A-Za-z0-9_-]*\/)*[A-Za-z_][A-Za-z0-9_-]*\.bend/,
    // Keep whole header keywords external even in recovery. Condense the real
    // function header before its body; a pending name belongs only to the
    // checkpoint immediately after its own keyword, never an older prefix.
    function_definition: $ => seq($._function_header,
      field('body', choice($.foreign_body, seq($._function_start, $._body_entry,
        choice(alias($._function_body, $.body), seq($.body, $._body_end)))))),
    _function_header: $ => seq(optional($.decorator), alias($._def_keyword, 'def'), $._header_checkpoint,
      field('name', alias($._declaration_name, $.identifier)),
      optional(token.immediate('?')), field('parameters', $.parameters), optional(seq('->', field('return_type', $._expression))),
      ':'),
    decorator: $ => seq(alias($._decorator_start, '@'), alias($._unsafe_keyword, 'unsafe')),
    parameters: $ => seq('(', args($.parameter), ')'),
    parameter: $ => choice(field('name', $.identifier), seq(
      optional(field('quantity', choice('+', '-', '~'))), field('name', $.identifier), ':', field('type', $._expression))),
    foreign_body: $ => repeat1($.foreign_import),
    foreign_import: $ => seq('import', field('path', $.string)),
    type_definition: $ => seq(alias($._type_keyword, 'type'), $._header_checkpoint,
      field('name', alias($._declaration_name, $.identifier)), optional($.type_parameters),
      'is', field('kind', $._expression), ':', repeat($.constructor_definition)),
    type_parameters: $ => seq('<', args($.type_parameter), '>'),
    type_parameter: $ => choice(field('name', $.identifier), seq(
      optional(field('quantity', choice('+', '-'))), field('name', $.identifier), ':', field('type', $._expression))),
    constructor_definition: $ => seq(field('name', $.identifier), '{', args($.type_parameter), '}'),
    _law_header: $ => seq(alias($._law_keyword, 'law'), $._header_checkpoint,
      field('name', alias($._declaration_name, $.identifier)), ':'),
    law_definition: $ => seq($._law_header,
      repeat(alias($._law_template_clause, $.law_clause)), repeat($.law_clause),
      field('body', $._block)),
    // Summarize only consumed clause prefixes. Native recovery can then
    // finish a nested rewrite and its still-missing enclosing law body.
    _law_template_header: $ => seq('for', field('quantity', '~'), field('name', $.identifier), ':'),
    _law_clause_header: $ => seq(choice(seq('for', optional(field('quantity', choice('+', '-')))), 'exs'),
      field('name', $.identifier), ':'),
    _law_template_constraint_header: $ => seq($._law_template_header, field('type', $._header_expression), 'where'),
    _law_constraint_header: $ => seq($._law_clause_header, field('type', $._header_expression), 'where'),
    _law_template_clause: $ => choice(seq($._law_template_header, field('type', $._header_expression)),
      seq($._law_template_constraint_header, field('constraint', $._header_expression))),
    law_clause: $ => choice(seq($._law_clause_header, field('type', $._header_expression)),
      seq($._law_constraint_header, field('constraint', $._header_expression))),

    // Bodies terminate with a value or match; lets own the rest of the body.
    _block: $ => seq($._block_start, $._body_entry, $._block_value),
    _block_value: $ => choice(alias($._block_body, $.body), seq($.body, $._block_end)),
    // Keep entry outside public body nodes so native recovery can retain an
    // intact terminal body without including the rejected prefix in its range.
    _body: $ => seq($._body_entry, $.body),
    // A continuation must let its optional ';' shift first. Initial entry is
    // distinct so an invalid leading ';' can retain the actual case/body owner.
    _continuation: $ => seq($._continuation_entry, $.body),
    body: $ => choice($.let_expression, $.parallel_let_expression, $.match_expression, alias($._plain_function_match, $.match_expression), alias($._plain_arm_match, $.match_expression), alias($._plain_block_match, $.match_expression), alias($._plain_lambda_match, $.match_expression), $.write_sequence, $._expression),
    binding: $ => choice($._pattern, seq('-', $.identifier)),
    _named_binding: $ => choice($._name_pattern, seq('-', $.identifier)),
    let_expression: $ => prec.right(seq(choice(
      seq(field('pattern', $.binding), '='),
      seq(field('pattern', alias($._named_binding, $.binding)), ':', field('type', $._expression), '=')),
      field('value', $._expression), optional(';'), field('body', $._continuation))),
    parallel_let_expression: $ => seq(field('pattern', alias($._named_binding, $.binding)),
      $._parallel_start, field('pattern', alias($._named_binding, $.binding)),
      repeat(seq($._parallel, field('pattern', alias($._named_binding, $.binding)))), '=',
      repeat1(seq($._parallel_value, field('value', $._expression))), $._parallel_end,
      optional(';'), field('body', $._continuation)),
    write_sequence: $ => seq(field('write', alias($._statement_write, $.array_write)),
      optional(seq(choice(';', $._write_more), field('body', $._continuation))), $._write_end),
    _statement_write: $ => seq(field('target', alias($._statement_index, $.index_expression)),
      '<-', field('value', $._write_value)),
    _statement_index: $ => seq(field('array', alias($._write_start, $.identifier)),
      alias($._index_open, '['), field('index', $._expression), ']'),
    match_expression: $ => seq($._match_header, $._match_start, repeat($.case_clause), $._match_end),
    _match_header: $ => seq('match', repeat1(seq(field('value', $._expression), optional(','))), ':'),
    case_clause: $ => seq($._case_header, $._case_body_start, $._body_entry, choice(field('body', alias($._arm_body, $.body)), seq(field('body', $.body), $._arm_end))),
    _case_header: $ => seq(alias($._case, 'case'), $._case_header_start,
      patternSep1($, field('pattern', $._pattern)), optional($._case_pattern_end), ':'),

    _function_body: $ => choice(alias($._owned_function_let, $.let_expression), alias($._owned_function_parallel, $.parallel_let_expression), alias($._owned_function_match, $.match_expression)),
    _owned_function_continuation: $ => seq($._continuation_entry, alias($._function_body, $.body)),
    _owned_function_let: $ => prec.right(seq(choice(
      seq(field('pattern', $.binding), '='),
      seq(field('pattern', alias($._named_binding, $.binding)), ':', field('type', $._expression), '=')),
      field('value', $._expression), optional(';'), field('body', $._owned_function_continuation))),
    _owned_function_parallel: $ => seq(field('pattern', alias($._named_binding, $.binding)),
      $._parallel_start, field('pattern', alias($._named_binding, $.binding)),
      repeat(seq($._parallel, field('pattern', alias($._named_binding, $.binding)))), '=',
      repeat1(seq($._parallel_value, field('value', $._expression))), $._parallel_end,
      optional(';'), field('body', $._owned_function_continuation)),

    _owned_function_match: $ => seq($._match_header, $._function_match_start, repeat(alias($._function_case, $.case_clause)), $._function_match_end, $._body_end, repeat(seq(repeat1(alias($._function_case, $.case_clause)), $._function_match_end, $._body_end))),
    _arm_body: $ => choice(alias($._owned_arm_let, $.let_expression), alias($._owned_arm_parallel, $.parallel_let_expression), alias($._owned_arm_match, $.match_expression)),
    _owned_arm_continuation: $ => seq($._continuation_entry, alias($._arm_body, $.body)),
    _owned_arm_let: $ => prec.right(seq(choice(
      seq(field('pattern', $.binding), '='),
      seq(field('pattern', alias($._named_binding, $.binding)), ':', field('type', $._expression), '=')),
      field('value', $._expression), optional(';'), field('body', $._owned_arm_continuation))),
    _owned_arm_parallel: $ => seq(field('pattern', alias($._named_binding, $.binding)),
      $._parallel_start, field('pattern', alias($._named_binding, $.binding)),
      repeat(seq($._parallel, field('pattern', alias($._named_binding, $.binding)))), '=',
      repeat1(seq($._parallel_value, field('value', $._expression))), $._parallel_end,
      optional(';'), field('body', $._owned_arm_continuation)),

    _owned_arm_match: $ => seq($._match_header, $._arm_match_start, repeat(alias($._arm_case, $.case_clause)), $._arm_match_end, $._arm_end, repeat(seq(repeat1(alias($._arm_case, $.case_clause)), $._arm_match_end, $._arm_end))),
    _block_body: $ => choice(alias($._owned_block_let, $.let_expression), alias($._owned_block_parallel, $.parallel_let_expression), alias($._owned_block_match, $.match_expression)),
    _owned_block_continuation: $ => seq($._continuation_entry, alias($._block_body, $.body)),
    _owned_block_let: $ => prec.right(seq(choice(
      seq(field('pattern', $.binding), '='),
      seq(field('pattern', alias($._named_binding, $.binding)), ':', field('type', $._expression), '=')),
      field('value', $._expression), optional(';'), field('body', $._owned_block_continuation))),
    _owned_block_parallel: $ => seq(field('pattern', alias($._named_binding, $.binding)),
      $._parallel_start, field('pattern', alias($._named_binding, $.binding)),
      repeat(seq($._parallel, field('pattern', alias($._named_binding, $.binding)))), '=',
      repeat1(seq($._parallel_value, field('value', $._expression))), $._parallel_end,
      optional(';'), field('body', $._owned_block_continuation)),

    _owned_block_match: $ => seq($._match_header, $._block_match_start, repeat(alias($._block_case, $.case_clause)), $._block_match_end, $._block_end, repeat(seq(repeat1(alias($._block_case, $.case_clause)), $._block_match_end, $._block_end))),
    _lambda_body: $ => choice(alias($._owned_lambda_let, $.let_expression), alias($._owned_lambda_parallel, $.parallel_let_expression), alias($._owned_lambda_match, $.match_expression)),
    _owned_lambda_continuation: $ => seq($._continuation_entry, alias($._lambda_body, $.body)),
    _owned_lambda_let: $ => prec.right(seq(choice(
      seq(field('pattern', $.binding), '='),
      seq(field('pattern', alias($._named_binding, $.binding)), ':', field('type', $._expression), '=')),
      field('value', $._expression), optional(';'), field('body', $._owned_lambda_continuation))),
    _owned_lambda_parallel: $ => seq(field('pattern', alias($._named_binding, $.binding)),
      $._parallel_start, field('pattern', alias($._named_binding, $.binding)),
      repeat(seq($._parallel, field('pattern', alias($._named_binding, $.binding)))), '=',
      repeat1(seq($._parallel_value, field('value', $._expression))), $._parallel_end,
      optional(';'), field('body', $._owned_lambda_continuation)),

    _owned_lambda_match: $ => seq($._match_header, $._lambda_match_start, repeat(alias($._lambda_case, $.case_clause)), $._lambda_match_end, $._lambda_end, repeat(seq(repeat1(alias($._lambda_case, $.case_clause)), $._lambda_match_end, $._lambda_end))),

    _function_case: $ => seq($._function_case_header, $._case_body_start, $._body_entry, choice(field('body', alias($._arm_body, $.body)), seq(field('body', $.body), $._arm_end))),
    _function_case_header: $ => seq(alias($._function_case_word, 'case'), $._case_header_start,
      patternSep1($, field('pattern', $._pattern)), optional($._case_pattern_end), ':'),
    _arm_case: $ => seq($._arm_case_header, $._case_body_start, $._body_entry, choice(field('body', alias($._arm_body, $.body)), seq(field('body', $.body), $._arm_end))),
    _arm_case_header: $ => seq(alias($._arm_case_word, 'case'), $._case_header_start,
      patternSep1($, field('pattern', $._pattern)), optional($._case_pattern_end), ':'),
    _block_case: $ => seq($._block_case_header, $._case_body_start, $._body_entry, choice(field('body', alias($._arm_body, $.body)), seq(field('body', $.body), $._arm_end))),
    _block_case_header: $ => seq(alias($._block_case_word, 'case'), $._case_header_start,
      patternSep1($, field('pattern', $._pattern)), optional($._case_pattern_end), ':'),
    _lambda_case: $ => seq($._lambda_case_header, $._case_body_start, $._body_entry, choice(field('body', alias($._arm_body, $.body)), seq(field('body', $.body), $._arm_end))),
    _lambda_case_header: $ => seq(alias($._lambda_case_word, 'case'), $._case_header_start,
      patternSep1($, field('pattern', $._pattern)), optional($._case_pattern_end), ':'),
    _plain_function_match: $ => seq($._match_header, $._function_match_start, repeat(alias($._function_case, $.case_clause)), $._function_match_end),
    _plain_arm_match: $ => seq($._match_header, $._arm_match_start, repeat(alias($._arm_case, $.case_clause)), $._arm_match_end),
    _plain_block_match: $ => seq($._match_header, $._block_match_start, repeat(alias($._block_case, $.case_clause)), $._block_match_end),
    _plain_lambda_match: $ => seq($._match_header, $._lambda_match_start, repeat(alias($._lambda_case, $.case_clause)), $._lambda_match_end),

    // parse_patt accepts variables, recursive constructors, and literals.
    // Surface sugars retain expression CST nodes, but their children must also
    // be patterns. Constructor resolution, arity, and literal limits belong to
    // the compiler rather than this context-free syntax.
    _pattern: $ => choice($._name_pattern, $._destructuring_pattern),
    _name_pattern: $ => choice($.identifier,
      alias($._pattern_reusable, $.reusable_expression),
      alias($._name_parenthesized, $.parenthesized_expression),
      alias($._name_call, $.call_expression),
      alias($._name_successor, $.natural_successor),
      alias($._name_eliminator, $.eliminator)),
    // With no arms, parse_term_base returns the fallback unchanged.
    _name_eliminator: $ => seq('\\', '{', field('fallback', $._name_pattern), optional(';'), '}'),
    _pattern_reusable: $ => prec(12, seq('+', $._name_pattern)),
    _group_open: $ => seq('(', $._group_start, $._body_entry),
    _name_parenthesized: $ => seq($._group_open,
      field('body', alias($._name_pattern, $.body)),
      optional(seq(':', field('type', $._expression))), $._group_end, ')'),
    _name_call: $ => prec.left(14, seq(field('function', $._name_pattern),
      field('arguments', alias($._empty_arguments, $.arguments)))),
    _empty_arguments: $ => seq(alias($._call_open, '('), ')'),
    // Reduce only the common prefix, never a completed pattern as an atom.
    _zero_successor_prefix: $ => seq(alias($._zero_natural, $.natural), alias($._natural_plus, '+')),
    _nonzero_successor_prefix: $ => seq(alias($._successor_natural, $.natural), alias($._natural_plus, '+')),
    _name_successor: $ => prec.right(-1, seq($._zero_successor_prefix,
      field('value', $._name_pattern), optional($._natural_successor_end))),
    _natural: $ => choice($.natural, alias($._zero_natural, $.natural), alias($._successor_natural, $.natural)),
    _destructuring_pattern: $ => choice($.integer, $.natural, $.float, $.character, $.string,
      alias($._pattern_constructor, $.constructor_expression),
      alias($._pattern_successor, $.natural_successor),
      alias($._pattern_parenthesized, $.parenthesized_expression),
      alias($._pattern_tuple, $.tuple_expression),
      alias($._pattern_list, $.list_expression),
      alias($._pattern_cons, $.binary_expression),
      alias($._pattern_call, $.call_expression),
      alias($._pattern_eliminator, $.eliminator)),
    _pattern_eliminator: $ => seq('\\', '{', field('fallback', $._destructuring_pattern), optional(';'), '}'),
    _pattern_constructor: $ => seq(field('name', $.identifier), token.immediate('{'), optional(patternSep1($, $._pattern)), '}'),
    _pattern_successor: $ => prec.right(-1, choice(
      seq($._nonzero_successor_prefix, field('value', $._pattern), optional($._natural_successor_end)),
      seq($._zero_successor_prefix, field('value', $._destructuring_pattern), optional($._natural_successor_end)))),
    _pattern_call: $ => prec.left(14, seq(field('function', $._destructuring_pattern),
      field('arguments', alias($._empty_arguments, $.arguments)))),
    _pattern_parenthesized: $ => seq($._group_open,
      field('body', alias($._destructuring_pattern, $.body)),
      optional(seq(':', field('type', $._expression))), $._group_end, ')'),
    // Share the grouped-pattern prefix until ')' or ',' decides its owner.
    // An early _pattern reduction can discard the real closer during recovery.
    _pattern_tuple: $ => seq($._group_open,
      field('element', choice(alias($._name_pattern, $.body),
        alias($._destructuring_pattern, $.body))), $._group_end, ',',
      commaSep1($._pattern), optional(seq(':', field('type', $._expression))), ')'),
    _pattern_list: $ => seq('[', optional(patternSep1($, $._pattern)), ']'),
    _pattern_cons: $ => prec.right(5, seq(field('left', $._pattern), field('operator', '<>'), field('right', $._pattern))),

    // Same expression syntax and precedence; only its header reductions differ.
    _header_expression: $ => choice($._atom, alias($._header_binary, $.binary_expression), $.lambda_expression),
    _header_binary: $ => binary($, $._header_expression, 0),
    _expression: $ => choice($._atom, $.binary_expression, $.lambda_expression),
    _domain_expression: $ => choice($._atom, alias($._domain_binary, $.binary_expression)),
    _generic_argument: $ => choice($._atom, alias($._generic_binary, $.binary_expression)),
    _write_value: $ => choice($._atom, alias($._write_binary, $.binary_expression)),
    _domain_binary: $ => binary($, $._domain_expression, 1),
    _generic_binary: $ => binary($, $._generic_argument, 5),
    _write_binary: $ => binary($, $._write_value, 2),
    _atom: $ => choice(
      $.identifier, $.builtin_type, $.kind_expression, $.quantity, $.integer,
      $._natural, $.float,
      $.natural_successor, $.character, $.string, $.hole, $.constructor_expression,
      $.type_application, alias($._glued_comparison, $.binary_expression),
      $.call_expression, $.index_expression, $.array_write,
      $.reusable_expression, $.dependent_type,
      $.annotation_expression, $.equality_expression, $.reflexivity, $.rewrite_expression,
      alias($._name_eliminator, $.eliminator), alias($._pattern_eliminator, $.eliminator),
      $.eliminator, $.parenthesized_expression, $.tuple_expression, $.list_expression,
      $.array_expression, $.do_expression,
    ),
    builtin_type: $ => choice('Type', 'Data', 'Quant'),
    kind_expression: $ => seq('Kind', '(', $._expression, ')'),
    quantity: $ => token(seq('&', /[012]/)),
    // parse_term_num consumes a full parse_term operand, including its atomic
    // postfix caller. Retain that caller through native infix recovery too.
    natural_successor: $ => prec.right(-1, choice(
      seq($._zero_successor_prefix, field('value', $._successor_value), optional($._natural_successor_end)),
      seq($._nonzero_successor_prefix, field('value', $._successor_value), optional($._natural_successor_end)))),
    // Summarize only a consumed full operand; -1 keeps every infix inside it.
    _successor_value: $ => prec.right(-1, $._header_expression),
    character: $ => seq("'", choice($.escape_sequence, token.immediate(prec(1, /[^\\]/u))), token.immediate("'")),
    string: $ => seq(alias($._string_start, '"'),
      repeat(choice($.escape_sequence, $.string_content, alias($._string_newline, $.string_content))), token.immediate('"')),
    string_content: $ => token.immediate(prec(1, /[^"\\\n]+/)),
    escape_sequence: $ => token.immediate(/\\([ntr0\\'"]|[uU]\{[0-9a-fA-F]{1,8}\})/),
    hole: $ => seq('?', field('name', $.identifier)),
    constructor_expression: $ => seq(field('name', $.identifier), token.immediate('{'),
      args($._expression, choice(',', $._pattern_separator)), '}'),
    // Glued comparisons and postfix operations bind to an atomic head. A
    // general expression here lets recovery consume a forbidden type operator
    // while waiting for another postfix token, then discard the declaration.
    _glued_comparison: $ => prec.left(4, seq(field('left', $._atom),
      field('operator', alias($._glued_lt, '<')), field('right', $._generic_argument), $._glued_comparison_end)),
    type_application: $ => seq(field('name', $.identifier), choice(alias($._lt, '<'), alias($._glued_lt, '<')),
      field('argument', $._generic_argument), choice($._type_close,
        seq(',', args(field('argument', $._expression)), $._type_close))),
    _type_close: $ => choice('>', alias($._gt, '>')),
    call_expression: $ => prec.left(14, seq(field('function', $._atom),
      field('arguments', $.arguments))),
    arguments: $ => seq(choice(alias($._call_open, '('), $.gpu_call),
      repeat(seq(field('argument', $.template_argument), optional(','))), args(field('argument', $._expression)), ')'),
    gpu_call: $ => seq(alias($._gpu_modifier, '!'), alias($._gpu_open, '(')),
    template_argument: $ => seq('~', $._expression),
    index_expression: $ => prec.left(14, seq(field('array', $._atom), alias($._index_open, '['), field('index', $._expression), ']')),
    array_write: $ => prec.right(1, seq(field('target', $.index_expression), '<-', field('value', $._write_value))),
    binary_expression: $ => binary($, $._expression, 0),
    reusable_expression: $ => prec(12, seq('+', $._expression)),
    lambda_expression: $ => prec.right(-2, seq(field('parameter', choice($.identifier, $.reusable_expression)), '=>', field('body', seq($._lambda_start, $._body_entry, choice(alias($._lambda_body, $.body), seq($.body, $._lambda_end)))))),
    dependent_type: $ => prec.right(0, seq(choice(seq(alias($._at, '@'), optional(choice('+', '-'))), '&'),
      field('name', $.identifier), ':', field('domain', $._domain_expression), '->', field('codomain', $._expression))),
    annotation_expression: $ => seq('{', field('value', $._expression), ':', field('type', $._expression), '}'),
    equality_expression: $ => seq('{', field('left', $._expression), choice('==', '!='),
      field('right', $._expression), ':', field('type', $._expression), '}'),
    reflexivity: $ => seq('{', '==', '}'),
    // Condense the consumed proof/colon before the motive, as for do headers.
    // Recovery can then retain the motive's actual atomic caller and arguments.
    _rewrite_prefix: $ => seq('%', optional(seq(field('name', $.identifier), alias($._at, '@'))),
      field('proof', $._expression), ':'),
    // Commit the consumed proof/colon before lexing its required motive.
    // Keep the separator in its caller so a rejected let can restart there.
    _rewrite_header: $ => seq($._rewrite_prefix, $._body_entry, field('motive', $._header_expression)),
    // Keep the pre-entry header above: an invalid separator has no block yet.
    // With no separator, summarize actual entry before the still-required value.
    _rewrite_body_header: $ => seq($._rewrite_header, $._block_start, $._body_entry),
    rewrite_expression: $ => prec.right(-2, choice(seq($._rewrite_body_header, field('body', $._block_value)),
      seq($._rewrite_header, ';', $._block_start, $._body_entry, field('body', $._block_value)))),
    eliminator: $ => seq('\\', '{', repeat($.eliminator_arm), optional(seq(field('fallback', $._expression), optional(';'))), '}'),
    eliminator_arm: $ => seq(field('name', $.identifier), ':', field('value', $._expression), optional(';')),
    parenthesized_expression: $ => seq($._group_open, field('body', $.body),
      optional(seq(':', field('type', $._expression))), $._group_end, ')'),
    tuple_expression: $ => seq($._group_open, field('element', $.body), $._group_end, ',',
      commaSep1($._expression), optional(seq(':', field('type', $._expression))), ')'),
    list_expression: $ => seq('[', args($._expression, choice(',', $._pattern_separator)), ']'),
    array_expression: $ => prec(12, choice(
      seq($._array_value_type, choice('*', '^'), field('size', $._expression), ']'),
      seq($._array_value_prefix, $._array_type, choice('*', '^'), field('size', $._expression), ']'))),
    _array_type: $ => choice(prec(1, seq(field('type', $._array_terminal_atom), $._array_type_end)), field('type', $._atom)),
    _array_value_prefix: $ => seq('[', field('value', $._expression), ':'),
    _array_value_type: $ => seq('[', field('value', $._expression), ':',
      choice(prec(1, seq(field('type', $._array_terminal_atom), $._array_type_end)), field('type', $._atom))),
    _array_terminal_atom: $ => choice($.identifier, $.builtin_type, $.kind_expression, $.quantity,
      $.integer, $._natural, $.float, $.character, $.string, $.hole,
      $.type_application, $.annotation_expression, $.equality_expression, $.reflexivity, $.eliminator,
      $.constructor_expression, $.parenthesized_expression, $.tuple_expression, $.list_expression, $.array_expression),
    // Reduce the header before entering its body so recovery need not search
    // through every header token to find an enclosing declaration.
    do_expression: $ => seq($._do_header, $._do_start, field('body', $.do_body), $._do_end),
    _do_header: $ => seq('do', field('monad', $.identifier), '<', args($._expression), '>', ':'),
    do_body: $ => choice($.do_binding, $.do_execution, $.do_step, $.return_expression, $._expression),
    do_binding: $ => prec.right(seq(field('name', choice($.identifier, $.reusable_expression)), ':',
      field('type', $._domain_expression), choice('=', '<-'), field('value', $._expression), optional(';'), field('body', $.do_body))),
    do_execution: $ => prec.right(seq(field('type', $._expression), '<-', field('value', $._expression), optional(';'), field('body', $.do_body))),
    do_step: $ => prec.right(seq(field('value', $._expression), choice(';', $._do_more), field('body', $.do_body))),
    return_expression: $ => seq('return', $._expression),
    comment: $ => token(seq('#', /[^\n]*/)),
  },
});

function commaSep1(rule) { return seq(rule, repeat(seq(',', rule))); }

// Optional commas do not turn same-line postfix calls or indexes into another
// pattern. The scanner recognizes the same term boundary as parse_term_ops.
function patternSep1($, rule) {
  return seq(rule, repeat(seq(choice(',', $._pattern_separator), rule)), optional(','));
}

function binary($, operand, minimum) {
  return choice(...[
    [0, '->', true], [1, choice('&', alias($._amp, '&')), true], [1, '|', true], [2, '||'], [3, '&&'],
    [4, alias($._lt, '<')], [4, '<='], [4, alias($._gt, '>')], [4, alias($._ge, '>=')],
    [5, '<>', true], [5, '++', true], [5, '<&>', true],
    [6, '.|.'], [7, '.^.'], [8, '.&.'], [9, '<<'], [9, alias($._shr, '>>')],
    [10, alias($._plus, '+')], [10, alias($._minus, '-')],
    [11, '*'], [11, '/'], [11, alias($._mod, '%')],
  ].filter(([p]) => p >= minimum).map(([p, op, right]) =>
    (right ? prec.right : prec.left)(p, seq(
      field('left', operand), field('operator', op), field('right', operand)))));
}
