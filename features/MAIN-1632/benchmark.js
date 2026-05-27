// MAIN-1632 — staging downtime benchmark.
//
// Hammers GET /api/Estimates against staging while a rollout of
// tofu-invoices-api-deployment / auth-api-deployment happens. We expect to see
// a 1-2 min window of 5xx / connection failures BEFORE the rolling-update fix,
// and zero failures AFTER.
//
// Run:
//   $env:K6_AUTH = '<paste fresh Firebase JWT, no "Bearer " prefix>'
//   k6 run --env DURATION=10m --env RPS=20 benchmark.js
//
// Output (JSON for post-hoc analysis):
//   k6 run --out json=benchmark-$(Get-Date -Format yyyyMMdd-HHmmss).json benchmark.js

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

// --- Config -----------------------------------------------------------------

const BASE_URL = __ENV.BASE_URL || 'https://staging.tofu.com';
const TOKEN = __ENV.K6_AUTH;
const RPS = parseInt(__ENV.RPS || '20', 10);            // requests per second
const DURATION = __ENV.DURATION || '10m';                // total run time
const PRE_ALLOCATED_VUS = parseInt(__ENV.VUS || '20', 10);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '100', 10);

if (!TOKEN) {
    throw new Error('K6_AUTH env var is required (Firebase JWT, no "Bearer " prefix).');
}

// --- Custom metrics ---------------------------------------------------------

const errors = new Counter('estimates_errors');
const successRate = new Rate('estimates_success');
const downtimeRate = new Rate('estimates_downtime');   // 5xx + network errors
const latency = new Trend('estimates_latency_ms', true);

// --- Scenario ---------------------------------------------------------------
// Constant arrival rate so RPS stays flat while the rollout happens — that
// way the error spike during the unhealthy window is unambiguous.

export const options = {
    scenarios: {
        steady: {
            executor: 'constant-arrival-rate',
            rate: RPS,
            timeUnit: '1s',
            duration: DURATION,
            preAllocatedVUs: PRE_ALLOCATED_VUS,
            maxVUs: MAX_VUS,
        },
    },
    thresholds: {
        // Fail the run if we lose more than 0.5% of requests across the window.
        // Pre-fix runs will obviously bust this — that's the point.
        estimates_success: ['rate>0.995'],
        http_req_failed: ['rate<0.005'],
    },
    // Don't abort on threshold breach — we want the full timeline.
    noConnectionReuse: false,
    discardResponseBodies: true,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// --- Request ----------------------------------------------------------------

const headers = {
    'accept': 'text/plain',
    'api-version': '3',
    'XA-App-Type': 'invoices',
    'Authorization': `Bearer ${TOKEN}`,
};

export default function () {
    const res = http.get(`${BASE_URL}/api/Estimates`, {
        headers,
        timeout: '15s',
        tags: { endpoint: 'estimates_list' },
    });

    const ok = res.status >= 200 && res.status < 300;
    const isDowntime = res.status === 0 || res.status >= 500;

    successRate.add(ok);
    downtimeRate.add(isDowntime);
    latency.add(res.timings.duration);
    if (!ok) {
        errors.add(1, { status: String(res.status) });
    }

    check(res, {
        'status is 2xx': (r) => r.status >= 200 && r.status < 300,
        'no 5xx': (r) => r.status < 500,
        'no network error': (r) => r.status !== 0,
    });
}

// --- Summary ----------------------------------------------------------------

export function handleSummary(data) {
    return {
        'stdout': textSummary(data, { indent: '  ', enableColors: true }),
        'benchmark-summary.json': JSON.stringify(data, null, 2),
    };
}
