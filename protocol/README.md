# DartAframes native protocol v2

Protocol v2 is a binding-owned JSON direct-handle protocol. Each request is an
object containing `"protocol": 2`, a stable `command`, and only that command's
declared fields. Unknown or irrelevant fields are rejected. Every expression
and lazy operation is executed immediately as a Rust API call: Rust clones the
native inputs, creates a real Polars `Expr` or `LazyFrame`, and returns a new
opaque handle. Polars query evaluation itself stays lazy until collection.

`protocol/capabilities.json` is a checked-in copy of the current native `hello`
payload. A loaded library's response remains authoritative.

## C ABI

ABI version 2 exports the six core protocol/ownership symbols plus twelve Arrow
C Data/C Stream interchange symbols:

```c
uint32_t df_abi_version(void);
int32_t df_invoke(const uint8_t *request, uint64_t request_length,
                  DfBuffer *result);
void df_buffer_free(DfBuffer *buffer);
int32_t df_handle_release(uint64_t handle);
void *df_handle_token_new(uint64_t handle);
void df_handle_token_release(void *token);

struct ArrowArray *df_arrow_array_new(void);
struct ArrowSchema *df_arrow_schema_new(void);
struct ArrowArrayStream *df_arrow_stream_new(void);
void df_arrow_array_delete(struct ArrowArray *array);
void df_arrow_schema_delete(struct ArrowSchema *schema);
void df_arrow_stream_delete(struct ArrowArrayStream *stream);
int32_t df_series_export_arrow(uint64_t handle, struct ArrowArray *array,
                               struct ArrowSchema *schema);
int32_t df_series_import_arrow(struct ArrowArray *array,
                               struct ArrowSchema *schema, uint64_t *handle);
int32_t df_frame_export_arrow(uint64_t handle, struct ArrowArray *array,
                              struct ArrowSchema *schema);
int32_t df_frame_import_arrow(struct ArrowArray *array,
                              struct ArrowSchema *schema, uint64_t *handle);
int32_t df_frame_export_arrow_stream(uint64_t handle, uint64_t max_rows,
                                     struct ArrowArrayStream *stream);
int32_t df_frame_import_arrow_stream(struct ArrowArrayStream *stream,
                                     uint64_t max_batches, uint64_t max_rows,
                                     uint64_t *handle);
```

`DfBuffer` is `uint8_t *data`, `uint64_t length`, then `int32_t status`. Rust
owns response bytes until one `df_buffer_free`, which clears the descriptor.
Return/status values are 0 (success), 1 (error), and 2 (caught panic); every
entry point has a panic barrier.

Handles identify typed `expr`, `selector`, `dtypeSelector`, `lazyFrame`,
`frame`, `series`, `job`, `sqlContext`, or `batchStream` registry entries.
They are generation-protected `uint64_t` values, never pointers, and every JSON
handle field or handle-array element is an unsigned decimal string:

```json
{"protocol":2,"command":"lazyCollect","input":"4294967297"}
```

Finalizer tokens provide one ownership path: `df_handle_token_release` releases
both token and handle best-effort. A caller must not also release that handle
through `df_handle_release`.

## Closed command schemas

The current registry contains 112 commands. The table lists every accepted
command-specific field; `protocol` and `command` are always accepted and no
other fields are. `?` means optional. Handle-valued fields use decimal strings.

| Group | Command | Accepted command fields |
| --- | --- | --- |
| core | `hello` | none |
| core | `runtimeDiagnostics` | none |
| frame | `frameImport` | `batch` |
| frame | `frameInfo` | `frame` |
| frame | `frameExport` | `frame` |
| frame | `frameLazy` | `frame` |
| frame | `frameReadJson` | `path`, `inferSchemaLength?`, `batchSize?`, `rechunk?` |
| frame | `frameReadIpcStream` | `path`, `nRows?`, `columns?`, `rechunk?` |
| frame | `frameWriteCsv` | `frame`, `path`, `includeHeader?`, `separator?` |
| frame | `frameWriteParquet` | `frame`, `path`, `compression?` |
| frame | `frameWriteIpc` | `frame`, `path`, `compression?`, `recordBatchSize?`, `parallel?`, `recordBatchStatistics?` |
| frame | `frameWriteIpcStream` | `frame`, `path`, `compression?` |
| frame | `frameWriteJson` | `frame`, `path` |
| frame | `frameWriteNdjson` | `frame`, `path` |
| frame | `frameColumn` | `frame`, `name` |
| frame | `frameSelectColumns` | `frame`, `columns` |
| frame | `frameSelect` | `frame`, `expressions` |
| frame | `frameFilter` | `frame`, `predicate` |
| frame | `frameFilterMask` | `frame`, `mask` |
| frame | `frameWithColumns` | `frame`, `expressions` |
| frame | `frameSort` | `frame`, `by`, `descending`, `nullsLast`, `maintainOrder` |
| frame | `frameSlice` | `frame`, `offset`, `length` |
| frame | `frameReverse` | `frame` |
| frame | `frameDrop` | `frame`, `columns`, `strict` |
| frame | `frameRename` | `frame`, `existing`, `new`, `strict` |
| series | `seriesImport` | `column` |
| series | `seriesInfo` | `series` |
| series | `seriesExport` | `series` |
| series | `seriesToFrame` | `series` |
| series | `seriesRename` | `series`, `name` |
| series | `seriesCast` | `series`, `dtype`, `strict` |
| series | `seriesSlice` | `series`, `offset`, `length` |
| series | `seriesReverse` | `series` |
| series | `seriesSort` | `series`, `descending`, `nullsLast`, `maintainOrder`, `multithreaded` |
| series | `seriesFilter` | `series`, `mask` |
| series | `seriesDropNulls` | `series` |
| series | `seriesAppend` | `left`, `right` |
| series | `seriesGather` | `series`, `indices` |
| series | `seriesUnique` | `series`, `maintainOrder` |
| series | `seriesBinary` | `left`, exactly one of `right`/`scalar`, `op` |
| series | `seriesAggregate` | `series`, `op` |
| job | `lazyCollect` | `input`, execution engine and optimizer fields? |
| job | `lazySubmit` | `input`, execution engine and optimizer fields? |
| job | `lazyProfile` | `input`, optimizer fields? |
| job | `jobPoll` | `job` |
| job | `jobCancel` | `job` |
| job | `jobTake` | `job` |
| job | `lazyBatchStream` | `input`, `batchRows`, `capacity`, `engine` |
| job | `batchStreamPoll` | `stream` |
| job | `batchStreamCancel` | `stream` |
| expression | `exprColumn` | `name` |
| expression | `exprLiteral` | `scalar` |
| expression | `exprLen` | none |
| expression | `exprAlias` | `input`, `name` |
| expression | `exprCast` | `input`, `dtype`, `strict?` |
| expression | `exprUnary` | `input`, `op` |
| expression | `exprBinary` | `left`, `right`, `op` |
| expression | `exprTernary` | `predicate`, `truthy`, `falsy` |
| expression | `exprAggregate` | `input`, `op`, and only the options valid for that operation |
| expression | `exprFunction` | `input`, `name`, `arguments`, plus only the selected function's options |
| expression | `exprOver` | `input`, `partitionBy`, `orderBy`, `mapping`, `orderDescending`, `orderNullsLast`, `orderMaintainOrder`, `orderMultithreaded` |
| selector | `selectorAll` | none |
| selector | `selectorEmpty` | none |
| selector | `selectorByName` | `names`, `strict`, `expandPatterns` |
| selector | `selectorByIndex` | `indices`, `strict` |
| selector | `selectorMatches` | `pattern` |
| selector | `selectorBinary` | `left`, `right`, `op` |
| selector | `selectorNot` | `input` |
| selector | `selectorAsExpr` | `input` |
| dtype selector | `dtypeSelectorCreate` | `kind`, plus only that kind's fields |
| dtype selector | `dtypeSelectorBinary` | `left`, `right`, `op` |
| dtype selector | `dtypeSelectorNot` | `input` |
| dtype selector | `dtypeSelectorAsSelector` | `input` |
| dtype selector | `dtypeSelectorMatches` | `input`, `dtype` |
| SQL | `sqlContextNew` | none |
| SQL | `sqlContextRegister` | `context`, `name`, `input` |
| SQL | `sqlContextRegisterAll` | `context`, `tables` (`name`/`input` objects) |
| SQL | `sqlContextUnregister` | `context`, `names` |
| SQL | `sqlContextTables` | `context` |
| SQL | `sqlContextExecute` | `context`, `query` |
| lazy | `lazyScanCsv` | `path`, `hasHeader?`, `separator?`, `skipRows?`, `nRows?`, `tryParseDates?` |
| lazy | `lazyScanParquet` | `path`, `nRows?`, `parallel?` |
| lazy | `lazyScanIpc` | `path`, `nRows?`, `cache?`, `rechunk?`, `recordBatchStatistics?` |
| lazy | `lazyScanNdjson` | `path`, `nRows?`, `inferSchemaLength?`, `ignoreErrors?`, `lowMemory?`, `rechunk?` |
| lazy | `lazySinkCsv` | `input`, `path`, `includeHeader`, `separator`, `maintainOrder` |
| lazy | `lazySinkParquet` | `input`, `path`, `compression`, `maintainOrder` |
| lazy | `lazySinkIpc` | `input`, `path`, `compression`, `maintainOrder` |
| lazy | `lazySinkNdjson` | `input`, `path`, `maintainOrder` |
| lazy | `lazySelect` | `input`, `expressions` |
| lazy | `lazySelectInputs` | `input`, `expressions` (expression or selector handles) |
| lazy | `lazyFilter` | `input`, `predicate` |
| lazy | `lazyWithColumns` | `input`, `expressions` |
| lazy | `lazyWithColumnsInputs` | `input`, `expressions` (expression or selector handles) |
| lazy | `lazySort` | `input`, `by`, `descending?`, `nullsLast?`, `maintainOrder?` |
| lazy | `lazySlice` | `input`, `offset`, `length` |
| lazy | `lazyGroupBy` | `input`, `keys`, `aggregations`, `maintainOrder?` |
| lazy | `lazyJoin` | `left`, `right`, `leftOn`, `rightOn`, `how`, `suffix?`, `coalesce?`, `nullsEqual?`, `validation?`, `maintainOrder?`, `allowParallel?`, `forceParallel?` |
| lazy | `lazyGroupByDynamic` | `input`, `indexColumn`, `groupBy`, `aggregations`, `every`, `period?`, `offset?`, `closed`, `label`, `includeBoundaries`, `startBy` |
| lazy | `lazyGroupByRolling` | `input`, `indexColumn`, `groupBy`, `aggregations`, `period`, `offset?`, `closed` |
| lazy | `lazyJoinAsOf` | `left`, `right`, `leftOn`, `rightOn`, `strategy`, `tolerance?`, `leftBy?`, `rightBy?`, `allowEqual`, `checkSortedness`, `suffix`, `coalesce?`, `allowParallel`, `forceParallel` |
| lazy | `lazyJoinWhere` | `left`, `right`, `predicates`, `suffix`, `allowParallel`, `forceParallel` |
| lazy | `lazyDistinct` | `input`, `subset?`, `keep?`, `maintainOrder?` |
| lazy | `lazyDropNulls` | `input`, `subset?` |
| lazy | `lazyDrop` | `input`, `columns`, `strict` |
| lazy | `lazyRename` | `input`, `existing`, `new`, `strict` |
| lazy | `lazyExplode` | `input`, `columns`, `emptyAsNull?`, `keepNulls?` |
| lazy | `lazyUnnest` | `input`, `columns` |
| lazy | `lazyUnpivot` | `input`, `on?`, `index`, `variableName?`, `valueName?` |
| lazy | `lazyConcat` | `inputs`, `how?`, `rechunk?` |
| lazy | `lazySchema` | `input` |
| lazy | `lazyExplain` | `input`, `optimized`, `format` |

Arrays are limited to 10,000 handles/names and requests to 64 MiB. Names and
paths must be nonempty; write paths are limited to 1 MiB. Notable defaults and
constraints are:

- Series binary operations are `eq`, `eqValidity`, `notEq`, `notEqValidity`,
  `lt`, `ltEq`, `gt`, `gtEq`, `add`, `subtract`, `multiply`, and `trueDivide`.
  Exactly one of a Series `right` handle and a typed `scalar` is required.
- Series aggregates are `count`, `nUnique`, `sum`, `mean`, `min`, `max`,
  `first`, and `last`. Value reductions return an exact typed `scalar` object;
  count reductions return a JSON-safe integer `value`.

- cast `strict=true`; CSV `hasHeader=true`, `separator=,`, `skipRows=0`, and
  `tryParseDates=false`; Parquet `parallel=true`.
- sort booleans default false and must match `by` length; group-by
  `maintainOrder=false`; slice uses signed-i64 `offset` and uint32 `length`.
- legacy joins support `inner|left|right|full|outer|semi|anti|cross`, default
  suffix `_right`, and `coalesce=false`. Typed joins additionally expose null
  equality, cardinality validation, order preservation, parallel controls, and
  nullable join-specific coalescing. Cross joins require empty key arrays; all
  others require equal nonempty key arrays.
- as-of joins use one key per side, `backward|forward|nearest`, optional Polars
  duration tolerance and equal-length `leftBy`/`rightBy`; non-equi joins require
  at least one predicate. Dynamic groups default period to `every` and offset to
  zero; rolling groups default offset to negative `period`.
- distinct defaults to `keep=first`, `maintainOrder=false`; concat defaults to
  `how=vertical`, `rechunk=false`, and also supports `verticalRelaxed`,
  `diagonal`, `diagonalRelaxed`, and `horizontal` (without rechunk).
- `lazyExplode` takes nonempty column-name strings, not expression handles.
  `emptyAsNull` and `keepNulls` default to and currently must remain `true`.
- CSV writes default to a header and comma separator. Parquet writes default to
  `zstd`; supported values are `none|uncompressed|snappy|gzip|brotli|zstd|lz4|lz4raw`.

## Expression operations

Stable operation IDs reported by `hello` are:

- unary: `not`, `negate`, `neg`, `isNull`, `isNotNull`, `isNan`, `isNotNan`;
- binary: `eq`, `eqValidity`, `notEq`, `notEqValidity`, `lt`, `ltEq`, `gt`,
  `gtEq`, `add`, `subtract`, `multiply`, `trueDivide`, `floorDivide`, `modulo`,
  `bitAnd`, `bitOr`, `bitXor`, `logicalAnd`, `logicalOr`;
- aggregate: `count`, `nullCount`, `sum`, `mean`, `min`, `max`, `first`, `last`,
  `median`, `nUnique`, `product`, `std`, `variance`, `quantile`, `argMin`,
  `argMax`, `approximateNUnique`, `nanMin`, `nanMax`, `mode`, `skew`,
  `kurtosis`, `any`, `all` (`exprLen` is a
  separate command);
- functions: `isNull`, `isNotNull`, `isNan`, `isNotNan`, `fillNull`, `abs`,
  `floor`, `ceil`, `round`, `clip`, `clipMin`, `clipMax`, `fillNan`, `isFinite`,
  `isInfinite`, `coalesce`, `isIn`, `lowercase`, `uppercase`, `stringContains`,
  `stringStartsWith`, `stringEndsWith`, `stringReplace`, `stripChars`, `shift`,
  `cumSum`, `cumMin`, `cumMax`, `pow`, `sqrt`, `cbrt`, `log`, `log1p`, `exp`,
  `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`,
  `tanh`, `asinh`, `acosh`, `atanh`, `degrees`, `radians`, `rank`,
  `interpolate`, `interpolateBy`, `diff`, `pctChange`, `rollingMin`,
  `rollingMax`, `rollingMean`, `rollingSum`, `rollingMedian`, `rollingVariance`,
  `rollingStd`, `ewmMean`, `ewmSum`, `ewmStd`, `ewmVariance`.

`std`/`variance` accept `ddof` (default 1, uint8). `quantile` requires a value in
0..1 and accepts `nearest|lower|higher|midpoint|linear` (native default
`nearest`). Function `arguments` is always a handle array. Conditional options
are: `round(decimals, mode=halfToEven|halfAwayFromZero|toZero)`,
`isIn(nullsEqual)`, `stringContains(literal, strict)`,
`stringReplace(literal, replaceAll)`, and `cumSum|cumMin|cumMax(reverse)`.
Those booleans are required on the wire where applicable; the Dart API supplies
them. Rank, interpolation, diff, fixed rolling, and EWM options are enumerated
in `capabilities.json`; their schemas reject irrelevant fields. `neg` is an
accepted alias for `negate`.

## Scalar literals

`exprLiteral.scalar` is a closed object with `dtype` and exactly one payload:
`value`, `floatBits`, `base64`, or `unscaled`. Examples:

```json
{"dtype":{"kind":"int128"},"value":"-170141183460469231731687303715884105728"}
{"dtype":{"kind":"float64"},"floatBits":"7ff8000000000001"}
{"dtype":{"kind":"binary"},"base64":"AAEC"}
{"dtype":{"kind":"datetime","unit":"nanoseconds","timeZone":"UTC"},"value":"42"}
{"dtype":{"kind":"decimal","precision":38,"scale":4},"unscaled":"12340000"}
{"dtype":{"kind":"int64"},"value":null}
```

Large integers, temporal counters, and decimal unscaled values use strings;
floats preserve bits as hexadecimal. Null retains its declared datatype.
`Object` and materialized `Unknown` literals are rejected.

## Responses, collection, and ownership

Success is `{ "ok": true, ... }`. Errors contain `category` and `message`
(`invalidRequest`, `protocolError`, `invalidHandle`, `unsupported`, `compute`,
`io`, `cancelled`, or `internalError`).

`lazyCollect` synchronously collects on the invoking thread. `lazySubmit` starts
Polars `collect_concurrently` and accepts only the `auto` engine so every job
retains Polars' cooperative cancellation token; explicit engines remain
available to synchronous collection. `jobPoll` observes, `jobCancel` requests
cancellation, and `jobTake` atomically returns one completed frame
or `{ "ready": false }`. Native states are `running`, `cancelling`, `complete`,
`cancelled`, `failed`, and `taken`; Dart also recognizes `queued`. Once an
accepted cancellation finishes, the computed result is discarded. A second
take fails.
At most 64 asynchronous jobs may be active; excess submissions fail before an
observer thread is created. Observer threads convert worker panic/disconnection
into a terminal internal error instead of leaving a job permanently running.

Every direct operation clones its native inputs before storing the new result,
so the source handle may be released after success and branches remain
independent. Expression, lazy-frame, frame, series, and job handles each have
one owner.
Deterministic release is normal; finalizer tokens are fallback cleanup. Releasing
a running job drops it and requests cancellation. Future-returning Dart wrappers
for metadata and I/O do not imply worker execution; only job collection does.

## Datatypes and copied batches

All 31 descriptors are:

```text
null, boolean, uint8, uint16, uint32, uint64, uint128,
int8, int16, int32, int64, int128, float16, float32, float64,
decimal, string, binary, binaryOffset, date, datetime, duration, time,
array, list, object, categorical, enum, struct, extension, unknown
```

`hello.datatypeCapabilities` independently reports `descriptor`, `literal`,
`import`, `export`, `cast`, and `kernels`. All 31 support descriptors; the first
23 (through `time`) support the other five levels. Native expressions also
provide namespace kernels for `array`, `list`, `categorical`, `enum`, and
`struct`; `enum` additionally reports cast support. Dart's static matrix is
independent, so callers must check both matrices.

Copied batches contain ordered named columns, descriptors, validity, and owned
logical values. This JSON path is intended for small data and supports only the
23 flat/materialized datatype IDs. Nested, category/dictionary, enum, struct,
and extension copied values are unsupported; unknown Arrow extensions degrade
to storage. Local IPC file/stream commands are storage I/O and do not provide
Arrow C Data/C Stream or in-memory IPC interchange.

ABI 2 provides Arrow C Data and C Stream interchange for the advertised flat
types. A frame is represented as a non-nullable struct array with flat children;
dictionary arrays, nested children, top-level frame validity, embedded NULs in
exported names, and unknown (`-1`) null counts are rejected. Imports consume the
top-level structs on both success and failure. Exports own independent payloads,
and every live release callback must be invoked exactly once. Stream imports
require explicit positive batch and row limits.

Local format commands are closed to filesystem paths (URI schemes are
rejected). `lazyScanIpc` and `lazyScanNdjson` return direct lazy handles;
`frameReadJson` and `frameReadIpcStream` return direct frame handles. Eager
writes cover IPC/Feather files, IPC streams, JSON arrays, and NDJSON. The
`lazySinkCsv`, `lazySinkParquet`, `lazySinkIpc`, and `lazySinkNdjson` commands
execute Polars 0.55.2 native lazy sinks synchronously and atomically persist a
same-directory temporary file when the platform permits replacement.
Qualified expression APIs use `exprFunction` with a closed, capability-listed
`name` such as `str.lenChars`, `dt.year`, `list.get`, or `struct.field`.
`operations.qualifiedFunctions` is the exhaustive list; support must not be
inferred from the namespace prefix.

Expression metadata uses the separate closed command:

```json
{"protocol":2,"command":"exprMeta","input":"4294967297","op":"rootNames"}
```

Its response has a `value` field (a string list, string, or boolean according
to the operation). `isColumnSelection` and `isLiteral` additionally require
`allowAliasing`; supported operations are listed by
`operations.expressionMetadata`.
