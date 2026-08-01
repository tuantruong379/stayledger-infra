#!/usr/bin/env node
/**
 * Split cluster export (List YAML per kind) into by-project folders mirroring stayledger-infra.
 * Output: artifacts/infra-export-<ts>/by-project/{staging|production}/<project>/...
 * Secrets: copied to secrets/ subfolder (SENSITIVE — do not commit).
 */
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'yaml';

const __dirname = dirname(fileURLToPath(import.meta.url));
const exportRoot = process.argv[2] || join(__dirname, '../../artifacts/infra-export-20260727-102813');
const outRoot = join(exportRoot, 'by-project');

/** @returns {string} project path relative to env root */
function mapProject(item, envNs) {
  const name = item.metadata?.name ?? '';
  const labels = item.metadata?.labels ?? {};
  const app = labels.app ?? '';
  const component = labels.component ?? '';
  const ns = item.metadata?.namespace ?? envNs;

  // Namespace-first routing
  if (ns === 'observability') {
    return 'stayledger-shared/observability';
  }
  if (ns === 'stayledger-ai-assistant') {
    return 'stayledger-ai-assistant';
  }
  if (item.kind === 'PrometheusRule' || name.startsWith('stayledger-pms-')) {
    return 'stayledger-shared/observability';
  }

  // PMS workloads (stayledger-staging / stayledger)
  if (
    name.startsWith('stayledger-admin-web') ||
    app === 'stayledger-admin-web' ||
    name === 'stayledger-admin-web-config'
  ) {
    return 'stayledger-admin-web';
  }
  if (
    name.startsWith('stayledger-api') ||
    name.startsWith('stayledger-ai-worker') ||
    app === 'stayledger-api' ||
    app === 'stayledger-ai-worker' ||
    name === 'stayledger-api-config' ||
    name.includes('guest-documents') ||
    name.includes('document-backup-offnode') ||
    name.includes('migration') && name.includes('stayledger')
  ) {
    return 'stayledger-api';
  }
  if (
    name.startsWith('stayledger-landing') ||
    app === 'stayledger-landing' ||
    name.startsWith('stayledger-landing-')
  ) {
    return 'stayledger-landing';
  }

  // Shared datastores (postgres, redis, pgbouncer, cluster secrets for PMS)
  if (
    /stayledger-postgres|stayledger-redis|stayledger-pgbouncer|postgres-backup|backup-notify|db-unlock/.test(
      name,
    ) ||
    name === 'stayledger-secrets' ||
    name === 'stayledger-staging-secrets' ||
    name === 'stayledger-pgbouncer-secret' ||
    name === 'backup-offnode-s3' ||
    name === 'stayledger-document-backup-s3' ||
    name === 'stayledger-metrics-auth' ||
    name.startsWith('restore-httpsmoke') ||
    name.startsWith('stayledger-postgres-') ||
    name.startsWith('stayledger-redis-') ||
    name.startsWith('stayledger-pgbouncer-') ||
    app === 'stayledger-postgres' ||
    app === 'stayledger-redis' ||
    app === 'stayledger-pgbouncer'
  ) {
    return 'stayledger-shared/datastores';
  }

  // AI assistant namespace resources
  if (
    name.startsWith('hotel-assistant') ||
    name.startsWith('postgres-') ||
    name.startsWith('pgbouncer') ||
    name.startsWith('redis') ||
    name.startsWith('nats') ||
    name === 'postgres-secret' ||
    name === 'redis-secret' ||
    name.startsWith('rag-eval')
  ) {
    return 'stayledger-ai-assistant';
  }

  // Observability stack
  if (
    name.startsWith('kps-') ||
    name.startsWith('grafana-') ||
    name.startsWith('loki') ||
    name.startsWith('tempo') ||
    name.startsWith('promtail') ||
    name.startsWith('otel-') ||
    name.startsWith('hotel-ai') ||
    name.includes('prometheus') ||
    component === 'monitoring'
  ) {
    return 'stayledger-shared/observability';
  }

  // TLS / ingress certs in PMS ns
  if (name.includes('tls') || name.includes('-tls')) {
    if (envNs.includes('ai-assistant')) return 'stayledger-ai-assistant';
    if (name.includes('landing')) return 'stayledger-landing';
    if (name.includes('admin') || name.includes('app')) return 'stayledger-admin-web';
    if (name.includes('api')) return 'stayledger-api';
    return 'stayledger-shared/datastores';
  }

  if (name === 'kube-root-ca.crt') return '_cluster/system';

  return '_unmapped';
}

function envFromPath(p) {
  if (p.includes('\\staging\\') || p.includes('/staging/')) return 'staging';
  if (p.includes('\\production\\') || p.includes('/production/')) return 'production';
  return 'unknown';
}

function nsFromPath(p) {
  const m = p.match(/[\\/](stayledger-staging|stayledger|stayledger-ai-assistant|observability)[\\/]/);
  return m ? m[1] : 'unknown';
}

function loadListYaml(filePath) {
  const raw = readFileSync(filePath, 'utf8');
  if (!raw.trim()) return [];
  const doc = yaml.parse(raw);
  if (doc?.items && Array.isArray(doc.items)) return doc.items;
  if (doc?.kind && doc?.metadata) return [doc];
  return [];
}

function ensureDir(p) {
  mkdirSync(p, { recursive: true });
}

function writeResource(outDir, kind, item, isSecret) {
  const sub = isSecret ? 'secrets' : 'live';
  const dir = join(outDir, sub);
  ensureDir(dir);
  const fname = `${kind.toLowerCase()}-${item.metadata.name}.yaml`;
  const cleaned = stripClusterNoise(item);
  writeFileSync(join(dir, fname), yaml.stringify(cleaned), 'utf8');
}

function stripClusterNoise(item) {
  const o = structuredClone(item);
  delete o.metadata?.resourceVersion;
  delete o.metadata?.uid;
  delete o.metadata?.creationTimestamp;
  delete o.metadata?.generation;
  delete o.metadata?.managedFields;
  delete o.status;
  if (o.metadata?.annotations) {
    delete o.metadata.annotations['deployment.kubernetes.io/revision'];
    delete o.metadata.annotations['kubectl.kubernetes.io/last-applied-configuration'];
  }
  return o;
}

function walkExport(dir, files = []) {
  for (const ent of readdirSync(dir)) {
    const p = join(dir, ent);
    if (statSync(p).isDirectory()) {
      if (ent === 'by-project' || ent === '_cluster-scoped') continue;
      walkExport(p, files);
    } else if (ent.endsWith('.yaml') && !ent.startsWith('_')) {
      files.push(p);
    }
  }
  return files;
}

const buckets = new Map();
const unmapped = [];

for (const filePath of walkExport(join(exportRoot, 'staging')).concat(walkExport(join(exportRoot, 'production')))) {
  const env = envFromPath(filePath);
  const ns = nsFromPath(filePath);
  const kindFile = filePath.split(/[\\/]/).pop().replace('.yaml', '');
  const isSecret = kindFile === 'secrets';

  let kind = kindFile;
  if (kind.endsWith('s') && kind !== 'ingresses') {
    kind = kind.slice(0, -1);
    if (kind === 'horizontalpodautoscaler') kind = 'HorizontalPodAutoscaler';
    else if (kind === 'servicemonitor') kind = 'ServiceMonitor';
    else if (kind === 'prometheusrule') kind = 'PrometheusRule';
    else if (kind === 'networkpolicie') kind = 'NetworkPolicy';
    else kind = kind.charAt(0).toUpperCase() + kind.slice(1);
  }
  if (kindFile === 'horizontalpodautoscalers') kind = 'HorizontalPodAutoscaler';
  if (kindFile === 'servicemonitors') kind = 'ServiceMonitor';
  if (kindFile === 'prometheusrules') kind = 'PrometheusRule';
  if (kindFile === 'networkpolicies') kind = 'NetworkPolicy';
  if (kindFile === 'configmaps') kind = 'ConfigMap';
  if (kindFile === 'deployments') kind = 'Deployment';
  if (kindFile === 'services') kind = 'Service';
  if (kindFile === 'ingresses') kind = 'Ingress';
  if (kindFile === 'cronjobs') kind = 'CronJob';
  if (kindFile === 'jobs') kind = 'Job';
  if (kindFile === 'statefulsets') kind = 'StatefulSet';
  if (kindFile === 'persistentvolumeclaims') kind = 'PersistentVolumeClaim';

  for (const item of loadListYaml(filePath)) {
    if (!item?.metadata?.name) continue;
    const project = mapProject(item, ns);
    const key = `${env}/${project}`;
    if (project === '_unmapped') {
      unmapped.push({ env, ns, kind, name: item.metadata.name, from: kindFile });
      continue;
    }
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push({ kind, item, isSecret });
  }
}

for (const [key, items] of buckets) {
  const outDir = join(outRoot, ...key.split('/'));
  ensureDir(outDir);
  const index = {};
  for (const { kind, item, isSecret } of items) {
    writeResource(outDir, kind, item, isSecret);
    const sub = isSecret ? 'secrets' : 'live';
    index[`${sub}/${kind}-${item.metadata.name}`] = kind;
  }
  writeFileSync(join(outDir, '_INDEX.json'), JSON.stringify(index, null, 2));
}

writeFileSync(
  join(outRoot, 'UNMAPPED.json'),
  JSON.stringify(unmapped, null, 2),
);
writeFileSync(
  join(outRoot, 'README.md'),
  `# By-project cluster snapshot

Mirrors [stayledger-infra/docs/FOLDER-STRUCTURE.md](../../../stayledger-infra/docs/FOLDER-STRUCTURE.md).

- \`live/\` — ConfigMap, Deployment, Service, Ingress, ... (cluster noise stripped)
- \`secrets/\` — **SENSITIVE** — do not commit

Source export: \`${exportRoot}\`

Regenerate: \`node stayledger-infra/scripts/split-infra-export-by-project.mjs <export-dir>\`
`,
);

console.log(JSON.stringify({
  outRoot,
  projects: [...buckets.keys()].sort(),
  unmappedCount: unmapped.length,
  unmappedSample: unmapped.slice(0, 15),
}, null, 2));
