// Support Domain — Restrict high-value payments
// Support agents cannot process payments above threshold without manager scope.

forbid(
  principal is AgentCore::OAuthUser,
  action == AgentCore::Action::\"PaymentAPI___process_payment\",
  resource
)
when {
  principal.hasTag("domain") &&
  principal.getTag("domain") == "support" &&
  !(principal.hasTag("role") && principal.getTag("role") == "manager")
};
