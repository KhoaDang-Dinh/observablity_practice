import http from 'k6/http';
import { check } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://127.0.0.1:18080';
const concurrency = Number(__ENV.CONCURRENCY || '10');
const p95Ms = Number(__ENV.P95_MS || '250');

export const options = {
  vus: concurrency,
  duration: __ENV.DURATION || '60s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: [`p(95)<${p95Ms}`],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/work`, {
    tags: { endpoint: 'work', test: 'eks-rightsizing' },
  });

  check(response, {
    'HTTP 200': (r) => r.status === 200,
  });
}
