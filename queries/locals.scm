; Syntactic scopes only: imports, dependent types and constructor resolution
; still require Bend's checker/LSP. Destructured patterns are conservative.
(source_file) @local.scope
[(function_definition) (law_definition) (type_definition) (lambda_expression)
 (case_clause) (let_expression) (parallel_let_expression) (do_binding)
 (dependent_type) (rewrite_expression)] @local.scope
(identifier) @local.reference
(parameter name: (identifier) @local.definition)
(type_parameter name: (identifier) @local.definition)
(law_clause name: (identifier) @local.definition)
(dependent_type name: (identifier) @local.definition)
(lambda_expression parameter: (identifier) @local.definition)
(lambda_expression parameter: (reusable_expression (identifier) @local.definition))
(lambda_expression parameter: (parenthesized_expression body: (body (identifier) @local.definition)))
(lambda_expression parameter: (parenthesized_expression body: (body (reusable_expression (identifier) @local.definition))))
(let_expression pattern: (binding (identifier) @local.definition))
(let_expression pattern: (binding (reusable_expression (identifier) @local.definition)))
(parallel_let_expression pattern: (binding (identifier) @local.definition))
(parallel_let_expression pattern: (binding (reusable_expression (identifier) @local.definition)))
(do_binding name: (identifier) @local.definition)
(do_binding name: (reusable_expression (identifier) @local.definition))
(case_clause pattern: (identifier) @local.definition)
(case_clause pattern: (reusable_expression (identifier) @local.definition))
(import_statement alias: (module_alias) @local.definition)
