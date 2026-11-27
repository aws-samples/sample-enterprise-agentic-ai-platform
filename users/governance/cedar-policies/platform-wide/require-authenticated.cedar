// Require Authentication Policy
// Forbid any unauthenticated access to gateway tools.
// All callers must present a valid JWT with the gateway scope.

forbid(
  principal,
  action,
  resource
)
unless {
  principal has "scope"
};
