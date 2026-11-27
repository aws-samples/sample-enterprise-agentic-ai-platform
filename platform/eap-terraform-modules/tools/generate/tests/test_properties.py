"""Property-based tests for eap-generate (CP-13 through CP-22).

Each test uses Hypothesis with minimum 100 iterations per the testing strategy.
"""

import re
import tempfile
from pathlib import Path

from hypothesis import given, settings

from tests.strategies import invalid_yaml_data, valid_yaml_data
from eap_generate.formatter import format_yaml
from eap_generate.parser import dump_string, parse_string
from eap_generate.renderer import render
from eap_generate.resolver import resolve
from eap_generate.schema import validate, validate_agent_refs


# ---------------------------------------------------------------------------
# CP-13: Schema Validation Completeness
# Valid YAML passes, invalid YAML fails with field path.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp13_valid_passes(data):
    errors = validate(data)
    assert errors == [], f"Valid YAML should pass: {errors}"


@settings(max_examples=100)
@given(data=invalid_yaml_data())
def test_cp13_invalid_fails(data):
    errors = validate(data)
    assert len(errors) > 0, "Invalid YAML should fail validation"
    for err in errors:
        assert err.field_path, "Error must have a field_path"
        assert err.message, "Error must have a message"


# ---------------------------------------------------------------------------
# CP-14: YAML Parse–Format Round Trip
# parse → format → parse produces semantically equivalent object.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp14_round_trip(data):
    yaml_str = dump_string(data)
    parsed = parse_string(yaml_str)
    formatted = format_yaml(parsed)
    reparsed = parse_string(formatted)
    assert parsed == reparsed, "Round-trip should produce equivalent object"


# ---------------------------------------------------------------------------
# CP-15: Module Block Completeness
# N agents → N runtimes, N Cognito clients, correct optional module counts.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp15_module_block_completeness(data):
    resolved = resolve(data)
    rendered = render(data, resolved)
    hcl = rendered.main_tf
    agents = data["agents"]
    n = len(agents)

    # N runtime modules
    runtime_count = len(re.findall(r'module "runtime_\w+"', hcl))
    assert runtime_count == n, f"Expected {n} runtime modules, got {runtime_count}"

    # N Cognito clients
    cognito_count = len(re.findall(r'resource "aws_cognito_user_pool_client" "\w+"', hcl))
    assert cognito_count == n, f"Expected {n} Cognito clients, got {cognito_count}"

    # Memory modules = agents with memory config
    memory_expected = sum(1 for a in agents.values() if a.get("memory"))
    memory_count = len(re.findall(r'module "memory_\w+"', hcl))
    assert memory_count == memory_expected, f"Expected {memory_expected} memory modules, got {memory_count}"

    # Evaluations modules = agents with evaluations config
    eval_expected = sum(1 for a in agents.values() if a.get("evaluations"))
    eval_count = len(re.findall(r'module "evaluations_\w+"', hcl))
    assert eval_count == eval_expected, f"Expected {eval_expected} evaluations modules, got {eval_count}"

    # Outputs: 3 per agent (id, arn, endpoint_arn)
    outputs_hcl = rendered.outputs_tf
    output_count = len(re.findall(r'output "\w+"', outputs_hcl))
    assert output_count == 3 * n, f"Expected {3 * n} outputs, got {output_count}"


# ---------------------------------------------------------------------------
# CP-16: A2A Wiring Correctness
# calls/allowed_callers produce correct Cognito client wiring.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data(min_agents=2, max_agents=4))
def test_cp16_a2a_wiring(data):
    resolved = resolve(data)
    rendered = render(data, resolved)
    hcl = rendered.main_tf

    for name, block in data["agents"].items():
        # If agent has allowed_callers, those client IDs should be in allowed_callers
        for caller in block.get("allowed_callers", []):
            expected_ref = f"aws_cognito_user_pool_client.{caller}.id"
            agent_section = _extract_runtime_block(hcl, name)
            if agent_section:
                assert expected_ref in agent_section, (
                    f"Agent {name} should have {caller}'s client ID in allowed_callers"
                )

        # If agent calls others, callee endpoint ARNs should be in env vars
        for callee in block.get("calls", []):
            env_key = f"{callee.upper()}_A2A_ENDPOINT"
            agent_section = _extract_runtime_block(hcl, name)
            if agent_section:
                assert env_key in agent_section, (
                    f"Agent {name} should have {env_key} env var for callee {callee}"
                )


def _extract_runtime_block(hcl: str, agent_name: str) -> str | None:
    """Extract the runtime module block for a given agent from HCL text."""
    pattern = rf'module "runtime_{agent_name}"'
    start = hcl.find(pattern)
    if start == -1:
        return None
    # Find the matching closing brace
    depth = 0
    for i in range(start, len(hcl)):
        if hcl[i] == "{":
            depth += 1
        elif hcl[i] == "}":
            depth -= 1
            if depth == 0:
                return hcl[start : i + 1]
    return hcl[start:]


# ---------------------------------------------------------------------------
# CP-17: HCL Output Correctness
# Generated HCL uses git source refs, includes required inputs and tags.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp17_hcl_correctness(data):
    resolved = resolve(data)
    rendered = render(data, resolved)

    # Uses git source format
    assert "git::" in rendered.main_tf, "Module source should use git:: format"

    # Includes required tags
    assert 'managed_by = "eap-generate"' in rendered.main_tf
    assert f'domain     = "{data["domain"]}"' in rendered.main_tf

    # versions.tf has correct provider constraint
    assert ">= 6.37.0" in rendered.versions_tf
    assert ">= 1.5" in rendered.versions_tf

    # variables.tf has required variables
    for var_name in ["aws_region", "ecr_repo_url", "cognito_user_pool_id", "cognito_token_endpoint"]:
        assert f'variable "{var_name}"' in rendered.variables_tf, f"Missing variable {var_name}"


# ---------------------------------------------------------------------------
# CP-18: Deterministic Generation
# Same input produces byte-identical output.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp18_deterministic(data):
    resolved1 = resolve(data)
    rendered1 = render(data, resolved1)

    resolved2 = resolve(data)
    rendered2 = render(data, resolved2)

    assert rendered1.main_tf == rendered2.main_tf, "main.tf should be identical"
    assert rendered1.variables_tf == rendered2.variables_tf, "variables.tf should be identical"
    assert rendered1.versions_tf == rendered2.versions_tf, "versions.tf should be identical"
    assert rendered1.outputs_tf == rendered2.outputs_tf, "outputs.tf should be identical"


# ---------------------------------------------------------------------------
# CP-19: Dependency Ordering
# Callees appear before callers in generated HCL.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data(min_agents=2, max_agents=4))
def test_cp19_dependency_ordering(data):
    resolved = resolve(data)
    rendered = render(data, resolved)
    hcl = rendered.main_tf

    # Skip ordering check for agents involved in cycles
    cyclic_agents: set[str] = set()
    for w in resolved.warnings:
        if "Cyclic" in w:
            # Extract agent names from cycle warning
            import re
            names_in_warning = re.findall(r"[a-z][a-z0-9_]+", w.split(":")[-1])
            cyclic_agents.update(names_in_warning)

    for name, block in data["agents"].items():
        if name in cyclic_agents:
            continue
        for callee in block.get("calls", []):
            if callee in cyclic_agents:
                continue
            caller_pos = hcl.find(f'module "runtime_{name}"')
            callee_pos = hcl.find(f'module "runtime_{callee}"')
            if caller_pos != -1 and callee_pos != -1:
                assert callee_pos < caller_pos, (
                    f"Callee {callee} should appear before caller {name} in HCL"
                )


# ---------------------------------------------------------------------------
# CP-20: Error Exit Codes
# Valid YAML → 0, invalid → 1, I/O error → 2.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data())
def test_cp20_valid_exit_zero(data):
    """Valid YAML should produce exit code 0 (no errors)."""
    errors = validate(data)
    ref_errors = validate_agent_refs(data)
    assert len(errors) == 0, "Valid YAML should have no schema errors"
    assert len(ref_errors) == 0, "Valid YAML should have no ref errors"


@settings(max_examples=100)
@given(data=invalid_yaml_data())
def test_cp20_invalid_exit_one(data):
    """Invalid YAML should produce validation errors (exit code 1)."""
    errors = validate(data)
    assert len(errors) > 0, "Invalid YAML should have schema errors"


def test_cp20_missing_file_exit_two():
    """Missing input file should raise FileNotFoundError (exit code 2)."""
    from eap_generate.parser import parse_file

    try:
        parse_file("/nonexistent/agent.yaml")
        assert False, "Should have raised FileNotFoundError"
    except FileNotFoundError:
        pass  # Expected — CLI maps this to exit code 2


# ---------------------------------------------------------------------------
# CP-21: Asymmetric Relationship Warning
# A calls B but B doesn't list A in allowed_callers → warning.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data(min_agents=2, max_agents=3))
def test_cp21_asymmetric_warning(data):
    agents = data["agents"]
    names = list(agents.keys())

    # Create an asymmetric relationship: first agent calls second,
    # but second doesn't list first in allowed_callers
    if len(names) >= 2:
        caller, callee = names[0], names[1]
        agents[caller]["calls"] = [callee]
        agents[callee]["allowed_callers"] = []  # Asymmetric — doesn't allow caller

        resolved = resolve(data)
        has_asymmetric_warning = any("does not list" in w for w in resolved.warnings)
        assert has_asymmetric_warning, (
            f"Should warn about asymmetric relationship: {caller} calls {callee}"
        )


# ---------------------------------------------------------------------------
# CP-22: Cycle Tolerance
# Cyclic A2A relationships produce warning + valid HCL.
# ---------------------------------------------------------------------------
@settings(max_examples=100)
@given(data=valid_yaml_data(min_agents=2, max_agents=3))
def test_cp22_cycle_tolerance(data):
    agents = data["agents"]
    names = list(agents.keys())

    if len(names) >= 2:
        a, b = names[0], names[1]
        # Create a cycle: A calls B, B calls A
        agents[a]["calls"] = [b]
        agents[a]["allowed_callers"] = [b]
        agents[b]["calls"] = [a]
        agents[b]["allowed_callers"] = [a]

        resolved = resolve(data)

        # Should have a cycle warning
        has_cycle_warning = any("Cyclic" in w for w in resolved.warnings)
        assert has_cycle_warning, "Should warn about cyclic A2A relationship"

        # Should still produce valid HCL
        rendered = render(data, resolved)
        assert rendered.main_tf, "Should still generate main.tf despite cycle"
        assert f'module "runtime_{a}"' in rendered.main_tf
        assert f'module "runtime_{b}"' in rendered.main_tf
