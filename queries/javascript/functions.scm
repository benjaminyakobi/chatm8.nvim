;; Function declaration
(function_declaration
  name: (identifier) @name
  parameters: (formal_parameters) @params) @func

;; Function expression (const f = function() {})
(function_expression
  name: (identifier)? @name
  parameters: (formal_parameters) @params) @func

;; Arrow function (const f = (a) => {})
(arrow_function
  parameters: (formal_parameters) @params) @func

;; Method in object or class
(method_definition
  name: (property_identifier) @name
  parameters: (formal_parameters) @params) @func

;; Variable assignment with function
(variable_declarator
  name: (identifier) @name
  value: [
    (function_expression
      parameters: (formal_parameters) @params)
    (arrow_function
      parameters: (formal_parameters) @params)
  ]) @func

;; Assignment expression: f = () => {}
(assignment_expression
  left: (identifier) @name
  right: [
    (function_expression
      parameters: (formal_parameters) @params)
    (arrow_function
      parameters: (formal_parameters) @params)
  ]) @func
