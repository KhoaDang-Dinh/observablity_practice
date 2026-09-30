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
    // Keep request failures as a hard release gate.
    // Latency is still measured by k6 and shown in the job output, but the
    // instance-sizing workflow owns the hard P95 decision because it compares
    // candidate EC2 types under the same controlled load.
    http_req_failed: ['rate<0.15'],
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
