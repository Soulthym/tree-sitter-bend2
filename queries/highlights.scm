; General names first; structural roles below override them.
(identifier) @variable
((identifier) @type
  (#match? @type "^[A-Z]"))
(comment) @comment
(string) @string
(character) @character
(escape_sequence) @string.escape
(integer) @number
(natural) @number
(float) @number.float
(quantity) @constant.builtin
(builtin_type) @type.builtin
"Kind" @type.builtin
(hole) @variable.builtin
(reflexivity) @constant.builtin

(function_definition name: (identifier) @function)
(law_definition name: (identifier) @function)
(type_definition name: (identifier) @type.definition)
(constructor_definition name: (identifier) @constructor)
(constructor_expression name: (identifier) @constructor)
(eliminator_arm name: (identifier) @constructor)
(type_application name: (identifier) @type)
(call_expression function: (identifier) @function.call)
(do_expression monad: (identifier) @type)
(parameter name: (identifier) @variable.parameter)
(type_parameter name: (identifier) @variable.parameter)
(constructor_definition (type_parameter name: (identifier) @variable.member))
(law_clause name: (identifier) @variable.parameter)
(dependent_type name: (identifier) @variable.parameter)
(lambda_expression parameter: (identifier) @variable.parameter)
(lambda_expression parameter: (reusable_expression (identifier) @variable.parameter))
(lambda_expression parameter: (parenthesized_expression body: (body (identifier) @variable.parameter)))
(lambda_expression parameter: (parenthesized_expression body: (body (reusable_expression (identifier) @variable.parameter))))
(do_binding name: (identifier) @variable)
(import_statement alias: (module_alias) @module)
(import_path) @string.special.path
(foreign_import path: (string) @string.special.path)
(decorator) @attribute
(function_definition "?" @attribute)
(gpu_call "!" @keyword.modifier)

["def" "type" "law" "is" "where" "for" "exs" "do"] @keyword
["match" "case"] @keyword.conditional
"return" @keyword.return
["import" "as"] @keyword.import
"Base" @module
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" ":"] @punctuation.delimiter
["->" "=>" "<-" "=" "==" "!=" "@" "\\" "~"
 "+" "-" "*" "/" "%" "<" ">" "<=" ">=" "<<" ">>"
 "&" "|" "&&" "||" "<>" "++" "<&>" ".&." ".|." ".^." "^"] @operator
