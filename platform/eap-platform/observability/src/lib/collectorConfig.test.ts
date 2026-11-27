import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import {
  renderCollectorConfig,
  toYaml,
  AWS_NATIVE_EXPORTER_NAMES,
  AWS_NATIVE_PIPELINE_NAMES,
  BU_ROUTING_RESOURCE_ATTRIBUTE,
  type RenderCollectorConfigOptions,
} from './collectorConfig';
import type { BackendConfiguration, LangfuseProjectBinding, ThirdPartyBackend } from './types';

const LANGFUSE_ENDPOINT = 'https://langfuse.internal/api/public/otel';

const options: RenderCollectorConfigOptions = {
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

/** All exporter keys in the rendered config are `otlphttp/*` (never AWS-native). */
function expectNoAwsNativeExporters(rendered: ReturnType<typeof renderCollectorConfig>): void {
  const keys = Object.keys(rendered.config.exporters);
  for (const key of keys) {
    expect(key.startsWith('otlphttp/')).toBe(true);
    for (const aws of AWS_NATIVE_EXPORTER_NAMES) {
      expect(key.includes(aws)).toBe(false);
    }
  }
}

/** No AWS-native pipeline appears in the rendered service.pipelines. */
function expectNoAwsNativePipelines(rendered: ReturnType<typeof renderCollectorConfig>): void {
  const pipelines = Object.keys(rendered.config.service.pipelines);
  for (const aws of AWS_NATIVE_PIPELINE_NAMES) {
    expect(pipelines).not.toContain(aws);
  }
  // The only pipeline is the third-party one.
  expect(pipelines).toEqual(['traces/thirdparty']);
}

describe('renderCollectorConfig — third-party leg only (task 7.3)', () => {
  it('renders an OTLP receiver (grpc + http) plus the default Langfuse pipeline for empty config', () => {
    const rendered = renderCollectorConfig(config([]), options);

    expect(rendered.config.receivers.otlp.protocols.grpc.endpoint).toBe('0.0.0.0:4317');
    expect(rendered.config.receivers.otlp.protocols.http.endpoint).toBe('0.0.0.0:4318');

    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse']);
    expect(rendered.config.exporters['otlphttp/langfuse'].endpoint).toBe(LANGFUSE_ENDPOINT);
    expect(rendered.config.service.pipelines['traces/thirdparty']).toEqual({
      receivers: ['otlp'],
      processors: ['batch'],
      exporters: ['otlphttp/langfuse'],
    });

    expectNoAwsNativeExporters(rendered);
    expectNoAwsNativePipelines(rendered);
  });

  it('is total for null/undefined/malformed config → default Langfuse only', () => {
    for (const input of [
      null,
      undefined,
      {} as BackendConfiguration,
      { thirdParty: null } as unknown as BackendConfiguration,
    ]) {
      const rendered = renderCollectorConfig(input, options);
      expect(rendered.exporterNames).toEqual(['otlphttp/langfuse']);
      expectNoAwsNativeExporters(rendered);
      expectNoAwsNativePipelines(rendered);
    }
  });

  it('mode="replace" renders the alternate in place of Langfuse', () => {
    const rendered = renderCollectorConfig(
      config([backend({ name: 'datadog', otlpEndpoint: 'https://dd.example/otlp', mode: 'replace' })]),
      options,
    );
    expect(rendered.exporterNames).toEqual(['otlphttp/datadog']);
    expect(rendered.config.exporters['otlphttp/datadog'].endpoint).toBe('https://dd.example/otlp');
    expect(rendered.config.exporters['otlphttp/langfuse']).toBeUndefined();
    expectNoAwsNativeExporters(rendered);
  });

  it('mode="add" renders Langfuse PLUS the alternate, wired into one pipeline', () => {
    const rendered = renderCollectorConfig(
      config([backend({ name: 'fiddler', otlpEndpoint: 'https://fiddler.example/otlp', mode: 'add' })]),
      options,
    );
    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse', 'otlphttp/fiddler']);
    expect(rendered.config.service.pipelines['traces/thirdparty'].exporters).toEqual([
      'otlphttp/langfuse',
      'otlphttp/fiddler',
    ]);
    expectNoAwsNativeExporters(rendered);
  });

  it('gives each exporter a UNIQUE otlphttp key even on name collisions', () => {
    const rendered = renderCollectorConfig(
      config([
        backend({ name: 'fiddler', otlpEndpoint: 'https://a.example/otlp', mode: 'add' }),
        backend({ name: 'fiddler', otlpEndpoint: 'https://b.example/otlp', mode: 'add' }),
      ]),
      options,
    );
    const keys = Object.keys(rendered.config.exporters);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toContain('otlphttp/fiddler');
    expect(keys).toContain('otlphttp/fiddler-2');
  });

  it('endpoint of each rendered exporter equals exactly its configured endpoint', () => {
    const endpoint = 'https://custom.example:4318/v1/traces';
    const rendered = renderCollectorConfig(config([backend({ otlpEndpoint: endpoint, mode: 'add' })]), options);
    expect(rendered.config.exporters['otlphttp/fiddler'].endpoint).toBe(endpoint);
  });

  it('honors injected receiver/queue tuning options', () => {
    const rendered = renderCollectorConfig(config([]), {
      ...options,
      otlpGrpcEndpoint: '127.0.0.1:5317',
      otlpHttpEndpoint: '127.0.0.1:5318',
      sendingQueueSize: 42,
      retryMaxElapsedTime: '120s',
    });
    expect(rendered.config.receivers.otlp.protocols.grpc.endpoint).toBe('127.0.0.1:5317');
    expect(rendered.config.receivers.otlp.protocols.http.endpoint).toBe('127.0.0.1:5318');
    const exp = rendered.config.exporters['otlphttp/langfuse'];
    expect(exp.sending_queue.queue_size).toBe(42);
    expect(exp.retry_on_failure.max_elapsed_time).toBe('120s');
  });
});

describe('renderCollectorConfig — per-exporter failure isolation (task 7.6)', () => {
  it('every third-party exporter has its own non-blocking sending_queue + retry_on_failure', () => {
    const rendered = renderCollectorConfig(
      config([
        backend({ name: 'fiddler', otlpEndpoint: 'https://fiddler.example/otlp', mode: 'add' }),
        backend({ name: 'datadog', otlpEndpoint: 'https://dd.example/otlp', mode: 'add' }),
      ]),
      options,
    );
    const exporters = Object.values(rendered.config.exporters);
    expect(exporters.length).toBe(3); // langfuse + fiddler + datadog
    for (const exp of exporters) {
      expect(exp.sending_queue.enabled).toBe(true);
      expect(exp.sending_queue.blocking).toBe(false);
      expect(typeof exp.sending_queue.queue_size).toBe('number');
      expect(exp.retry_on_failure.enabled).toBe(true);
      expect(typeof exp.retry_on_failure.max_elapsed_time).toBe('string');
    }
  });

  it('adds an Authorization header seam only when the backend declares an auth secret', () => {
    const withAuth = renderCollectorConfig(
      config([backend({ name: 'fiddler', authSecretArn: 'arn:aws:secretsmanager:us-east-1:1:secret:x', mode: 'replace' })]),
      { defaultLangfuseEndpoint: LANGFUSE_ENDPOINT },
    );
    expect(withAuth.config.exporters['otlphttp/fiddler'].headers).toEqual({
      Authorization: '${env:EAP_OTLP_AUTH_FIDDLER}',
    });

    const noAuth = renderCollectorConfig(
      config([backend({ name: 'fiddler', authSecretArn: '', mode: 'replace' })]),
      { defaultLangfuseEndpoint: LANGFUSE_ENDPOINT },
    );
    expect(noAuth.config.exporters['otlphttp/fiddler'].headers).toBeUndefined();
  });
});

describe('renderCollectorConfig — per-BU Langfuse routing (task 10.4)', () => {
  const LANGFUSE_OTEL = 'https://langfuse.internal/api/public/otel';

  function lfBinding(overrides: Partial<LangfuseProjectBinding> = {}): LangfuseProjectBinding {
    return {
      bu: 'team-bu-1',
      projectId: 'proj-team-bu-1',
      publicKeyRef: 'arn:aws:secretsmanager:us-east-1:1:secret:pk-team-bu-1',
      secretKeyRef: 'arn:aws:secretsmanager:us-east-1:1:secret:sk-team-bu-1',
      otlpBasicAuthRef: 'arn:aws:secretsmanager:us-east-1:1:secret:auth-team-bu-1',
      ...overrides,
    };
  }

  const bindings: LangfuseProjectBinding[] = [
    lfBinding({ bu: 'team-bu-1' }),
    lfBinding({ bu: 'team-bu-2', projectId: 'proj-team-bu-2', otlpBasicAuthRef: 'auth-2' }),
  ];

  const routingOptions: RenderCollectorConfigOptions = {
    ...options,
    langfuseProjectBindings: bindings,
    langfuseOtelEndpoint: LANGFUSE_OTEL,
  };

  it('emits one otlphttp/langfuse-<bu> exporter per BU, all pointed at the shared endpoint', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);

    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse-team-bu-1', 'otlphttp/langfuse-team-bu-2']);
    for (const key of rendered.exporterNames) {
      expect(rendered.config.exporters[key].endpoint).toBe(LANGFUSE_OTEL);
    }
    expectNoAwsNativeExporters(rendered);
  });

  it('derives a per-BU Basic-auth ${env:...} header seam per project', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);
    expect(rendered.config.exporters['otlphttp/langfuse-team-bu-1'].headers).toEqual({
      Authorization: 'Basic ${env:EAP_OTLP_AUTH_LANGFUSE_TEAM_BU_1}',
    });
    expect(rendered.config.exporters['otlphttp/langfuse-team-bu-2'].headers).toEqual({
      Authorization: 'Basic ${env:EAP_OTLP_AUTH_LANGFUSE_TEAM_BU_2}',
    });
  });

  it('gives every per-BU exporter its OWN non-blocking sending_queue + retry_on_failure (task 7.6 pattern)', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);
    for (const key of rendered.exporterNames) {
      const exp = rendered.config.exporters[key];
      expect(exp.sending_queue.enabled).toBe(true);
      expect(exp.sending_queue.blocking).toBe(false);
      expect(exp.retry_on_failure.enabled).toBe(true);
    }
  });

  it('emits a routing connector keyed on the deployment.environment resource attribute', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);
    const routing = rendered.config.connectors?.routing;
    expect(routing).toBeDefined();
    expect(BU_ROUTING_RESOURCE_ATTRIBUTE).toBe('deployment.environment');
    expect(routing!.table).toEqual([
      {
        context: 'resource',
        condition: 'attributes["deployment.environment"] == "team-bu-1"',
        pipelines: ['traces/langfuse-team-bu-1'],
      },
      {
        context: 'resource',
        condition: 'attributes["deployment.environment"] == "team-bu-2"',
        pipelines: ['traces/langfuse-team-bu-2'],
      },
    ]);
  });

  it('wires traces/thirdparty (otlp→batch→routing) and one traces/langfuse-<bu> pipeline per BU', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);
    const pipelines = rendered.config.service.pipelines;

    expect(pipelines['traces/thirdparty']).toEqual({
      receivers: ['otlp'],
      processors: ['batch'],
      exporters: ['routing'],
    });
    expect(pipelines['traces/langfuse-team-bu-1']).toEqual({
      receivers: ['routing'],
      exporters: ['otlphttp/langfuse-team-bu-1'],
    });
    expect(pipelines['traces/langfuse-team-bu-2']).toEqual({
      receivers: ['routing'],
      exporters: ['otlphttp/langfuse-team-bu-2'],
    });
  });

  it('contains ZERO AWS-native exporters/pipelines in the per-BU branch (Properties 11 & 17)', () => {
    const rendered = renderCollectorConfig(config([]), routingOptions);
    const exporterKeys = Object.keys(rendered.config.exporters);
    const pipelineKeys = Object.keys(rendered.config.service.pipelines);
    for (const aws of AWS_NATIVE_EXPORTER_NAMES) {
      expect(exporterKeys.some((k) => k.includes(aws))).toBe(false);
      expect(rendered.yaml).not.toContain(aws);
    }
    for (const aws of AWS_NATIVE_PIPELINE_NAMES) {
      expect(pipelineKeys).not.toContain(aws);
      expect(rendered.yaml).not.toContain(aws);
    }
    // Every exporter is a third-party otlphttp exporter.
    for (const key of exporterKeys) {
      expect(key.startsWith('otlphttp/')).toBe(true);
    }
  });

  it('drops ambiguous duplicate-BU bindings (fail closed — never cross-routed)', () => {
    const dup = [
      lfBinding({ bu: 'team-bu-1', projectId: 'p1a', otlpBasicAuthRef: 'a1a' }),
      lfBinding({ bu: 'team-bu-1', projectId: 'p1b', otlpBasicAuthRef: 'a1b' }),
      lfBinding({ bu: 'team-bu-2', projectId: 'p2' }),
    ];
    const rendered = renderCollectorConfig(config([]), {
      ...options,
      langfuseProjectBindings: dup,
      langfuseOtelEndpoint: LANGFUSE_OTEL,
    });
    // team-bu-1 is ambiguous → dropped; only team-bu-2 routes.
    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse-team-bu-2']);
  });

  it('falls back to the default single pipeline when no binding resolves (endpoint missing)', () => {
    const rendered = renderCollectorConfig(config([]), {
      ...options,
      langfuseProjectBindings: bindings,
      // No langfuseOtelEndpoint → per-BU routes cannot resolve.
    });
    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse']);
    expect(rendered.config.connectors).toBeUndefined();
    expect(Object.keys(rendered.config.service.pipelines)).toEqual(['traces/thirdparty']);
  });

  it('is backward compatible: no bindings → unchanged single default pipeline (no connectors)', () => {
    const rendered = renderCollectorConfig(config([]), options);
    expect(rendered.config.connectors).toBeUndefined();
    expect(rendered.exporterNames).toEqual(['otlphttp/langfuse']);
    expect(Object.keys(rendered.config.service.pipelines)).toEqual(['traces/thirdparty']);
  });

  it('serializes the routing connector + per-BU pipelines to deterministic YAML', () => {
    const a = renderCollectorConfig(config([]), routingOptions).yaml;
    const b = renderCollectorConfig(config([]), routingOptions).yaml;
    expect(a).toBe(b);
    expect(a).toContain('connectors:');
    expect(a).toContain('routing:');
    expect(a).toContain('traces/langfuse-team-bu-1:');
    expect(a).toContain('otlphttp/langfuse-team-bu-1:');
    // The OTTL condition round-trips through the quoted-scalar serializer.
    expect(a).toContain('condition:');
  });

  it('never emits an AWS-native exporter/pipeline for ANY resolvable binding set (Property 11/17)', () => {
    const buArb = fc
      .tuple(fc.constantFrom('team-bu', 'unit', 'org', 'bu'), fc.integer({ min: 0, max: 999 }))
      .map(([p, n]) => `${p}-${n}`);
    const bindingsArb = fc.uniqueArray(buArb, { minLength: 0, maxLength: 6 }).map((bus) =>
      bus.map(
        (bu, i): LangfuseProjectBinding => ({
          bu,
          projectId: `proj-${bu}-${i}`,
          publicKeyRef: `pk-${bu}`,
          secretKeyRef: `sk-${bu}`,
          otlpBasicAuthRef: `auth-${bu}`,
        }),
      ),
    );

    fc.assert(
      fc.property(bindingsArb, (bs) => {
        const rendered = renderCollectorConfig(config([]), {
          ...options,
          langfuseProjectBindings: bs,
          langfuseOtelEndpoint: LANGFUSE_OTEL,
        });
        for (const key of Object.keys(rendered.config.exporters)) {
          expect(key.startsWith('otlphttp/')).toBe(true);
          for (const aws of AWS_NATIVE_EXPORTER_NAMES) {
            expect(key.includes(aws)).toBe(false);
          }
        }
        for (const aws of AWS_NATIVE_PIPELINE_NAMES) {
          expect(Object.keys(rendered.config.service.pipelines)).not.toContain(aws);
          expect(rendered.yaml).not.toContain(aws);
        }
      }),
      { numRuns: 100 },
    );
  });
});

describe('toYaml — deterministic serialization', () => {
  it('is deterministic for the same input', () => {
    const a = renderCollectorConfig(config([backend({ mode: 'add' })]), options).yaml;
    const b = renderCollectorConfig(config([backend({ mode: 'add' })]), options).yaml;
    expect(a).toBe(b);
  });

  it('serializes the receiver, batch processor, exporters, and pipeline as YAML', () => {
    const rendered = renderCollectorConfig(config([]), options);
    const yaml = rendered.yaml;
    expect(yaml).toContain('receivers:');
    expect(yaml).toContain('otlp:');
    expect(yaml).toContain('protocols:');
    expect(yaml).toContain('grpc:');
    expect(yaml).toContain('processors:');
    expect(yaml).toContain('batch: {}');
    expect(yaml).toContain('exporters:');
    expect(yaml).toContain('otlphttp/langfuse:');
    expect(yaml).toContain('sending_queue:');
    expect(yaml).toContain('blocking: false');
    expect(yaml).toContain('retry_on_failure:');
    expect(yaml).toContain('traces/thirdparty:');
    // Quoted endpoint scalar with special ':' preserved.
    expect(yaml).toContain(`endpoint: "${LANGFUSE_ENDPOINT}"`);
  });

  it('never emits an AWS-native exporter or pipeline token in the YAML', () => {
    const rendered = renderCollectorConfig(
      config([backend({ name: 'datadog', mode: 'add' })]),
      options,
    );
    for (const aws of AWS_NATIVE_EXPORTER_NAMES) {
      expect(rendered.yaml).not.toContain(aws);
    }
    for (const aws of AWS_NATIVE_PIPELINE_NAMES) {
      expect(rendered.yaml).not.toContain(aws);
    }
  });

  it('serializes an empty exporter list to `[]` (defensive — never occurs via resolveBackends)', () => {
    // resolveBackends always yields >=1 exporter, so the pipeline exporter list
    // is never empty in practice; assert the serializer handles [] anyway.
    expect(toYaml({
      receivers: { otlp: { protocols: { grpc: { endpoint: 'x' }, http: { endpoint: 'y' } } } },
      processors: { batch: {} },
      exporters: {},
      service: { pipelines: { 'traces/thirdparty': { receivers: ['otlp'], processors: ['batch'], exporters: [] } } },
    })).toContain('exporters: []');
  });
});
