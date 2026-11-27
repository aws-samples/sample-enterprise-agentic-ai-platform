// PII Tool Restriction — Only agents with pii_access scope can call PII-related tools

forbid(
  principal is AgentCore::OAuthUser,
  action == AgentCore::Action::\"CustomerDataAPI___get_customer_details\",
  resource
)
unless {
  principal.hasTag("scope") &&
  principal.getTag("scope") == "pii_access"
};
