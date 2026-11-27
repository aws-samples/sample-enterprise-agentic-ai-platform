"""EAP Structured Logging (Component 5)

JSON logger to stdout with automatic trace ID correlation.
Consistent field schema: timestamp, level, trace_id, span_id, agent_name, domain.
"""

import logging
import sys

from pythonjsonlogger import jsonlogger


class EAPJsonFormatter(jsonlogger.JsonFormatter):
    """Custom JSON formatter with platform fields."""

    def __init__(self, domain: str, agent_name: str, **kwargs):
        super().__init__(**kwargs)
        self.domain = domain
        self.agent_name = agent_name

    def add_fields(self, log_record, record, message_dict):
        super().add_fields(log_record, record, message_dict)
        log_record["domain"] = self.domain
        log_record["agent_name"] = self.agent_name
        log_record["level"] = record.levelname

        # OTel trace context correlation (if available)
        try:
            from opentelemetry import trace

            span = trace.get_current_span()
            ctx = span.get_span_context()
            if ctx.is_valid:
                log_record["trace_id"] = format(ctx.trace_id, "032x")
                log_record["span_id"] = format(ctx.span_id, "016x")
        except ImportError:
            pass


def setup_logging(log_level: str, domain: str, agent_name: str):
    """Configure structured JSON logging for the agent."""
    handler = logging.StreamHandler(sys.stdout)
    formatter = EAPJsonFormatter(
        domain=domain,
        agent_name=agent_name,
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
