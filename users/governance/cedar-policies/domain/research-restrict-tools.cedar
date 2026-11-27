// Research Domain — Tool Restriction Policy
// Agents in the research domain can only access approved tools.
// Prevents research agents from calling payment tools.

forbid(
  principal is AgentCore::OAuthUser,
  action == AgentCore::Action::\"PaymentAPI___process_payment\",
  resource
)
when {
  principal.hasTag("domain") &&
  principal.getTag("domain") == "research"
};
