import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://127.0.0.1:18080';

export const options = {
  scenarios: {
    steady_predeploy: {
      executor: 'constant-arrival-rate',
      rate: 10,
      timeUnit: '1s',
      duration: '45s',
      preAllocatedVUs: 20,
      maxVUs: 50,
    },
  },
  thresholds: {
    // The demo app intentionally injects ~10% HTTP 500 responses.
    // Keep the first gate above that baseline; tighten it when the fault
    // injection is disabled for a production-style exercise.
    http_req_failed: ['rate<0.15'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/work`, {
    tags: { endpoint: 'work' },
  });

  check(response, {
    'candidate returned an expected demo status': (r) =>
      r.status === 200 || r.status === 500,
  });

  sleep(0.05);
}
