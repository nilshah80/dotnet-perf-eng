import { browser } from 'k6/browser';
import { check } from 'k6';

const baseUrl = __ENV.PERF_BASE_URL || 'http://127.0.0.1:18080';

export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto(baseUrl, { waitUntil: 'networkidle' });
    const title = await page.locator('h1').textContent();
    const instance = await page.locator('#status').textContent();
    check({ title, instance }, {
      'browser rendered target': value => value.title === 'Protocol reliability target',
      'browser observed instance': value => value.instance && value.instance !== 'loading',
    });
  } finally {
    await page.close();
  }
}
