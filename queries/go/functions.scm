;; function
(function_declaration
  name: (identifier) @name
  parameters: (parameter_list) @params
  result: (_) ? @return) @func

;; method
(method_declaration
  receiver: (parameter_list) @receiver
  name: (field_identifier) @name
  parameters: (parameter_list) @params
  result: (_) ? @return) @func

;; anonymous
(func_literal
  parameters: (parameter_list) @params
  result: (_) ? @return) @func

;; short assign
(short_var_declaration
  left: (expression_list (identifier) @name)
  right: (expression_list
    (func_literal
      parameters: (parameter_list) @params
      result: (_) ? @return))) @func

;; var assign
(var_spec
  name: (identifier) @name
  value: (expression_list
    (func_literal
      parameters: (parameter_list) @params
      result: (_) ? @return))) @func
