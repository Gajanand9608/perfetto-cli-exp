# Android Startup ANR Perfetto Workflow

This workspace is for capturing Android startup traces and using an AI agent to
analyze the resulting Perfetto trace files.

The current investigation target was:

- Package: `com.learning.apaexperiment`
- Trace: `trace_20260622_084640.perfetto-trace`
- Analysis notes: `trace_20260622_084640.perfetto-trace_analysis.md`

## What This Workflow Covers

Use this README when you need to:

1. Launch an Android app.
2. Capture a Perfetto trace during startup.
3. Pull the trace file to this workspace.
4. Launch an AI agent with a precise analysis prompt.
5. Analyze main-thread ANRs, jank, lock contention, and I/O waits.

## Prerequisites

Install or verify:

```sh
adb version
android --version
```

The Android CLI can launch apps and capture screenshots:

```sh
android run --help
android screen capture --help
```

The Perfetto trace processor wrapper should live at the workspace root:

```sh
ls ./trace_processor
```

If it is missing:

```sh
curl -LO https://get.perfetto.dev/trace_processor
chmod +x trace_processor
printf "trace_processor\n" >> .gitignore
```

## Launch The App

If you have APKs:

```sh
android run --device <DEVICE_SERIAL> --apks <APP.apk>
```

If the app is already installed:

```sh
adb shell am force-stop com.learning.apaexperiment
adb shell monkey -p com.learning.apaexperiment -c android.intent.category.LAUNCHER 1
```

Capture a screenshot if you need to confirm state:

```sh
android screen capture -o screen.png
```

## Capture A Startup Trace

Use this script as the reusable implementation in another project. Save it as
`capture_startup_trace.sh` or paste it into the agent that will implement the
same workflow.

```sh
#!/usr/bin/env bash
set -euo pipefail

PACKAGE="${1:-com.learning.apaexperiment}"
DURATION_SEC="${2:-15}"
DEVICE_ARG="${ANDROID_SERIAL:+-s ${ANDROID_SERIAL}}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-.}"
TRACE_NAME="trace_${STAMP}.perfetto-trace"
REMOTE_TRACE="/data/misc/perfetto-traces/${TRACE_NAME}"

mkdir -p "${OUT_DIR}"

echo "Package: ${PACKAGE}"
echo "Duration: ${DURATION_SEC}s"
echo "Remote trace: ${REMOTE_TRACE}"

adb ${DEVICE_ARG} shell rm -f "${REMOTE_TRACE}" || true
adb ${DEVICE_ARG} shell am force-stop "${PACKAGE}" || true

# Start Perfetto first, then launch the app so startup is inside the trace.
adb ${DEVICE_ARG} shell perfetto \
  -o "${REMOTE_TRACE}" \
  -t "${DURATION_SEC}s" \
  sched freq idle am wm gfx view binder_driver hal dalvik app &

PERFETTO_PID=$!
sleep 1

adb ${DEVICE_ARG} shell monkey \
  -p "${PACKAGE}" \
  -c android.intent.category.LAUNCHER \
  1

wait "${PERFETTO_PID}"
adb ${DEVICE_ARG} pull "${REMOTE_TRACE}" "${OUT_DIR}/${TRACE_NAME}"

echo "Trace saved to ${OUT_DIR}/${TRACE_NAME}"
```

Run it:

```sh
chmod +x capture_startup_trace.sh
./capture_startup_trace.sh com.learning.apaexperiment 15
```

Use a longer duration for ANRs:

```sh
./capture_startup_trace.sh com.learning.apaexperiment 30
```

## Launch The AI Agent

Start your coding or analysis agent from this workspace, then paste this prompt.
If your agent supports file access, give it the absolute trace path.

```text
Analyze the Perfetto trace at /absolute/path/to/trace.perfetto-trace.

The Android app <PACKAGE_NAME> is experiencing ANRs during app startup.
The main thread appears blocked or busy in Application.onCreate().

Find the root cause:
1. What is blocking or occupying the main thread, and for how long?
2. What is the full call chain to the blocking code?
3. Are there secondary performance issues such as jank, lock contention, Binder
   waits, or I/O waits?
4. What is the recommended fix?

Use trace_processor SQL. Create a chain-of-evidence markdown file next to the
trace. Do not conclude from long wall time alone; verify thread_state to
separate Running, Runnable, Sleeping, and D-state/I/O wait time.
```

## Trace Processor Commands

Run startup metrics first. Some traces do not populate `android_startup`, but it
is still the right first check.

```sh
./trace_processor --run-metrics android_startup trace_20260622_084640.perfetto-trace
```

Run ad hoc SQL:

```sh
./trace_processor --query-string "SELECT trace_bounds.start_ts, trace_bounds.end_ts FROM trace_bounds;" trace_20260622_084640.perfetto-trace
```

## Important SQL For Startup ANR Analysis

Replace `com.learning.apaexperiment` and the trace filename as needed.

### Resolve Process And Main Thread

```sql
SELECT
  p.upid AS upid,
  p.pid AS pid,
  p.name AS process_name,
  p.start_ts AS process_start_ts,
  t.utid AS main_utid,
  t.tid AS main_tid,
  t.name AS thread_name,
  t.start_ts AS thread_start_ts
FROM process AS p
JOIN thread AS t ON t.upid = p.upid
WHERE p.name = 'com.learning.apaexperiment'
  AND t.is_main_thread = 1;
```

### Find Long Main Thread Slices

Replace `2971` with the resolved `main_utid`.

```sql
INCLUDE PERFETTO MODULE slices.with_context;

SELECT
  ts.id AS slice_id,
  ts.ts AS ts,
  ts.dur AS dur,
  IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur) / 1000000.0 AS observed_ms,
  ts.depth AS depth,
  ts.parent_id AS parent_id,
  ts.name AS name
FROM thread_slice AS ts
WHERE ts.utid = 2971
ORDER BY IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur) DESC
LIMIT 50;
```

### Verify What The Main Thread Was Doing

Use the suspicious slice timestamp as the lower bound. This example uses the
`bindApplication` start from the current trace.

```sql
SELECT
  thread_state.state AS state,
  thread_state.io_wait AS io_wait,
  thread_state.blocked_function AS blocked_function,
  COUNT(*) AS count,
  SUM(IIF(thread_state.dur = -1, trace_end() - thread_state.ts, thread_state.dur)) / 1000000.0 AS dur_ms
FROM thread_state
WHERE thread_state.utid = 2971
  AND thread_state.ts < trace_end()
  AND (thread_state.ts + IIF(thread_state.dur = -1, trace_end() - thread_state.ts, thread_state.dur)) > 26405108457854
GROUP BY thread_state.state, thread_state.io_wait, thread_state.blocked_function
ORDER BY dur_ms DESC;
```

Interpretation:

- `Running`: the main thread is consuming CPU.
- `R` or `R+`: runnable but waiting for CPU.
- `S`: sleeping or waiting.
- `D` with `io_wait=1`: usually blocked in kernel I/O.

### Search For App-Specific Startup Code

```sql
INCLUDE PERFETTO MODULE slices.with_context;

SELECT
  ts.id AS slice_id,
  ts.ts AS ts,
  IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur) / 1000000.0 AS observed_ms,
  ts.thread_name AS thread_name,
  ts.utid AS utid,
  ts.tid AS tid,
  ts.depth AS depth,
  ts.parent_id AS parent_id,
  ts.name AS name
FROM thread_slice AS ts
WHERE ts.process_name = 'com.learning.apaexperiment'
  AND (
    LOWER(ts.name) GLOB '*application.oncreate*'
    OR LOWER(ts.name) GLOB '*callapplicationoncreate*'
    OR LOWER(ts.name) GLOB '*applaunchinitmanager*'
    OR LOWER(ts.name) GLOB '*startup*'
    OR LOWER(ts.name) GLOB '*fibo*'
  )
ORDER BY ts.ts ASC;
```

### Check Lock Contention

```sql
INCLUDE PERFETTO MODULE slices.with_context;

SELECT
  ts.thread_name AS thread_name,
  ts.utid AS utid,
  ts.tid AS tid,
  ts.name AS name,
  COUNT(*) AS count,
  SUM(IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur)) / 1000000.0 AS total_ms,
  MAX(IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur)) / 1000000.0 AS max_ms
FROM thread_slice AS ts
WHERE ts.process_name = 'com.learning.apaexperiment'
  AND LOWER(ts.name) GLOB '*lock contention*'
GROUP BY ts.thread_name, ts.utid, ts.tid, ts.name
ORDER BY total_ms DESC
LIMIT 50;
```

### Check App I/O Waits

```sql
SELECT
  t.name AS thread_name,
  t.utid AS utid,
  t.tid AS tid,
  thread_state.blocked_function AS blocked_function,
  thread_state.io_wait AS io_wait,
  COUNT(*) AS count,
  SUM(IIF(thread_state.dur = -1, trace_end() - thread_state.ts, thread_state.dur)) / 1000000.0 AS total_ms,
  MAX(IIF(thread_state.dur = -1, trace_end() - thread_state.ts, thread_state.dur)) / 1000000.0 AS max_ms
FROM thread_state
JOIN thread AS t ON t.utid = thread_state.utid
JOIN process AS p ON p.upid = t.upid
WHERE p.name = 'com.learning.apaexperiment'
  AND thread_state.state = 'D'
GROUP BY t.name, t.utid, t.tid, thread_state.blocked_function, thread_state.io_wait
ORDER BY total_ms DESC
LIMIT 50;
```

### Check Jank / Frame Timeline

If startup never reaches drawing, there may be no rows for the target app.

```sql
SELECT
  aft.name AS name,
  COUNT(*) AS frames,
  SUM(CASE WHEN aft.dur > 16666666 THEN 1 ELSE 0 END) AS over_16_6ms,
  MAX(aft.dur) / 1000000.0 AS max_ms,
  SUM(aft.dur) / 1000000.0 AS total_ms
FROM actual_frame_timeline_slice AS aft
WHERE aft.upid = (
  SELECT p.upid
  FROM process AS p
  WHERE p.name = 'com.learning.apaexperiment'
  LIMIT 1
)
GROUP BY aft.name
ORDER BY max_ms DESC;
```

## Current Trace Finding Summary

For `trace_20260622_084640.perfetto-trace`, the main thread was not blocked on a
lock or I/O. It was busy-running CPU work during startup:

- `bindApplication` was open for at least `13515.370132 ms`.
- Main thread was `Running` for `13465.574996 ms` inside that observed window.
- After `AppLaunchInitManager.fibo(long)` was JIT compiled, the main thread ran
  in user mode for at least `13260.737255 ms`.
- Main thread I/O wait was small by comparison.
- Main thread lock contention was negligible.

The likely code path is:

```text
bindApplication
-> makeApplication
-> Instrumentation.callApplicationOnCreate(...)
-> Application.onCreate()
-> com.learning.apaexperiment.AppLaunchInitManager
-> AppLaunchInitManager.onAppLaunchSync...
-> AppLaunchInitManager.launchSync...
-> AppLaunchInitManager.fibo(long)
```

Recommended fix: remove synchronous CPU-heavy work from `Application.onCreate()`
and startup initializers. Move non-critical initialization off the main thread,
make it lazy, and replace recursive or expensive Fibonacci-style demo work with
an iterative, memoized, or background implementation.

## Notes For Another Agent

When implementing this in another project:

- Keep traces and analysis notes in one directory.
- Create one analysis markdown file per trace.
- Always record exact timestamps, `upid`, `utid`, `pid`, `tid`, slice IDs, and
  thread states.
- Never conclude from a long slice alone. Query `thread_state`.
- If the main thread is `Running`, look for CPU-heavy app code.
- If it is `D/io_wait=1`, follow I/O and blocked function evidence.
- If it is `S`, inspect Binder, locks, futex waits, or other dependency chains.
- Check lock contention, D-state totals, Binder waits, and frame timeline before
  finalizing the root cause.
