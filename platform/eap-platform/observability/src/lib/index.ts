/**
 * index.ts — barrel for the shared observability backend logic module.
 *
 * Re-exports the pure, AWS-free logic and the design's data-model types so
 * later tasks (Deep_Link_Service, Telemetry_API_Service, collector config
 * resolution, per-BU routing) import from a single stable surface.
 */

export * from './types';
export * from './auth';
export * from './arn';
export * from './sanitize';
export * from './ownership';
export * from './backendConfig';
export * from './langfuseRouting';

// `collectorConfig` re-exports its own render-scoped types and constants. It
// also declares `AWS_NATIVE_EXPORTER_NAMES` (same value/intent as the one in
// `backendConfig`); re-export everything EXCEPT that name to avoid an ambiguous
// star-export collision. Consumers needing the constant get it from
// `backendConfig` via this barrel; the pipeline-name constant is unique to
// `collectorConfig`.
export {
  renderCollectorConfig,
  toYaml,
  AWS_NATIVE_PIPELINE_NAMES,
  BU_ROUTING_RESOURCE_ATTRIBUTE,
  type CollectorConfig,
  type RenderedCollectorConfig,
  type RenderCollectorConfigOptions,
  type OtlpHttpExporterConfig,
  type SendingQueueConfig,
  type RetryOnFailureConfig,
  type PipelineConfig,
  type RoutingConnectorConfig,
  type RoutingTableEntry,
} from './collectorConfig';

// NOTE: `lifecycleStore.ts` (AWS-backed `resolveAgentOwnership`) is intentionally
// NOT re-exported here so this barrel stays pure and AWS-free. The Lambda
// handlers import it directly (`./lifecycleStore`); the pure decision function
// `authorizeAgentForBu` above needs no AWS dependency.
