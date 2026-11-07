#!/usr/bin/env bash
# Offline test harness for functions/spa-router.js (T-061). The function is a
# plain CloudFront Function (ES5-style JS), so node can run it directly: the
# `${apex}` placeholder that Terraform's templatefile() fills in is replaced
# here with a test domain. No AWS, no network. (`aws cloudfront test-function`
# needs the function deployed, so it can't be an offline gate.)
#
# Usage: bash scripts/tests/run-spa-router-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

exec node - "$repo_root/functions/spa-router.js" <<'JS'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const APEX = 'example.test';
if (!src.includes('${apex}')) {
  console.error('FAIL: functions/spa-router.js has no ${apex} placeholder (T-061)');
  process.exit(1);
}
const handler = new Function(src.split('${apex}').join(APEX) + '\nreturn handler;')();

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  ok: ' + name); }
  else { fail++; console.error('  FAIL: ' + name + (detail ? ' -- ' + detail : '')); }
}
function req(uri, host, qs) {
  const request = { uri, headers: {}, querystring: qs || {} };
  if (host !== undefined) request.headers.host = { value: host };
  return handler({ request });
}
function redirectTo(r) {
  return r.statusCode === 301 && r.headers && r.headers.location ? r.headers.location.value : null;
}

// --- routing that existed before T-061 must not change -------------------
check('apex / rewrites to /index.html', req('/', APEX).uri === '/index.html');
check('apex deep link rewrites to /index.html', req('/cv/skills', APEX).uri === '/index.html');
check('apex asset passes through', req('/assets/app.js', APEX).uri === '/assets/app.js');
check('/admin deep link rewrites to /admin/index.html', req('/admin/people', APEX).uri === '/admin/index.html');
check('/admin asset passes through', req('/admin/assets/a.js', APEX).uri === '/admin/assets/a.js');
check('/metrics passes through', req('/metrics', APEX).uri === '/metrics');
check('/health passes through', req('/health', APEX).uri === '/health');
check('cloudfront.net host serves like the apex',
  req('/cv', 'dvdlxl0zqepqi.cloudfront.net').uri === '/index.html');
check('a request with no Host header does not crash', req('/', undefined).uri === '/index.html');

// --- www -> apex ---------------------------------------------------------
check('www / redirects to the apex', redirectTo(req('/', 'www.' + APEX)) === 'https://' + APEX + '/');
check('www keeps the path', redirectTo(req('/admin/people', 'www.' + APEX)) === 'https://' + APEX + '/admin/people');
check('www keeps the query string',
  redirectTo(req('/x', 'www.' + APEX, { a: { value: '1' }, b: { value: 'two words' } })) ===
    'https://' + APEX + '/x?a=1&b=two%20words');
check('www keeps a multi-value query string',
  redirectTo(req('/x', 'www.' + APEX, { t: { value: 'a', multiValue: [{ value: 'a' }, { value: 'b' }] } })) ===
    'https://' + APEX + '/x?t=a&t=b');
check('www redirect is a 301 with a description',
  req('/', 'www.' + APEX).statusDescription === 'Moved Permanently');
check('a lookalike host is not redirected', req('/', 'www.' + APEX + '.evil.test').uri === '/index.html');
check('the apex itself is not redirected', req('/', APEX).statusCode === undefined);

// --- /react -> react.<apex> ---------------------------------------------
const react = 'https://react.' + APEX;
check('/react redirects', redirectTo(req('/react', APEX)) === react);
check('/react/ redirects', redirectTo(req('/react/', APEX)) === react);
check('/react/deep/link redirects', redirectTo(req('/react/deep/link', APEX)) === react);
check('/react redirects on the cloudfront.net host too',
  redirectTo(req('/react', 'dvdlxl0zqepqi.cloudfront.net')) === react);
check('www + /react is one hop to react.<apex>', redirectTo(req('/react', 'www.' + APEX)) === react);
check('/reactor is not /react', req('/reactor', APEX).uri === '/index.html');
check('/admin/react is not /react', req('/admin/react', APEX).uri === '/admin/index.html');
check('a file called /react.js passes through', req('/react.js', APEX).uri === '/react.js');

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
JS
