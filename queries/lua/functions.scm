;; Named functions
(function_declaration
  name: (_) @name
  parameters: (parameters) @params) @func

;; Anonymous
(function_definition
  parameters: (parameters) @params) @func

;; local foo = function() end
(variable_declaration
  (assignment_statement
    (variable_list (identifier) @name)
    (expression_list
      (function_definition
        parameters: (parameters) @params)))) @func

;; foo = function() end
(assignment_statement
  (variable_list (identifier) @name)
  (expression_list
    (function_definition
      parameters: (parameters) @params))) @func
