// Default Permit — Authenticated users can access all tools
// This is the base permit policy. Forbid policies override it.
// Without this, Cedar's default-deny means nothing works.

permit(
  principal is AgentCore::OAuthUser,
  action,
  resource
);
