#!/usr/bin/env python3
"""Execute real Chalk Lua modules with offline, data-only Roblox math fixtures."""
import argparse
import json
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent


def plain(value, lua_type):
    if lua_type(value) != 'table':
        return value
    keys = list(value.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [plain(value[i], lua_type) for i in range(1, len(keys) + 1)]
    return {str(k): plain(value[k], lua_type) for k in keys}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deps', type=Path, default=Path('/private/tmp/chalk-replay-deps'))
    parser.add_argument('--suite', action='append', choices=['planner', 'approach', 'mode', 'motion', 'autoplay', 'wr-repeat', 'idle-guard', 'fullplay', 'fullplay-steering', 'carrier-moves', 'pending-sprint', 'match-skip', 'match-skip-identity', 'autoload'], help='Repeat to select suites; default planner + approach.')
    parser.add_argument('--config', type=Path, help='Locally cached pure Lua module returning native Config.')
    parser.add_argument('--field', type=Path, help='Locally cached pure Lua module returning native Field.')
    parser.add_argument('--route-math', type=Path, help='Saved native RouteMath source for fullplay policy/controller tests.')
    parser.add_argument('--first-only', action='store_true', help='Replay only the first recorded live-miss snapshot.')
    parser.add_argument('--regression-only', action='store_true', help='Run the live-miss fixture assertion without its dense scan.')
    parser.add_argument('--native-witness', type=Path, help='Compare live-miss dense scan against this recorded native JSON report.')
    parser.add_argument('--json', type=Path, help='Optional local report destination.')
    args = parser.parse_args(argv)
    if args.regression_only and args.native_witness:
        parser.error('--native-witness needs the dense scan; omit --regression-only')
    sys.path.insert(0, str(args.deps))
    try:
        from lupa import LuaRuntime, lua_type
    except ImportError as error:
        print(f'Lupa unavailable in {args.deps}: {error}', file=sys.stderr)
        return 2
    lua = LuaRuntime(unpack_returned_tuples=True)
    def load(path):
        path = Path(path)
        return lua.execute(path.read_text(), name=str(path))
    def one(value):
        return value[0] if isinstance(value, tuple) else value
    report = {'runtime': lua.eval('_VERSION'), 'limitations': [
        'Offline Lua with double-precision Vector3/CFrame math; Roblox float32 rounding and Luau runtime are not reproduced.',
        'No physics, replication, frame/input latency, native action execution, or server catch/tackle confirmation.',
        'Instance fixtures are isolated data tables, not simulated characters. Unsupported APIs fail.',
        'Recorded fixtures retain their stated estimated/missing-input assumptions; passing is model validation only.'
    ], 'inputs': {
        'config': str(args.config.resolve()) if args.config else 'suite defaults; Jam uses chalk-offline-fixture-config.lua native numeric whitelist',
        'field': str(args.field.resolve()) if args.field else 'not supplied; recorded field bounds are NOT verified',
        'routeMath': str(args.route_math.resolve()) if args.route_math else None,
        'nativeWitness': str(args.native_witness.resolve()) if args.native_witness else None,
    }, 'suites': {}}
    try:
        load(HERE / 'chalk-offline-roblox-shim.lua')
        planner = load(HERE / 'chalk-intercept-planner.lua')
        approach = load(HERE / 'chalk-wr-approach.lua')
        config = load(args.config) if args.config else None
        field = load(args.field) if args.field else None
    except Exception as error:
        print(f'HARNESS ERROR {error}', file=sys.stderr)
        return 2
    suites = args.suite or ['planner', 'approach']
    failed = 0
    for suite in suites:
        started = time.perf_counter()
        try:
            if suite == 'planner':
                result = load(HERE / 'chalk-intercept-selftest.lua')(planner)
            elif suite == 'approach':
                result = load(HERE / 'chalk-wr-approach-selftest.lua')(approach, planner)
            elif suite == 'risky':
                result = load(HERE / 'chalk-risky-catch-selftest.lua')(planner)
            elif suite == 'threat':
                result = load(HERE / 'chalk-threat-memory-selftest.lua')(planner)
            elif suite == 'mode':
                result = load(HERE / 'chalk-mode-selftest.lua')((HERE / 'chalk-overlay-core.lua').read_text())
            elif suite == 'fullplay-steering':
                result = load(HERE / 'chalk-fullplay-steering-selftest.lua')((HERE / 'chalk-intercept-controller.lua').read_text())
            elif suite == 'motion':
                result = load(HERE / 'chalk-character-motion-selftest.lua')(load(HERE / 'chalk-character-motion.lua'))
            elif suite == 'pending-sprint':
                result = load(HERE / 'chalk-pending-sprint-controller-selftest.lua')(
                    load(HERE / 'chalk-character-motion.lua'), (HERE / 'chalk-intercept-controller.lua').read_text())
            elif suite == 'carrier-moves':
                result = load(HERE / 'chalk-carrier-moves-selftest.lua')(load(HERE / 'chalk-carrier-moves.lua'))
            elif suite == 'autoplay':
                result = load(HERE / 'chalk-autoplay-selftest.lua')(load(HERE / 'chalk-autoplay-policy.lua'))
            elif suite == 'autoload':
                result = load(HERE / 'chalk-autoload-selftest.lua')((HERE / 'chalk-bootstrap.lua').read_text(), (HERE / 'chalk-autoload-controller.lua').read_text(), (HERE / 'chalk-it-up-loader.lua').read_text())
            elif suite == 'match-skip':
                result = load(HERE / 'chalk-match-skip-selftest.lua')(load(HERE / 'chalk-match-skip-controller.lua'))
            elif suite == 'match-skip-identity':
                result = load(HERE / 'chalk-match-skip-identity-selftest.lua')((HERE / 'chalk-overlay-core.lua').read_text())
            elif suite == 'wr-repeat':
                result = load(HERE / 'chalk-wr-repeat-selftest.lua')(load(HERE / 'chalk-wr-repeat-controller.lua'))
            elif suite == 'idle-guard':
                result = load(HERE / 'chalk-idle-guard-selftest.lua')(load(HERE / 'chalk-idle-guard.lua'))
            elif suite == 'fullplay':
                if args.route_math is None:
                    raise ValueError('fullplay needs --route-math PATH to the saved native source')
                result = load(HERE / 'chalk-fullplay-selftest.lua')(load(HERE / 'chalk-fullplay-policy.lua'), load(HERE / 'chalk-fullplay-controller.lua'), args.route_math.read_text(), (HERE / 'chalk-fullplay-policy.lua').read_text())
            elif suite == 'live-miss':
                options = lua.table_from({'firstOnly': args.first_only, 'regressionOnly': args.regression_only})
                result = load(HERE / 'chalk-live-miss-selftest.lua')(planner, config, field, options)
            elif suite == 'jam':
                jam_config = config if config is not None else load(HERE / 'chalk-offline-fixture-config.lua')
                result = load(HERE / 'chalk-jam-avoidance-selftest.lua')(load(HERE / 'chalk-jam-avoidance.lua'), jam_config, field)
            else:
                if config is None or field is None:
                    raise ValueError(f'{suite} needs --config and --field; native values will not be invented')
                if suite == 'tackle':
                    result = load(HERE / 'chalk-tackle-selftest.lua')(planner, load(HERE / 'chalk-tackle-controller.lua'), config, field)
                elif suite == 'wr-timing':
                    result = load(HERE / 'chalk-wr-timing-fixture.lua')(planner, approach, config, field)
                elif suite == 'wr-miss':
                    result = load(HERE / 'chalk-wr-miss-fixture.lua')(planner, config, field, 196.2)
            data = plain(one(result), lua_type)
            data['offlineSeconds'] = time.perf_counter() - started
            if suite == 'live-miss' and args.native_witness:
                native = json.loads(args.native_witness.read_text())
                expected = native.get('result', native)['results'][0]
                actual = data['results'][0]
                checks = {}
                for scan in ('coarse', 'denseContactOnly', 'denseActions'):
                    a, b = actual[scan], expected[scan]
                    margin_delta = abs(a['bestMargin'] - b['bestMargin'])
                    time_delta = abs(a['best']['contactAt'] - b['best']['contactAt'])
                    vector_delta = max(abs(a['best']['rootTarget'][axis] - b['best']['rootTarget'][axis]) for axis in ('x', 'y', 'z'))
                    matches = a['robust'] == b['robust'] and a['best']['kind'] == b['best']['kind'] and margin_delta <= .0001 and time_delta <= .000001 and vector_delta <= .0001
                    checks[scan] = {'passed': matches, 'marginDelta': margin_delta, 'contactTimeDelta': time_delta, 'rootMaxComponentDelta': vector_delta}
                data['nativeWitnessComparison'] = checks
                mismatch_count = sum(not check['passed'] for check in checks.values())
                failed += mismatch_count
                print(f'Native witness parity: {len(checks)-mismatch_count}/{len(checks)} within 1e-4 studs, 1e-6 seconds', flush=True)
            report['suites'][suite] = data
            if 'failed' in data:
                failed += data['failed']
                print(f'{suite}: {data["passed"]}/{data["total"]} PASS ({data["offlineSeconds"]:.3f}s)', flush=True)
                for case in data.get('results', []):
                    if not case.get('passed'):
                        print(f'  FAIL {case.get("name")}: {case.get("error")}', flush=True)
            elif isinstance(data.get('passed'), bool):
                if not data['passed']:
                    failed += 1
                print(f'{suite}: {"PASS" if data["passed"] else "FAIL"} {data.get("tests", 1)} assertions ({data["offlineSeconds"]:.3f}s)', flush=True)
            else:
                print(f'{suite}: replay completed ({data["offlineSeconds"]:.3f}s); no assertion verdict', flush=True)
                print(json.dumps(data, sort_keys=True, default=str), flush=True)
        except Exception as error:
            failed += 1
            report['suites'][suite] = {'error': str(error), 'offlineSeconds': time.perf_counter() - started}
            print(f'{suite}: ERROR {error}', flush=True)
    report['failures'] = failed
    print('LIMITATIONS: ' + ' '.join(report['limitations']), flush=True)
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True, default=str) + '\n')
        print(f'Report: {args.json.resolve()}', flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
