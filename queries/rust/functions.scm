;; Function
(function_item
  (visibility_modifier)? @visibility
  name: (identifier) @name
  parameters: (parameters) @params
  return_type: (_)? @return) @func

;; Closure
(closure_expression
  parameters: (closure_parameters)? @params) @func
