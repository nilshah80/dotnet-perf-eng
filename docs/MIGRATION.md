# Migration from v1 request catalogs

This document is the Slice 1/Slice 10 compatibility adapter record. It does
not change frozen `v1` bytes.

## Catalogs

`perflab lab migrate-catalog` and native `catalog migrate-catalog` rewrite a
v1 TSV catalog to a v1 `ScenarioCatalog` with `contractRevision: v1`.
Every TSV row becomes `workload.type: request`. `lifecycle.ownership` and
`writeSafety.class` are separate fields; both default to `none`.

Existing measured request output is unchanged. Journey descriptors may appear
in `v1` catalogs; runners advertise and execute journeys from `v1`.

## Comparison projection

Eligible legacy request baselines gate through `legacy-request-v1`. Journey,
mix, distributed, diagnostic-campaign, continuous-profiling, and fault
candidates are inconclusive rather than coerced into that projection.

## JMeter properties

New defaults and shipped JMX use `perf.*`. A recorded v1 adapter still accepts
`perflab.*` keys and emits the canonical `perf.*` names. Compatibility
environment names `PERFLAB_JMETER_*` remain names only.

## Rollback

Keep `v1` listed in `contract-index.json`. A newer runner accepts that
revision through the frozen history snapshot. Do not rewrite
`contract-history/v1/`.
