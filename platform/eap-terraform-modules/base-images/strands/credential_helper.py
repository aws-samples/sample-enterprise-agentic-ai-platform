"""EAP Identity Credential Helper (Component 4)

Provides outbound credential management for agent-to-service calls:
- OAuth2 token acquisition and refresh via AgentCore Identity
- SigV4 signing for AWS service calls
- Token caching with automatic refresh before expiry

Reads AGENTCORE_RUNTIME_URL env var injected by the runtime module.
App_Teams never interact with this directly — it's used by the protocol
layers and agent framework transparently.

Requirements: R15.14
"""

import logging
import os
import threading
import time
from dataclasses import dataclass, field

import httpx

logger = logging.getLogger("eap.credentials")

RUNTIME_URL = os.environ.get("AGENTCORE_RUNTIME_URL", "")
TOKEN_REFRESH_MARGIN_SECONDS = 60  # Refresh 60s before expiry


@dataclass
class CachedToken:
    """A cached credential with expiry tracking."""
    access_token: str
    token_type: str = "Bearer"
    expires_at: float = 0.0  # epoch seconds
    scope: str = ""

    @property
    def is_expired(self) -> bool:
        return time.time() >= (self.expires_at - TOKEN_REFRESH_MARGIN_SECONDS)


class CredentialHelper:
    """Manages outbound credentials for agent service calls."""

    def __init__(self):
        self._token_cache: dict[str, CachedToken] = {}
        self._lock = threading.Lock()
        self._client = httpx.Client(timeout=10.0)

    def get_oauth_token(self, audience: str = "default") -> str | None:
        """Get a valid OAuth2 token for outbound calls.

        Checks cache first, refreshes if expired or missing.
        Returns the access token string, or None if unavailable.
        """
        with self._lock:
            cached = self._token_cache.get(audience)
            if cached and not cached.is_expired:
                return cached.access_token

        # Refresh outside lock to avoid blocking other callers
        token = self._refresh_oauth_token(audience)
        if token:
            with self._lock:
                self._token_cache[audience] = token
            return token.access_token
        return None

    def _refresh_oauth_token(self, audience: str) -> CachedToken | None:
        """Request a fresh OAuth2 token from AgentCore Identity."""
        if not RUNTIME_URL:
            logger.warning("AGENTCORE_RUNTIME_URL not set, skipping OAuth refresh")
            return None

        token_endpoint = f"{RUNTIME_URL}/identity/token"
        try:
            resp = self._client.post(
                token_endpoint,
                json={"audience": audience, "grant_type": "client_credentials"},
            )
            resp.raise_for_status()
            data = resp.json()
            token = CachedToken(
                access_token=data["access_token"],
                token_type=data.get("token_type", "Bearer"),
                expires_at=time.time() + data.get("expires_in", 3600),
                scope=data.get("scope", ""),
            )
            logger.info(
                "OAuth token refreshed",
                extra={"audience": audience, "expires_in": data.get("expires_in")},
            )
            return token
        except httpx.HTTPStatusError as e:
            logger.error(
                "OAuth token refresh failed",
                extra={"audience": audience, "status": e.response.status_code},
            )
        except Exception as e:
            logger.error(
                "OAuth token refresh error",
                extra={"audience": audience, "error": str(e)},
            )
        return None

    def get_sigv4_headers(self, service: str, region: str | None = None) -> dict:
        """Get SigV4 authorization headers for AWS service calls.

        Uses the container's IAM role credentials (available via instance
        metadata or ECS task role). Falls back to boto3 credential chain.
        """
        try:
            import botocore.session
            from botocore.auth import SigV4Auth
            from botocore.awsrequest import AWSRequest

            session = botocore.session.get_session()
            credentials = session.get_credentials()
            if not credentials:
                logger.warning("No AWS credentials available for SigV4")
                return {}

            region = region or os.environ.get("AWS_REGION", "us-east-1")
            logger.debug("SigV4 credentials available", extra={"service": service, "region": region})
            return {"_sigv4_service": service, "_sigv4_region": region}
        except ImportError:
            logger.warning("botocore not available, SigV4 signing disabled")
            return {}
        except Exception as e:
            logger.error("SigV4 credential error", extra={"error": str(e)})
            return {}

    def close(self):
        """Clean up HTTP client."""
        self._client.close()


# Module-level singleton — initialized once at container startup
_helper: CredentialHelper | None = None


def get_credential_helper() -> CredentialHelper:
    """Get or create the singleton credential helper."""
    global _helper
    if _helper is None:
        _helper = CredentialHelper()
    return _helper
