;; Function definitions with optional return type
(function_definition
  name: (identifier) @name
  parameters: (parameters) @params
  return_type: (type)? @return) @func

;; Methods inside classes (same node type, but still useful to capture)
(function_definition
  name: (identifier) @name
  parameters: (parameters) @params
  return_type: (type)? @return) @func

;; Lambda (anonymous function)
(lambda
  parameters: (lambda_parameters)? @params) @func

;; Assigned lambda: f = lambda x: x + 1
(assignment
  left: (identifier) @name
  right: (lambda
    parameters: (lambda_parameters)? @params)) @func
