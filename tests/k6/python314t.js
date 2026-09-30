import http from 'k6/http';
import { check } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://127.0.0.1:18081';
const concurrency = Number(__ENV.CONCURRENCY || '10');

export const options = {
  vus: concurrency,
  duration: __ENV.DURATION || '30s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/cpu`, {
    tags: { endpoint: 'cpu', test: 'python314t-gil-ab' },
  });
  check(response, {
    'HTTP 200': (r) => r.status === 200,
  });
}
