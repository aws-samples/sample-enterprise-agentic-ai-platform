import { describe, it, expect } from 'vitest';
import {
  resolveBackends,
  AWS_NATIVE_EXPORTER_NAMES,
  type ResolveBackendsOptions,
} from './backendConfig';
import type { BackendConfiguration, ThirdPartyBackend } from './types';

const LANGFUSE_ENDPOINT = 'https://langfuse.internal/api/public/otel';

const options: ResolveBackendsOptions = {
  defaultLangfuseEndpoint: LANGFUSE_ENDPOINT,
  defaultLangfuseAuthSecretArn: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:langfuse',
};

function backend(overrides: Partial<ThirdPartyBackend> = {}): ThirdPartyBackend {
  return {
    name: 'fiddler',
    otlpEndpoint: 'https://fiddler.example/otlp',
    authSecretArn: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:fiddler',
    mode: 'add',
    enabled: true,
    ...overrides,
  };
}

function config(thirdParty: ThirdPartyBackend[]): BackendConfiguration {
  return { thirdParty };
}

/** Asserts no resolved exporter is an AWS-native exporter. */
function expectNoAwsNative(exporters: ReturnType<typeof resolveBackends>): void {
  for (const e of exporters) {
    expect(e.kind).toBe('otlphttp');
    expect(AWS_NATIVE_EXPORTER_NAMES).not.toContain(e.name as never);
  }
}

describe('resolveBackends', () => {
  it('resolves an empty config to the default Langfuse exporter only (R16.4)', () => {
    const result = resolveBackends(config([]), options);
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('langfuse');
    expect(result[0].otlpEndpoint).toBe(LANGFUSE_ENDPOINT);
    expect(result[0].kind).toBe('otlphttp');
    expectNoAwsNative(result);
  });

  it('resolves null/undefined/malformed config to Langfuse only (total function)', () => {
    for (const input of [null, undefined, {} as BackendConfiguration, { thirdParty: null } as unknown as BackendConfiguration]) {
      const result = resolveBackends(input, options);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('langfuse');
      expect(result[0].otlpEndpoint).toBe(LANGFUSE_ENDPOINT);
    }
  });

  it('treats all-disabled backends as absent → Langfuse only (respects enabled)', () => {
    const result = resolveBackends(
      config([
        backend({ name: 'fiddler', mode: 'replace', enabled: false }),
        backend({ name: 'datadog', mode: 'add', enabled: false }),
      ]),
      options,
    );
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('langfuse');
  });

  it('mode="replace" resolves to the alternate in place of Langfuse (R16.3)', () => {
    const result = resolveBackends(
      config([backend({ name: 'datadog', otlpEndpoint: 'https://dd.example/otlp', mode: 'replace' })]),
      options,
    );
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('datadog');
    expect(result[0].otlpEndpoint).toBe('https://dd.example/otlp');
    expect(result.some((e) => e.name === 'langfuse')).toBe(false);
    expectNoAwsNative(result);
  });

  it('mode="add" resolves to Langfuse PLUS the alternate (R16.3)', () => {
    const result = resolveBackends(
      config([backend({ name: 'fiddler', otlpEndpoint: 'https://fiddler.example/otlp', mode: 'add' })]),
      options,
    );
    expect(result).toHaveLength(2);
    expect(result[0].name).toBe('langfuse');
    expect(result[1].name).toBe('fiddler');
    expect(result[1].otlpEndpoint).toBe('https://fiddler.example/otlp');
    expectNoAwsNative(result);
  });

  it('each resolved exporter endpoint equals exactly its configured endpoint (R16.2)', () => {
    const endpoint = 'https://custom.example:4318/v1/traces';
    const result = resolveBackends(config([backend({ otlpEndpoint: endpoint, mode: 'add' })]), options);
    const fiddler = result.find((e) => e.name === 'fiddler');
    expect(fiddler?.otlpEndpoint).toBe(endpoint);
  });

  it('drops Langfuse when any enabled backend replaces it, keeping all enabled alternates', () => {
    const result = resolveBackends(
      config([
        backend({ name: 'fiddler', mode: 'replace' }),
        backend({ name: 'datadog', otlpEndpoint: 'https://dd.example/otlp', mode: 'add' }),
      ]),
      options,
    );
    expect(result.some((e) => e.name === 'langfuse')).toBe(false);
    expect(result.map((e) => e.name).sort()).toEqual(['datadog', 'fiddler']);
    expectNoAwsNative(result);
  });

  it('carries authSecretArn through when present and omits it when empty', () => {
    const withAuth = resolveBackends(
      config([backend({ authSecretArn: 'arn:aws:secretsmanager:us-east-1:1:secret:x', mode: 'add' })]),
      options,
    );
    expect(withAuth.find((e) => e.name === 'fiddler')?.authSecretArn).toBe(
      'arn:aws:secretsmanager:us-east-1:1:secret:x',
    );

    const noAuth = resolveBackends(config([backend({ authSecretArn: '', mode: 'add' })]), options);
    expect(noAuth.find((e) => e.name === 'fiddler')).not.toHaveProperty('authSecretArn');
  });

  it('never produces an AWS-native exporter for any mode', () => {
    for (const mode of ['add', 'replace'] as const) {
      const result = resolveBackends(config([backend({ mode })]), options);
      expectNoAwsNative(result);
    }
  });

  it('uses the injected default endpoint rather than a hardcoded value', () => {
    const alt = resolveBackends(config([]), {
      defaultLangfuseEndpoint: 'https://other-langfuse.internal/otel',
    });
    expect(alt[0].otlpEndpoint).toBe('https://other-langfuse.internal/otel');
    expect(alt[0].authSecretArn).toBeUndefined();
  });
});
