// CloudFront Function (viewer-request): routes two SPAs on one distribution.
// cv-public-vanilla owns /, cv-admin-react owns /admin/. Any extension-less
// URI is a client-side route and rewrites to the owning app's index.html;
// URIs with a file extension (assets) pass through untouched.
//
// T-061: two redirects for the custom domain. `${apex}` is filled in by
// Terraform's templatefile() (frontend.tf); scripts/tests/run-spa-router-
// tests.sh substitutes a test domain and runs this file under node.
//   - /react and /react/* -> https://react.${apex} (cv-public-react lives on
//     Vercel under its own subdomain, T-410; no proxy in front of Vercel).
//   - www.${apex} -> https://${apex}, path and query string kept.
// /react is checked first, so www.${apex}/react is one hop, not two.
//
// T-014 ruling 4: /metrics and /health are monitoring probe paths, not SPA
// routes -- nothing routes them to the BFF (they're not under /bff/*), but
// before this exclusion the blanket extension-less rewrite sent both to
// /index.html, so a probe aimed at the CloudFront domain read 200-with-the-
// public-shell as "healthy". Excluded here so they fall through to S3
// unrewritten and never return the SPA shell (today that's a genuine 403,
// application/xml -- the bucket has no root index.html; T-403 re-verifies
// once cv-public-vanilla publishes one).
function redirect(location) {
  return {
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: { location: { value: location } },
  };
}

// Rebuilds ?a=1&b=2 from CloudFront's parsed querystring object. A repeated
// key arrives as multiValue (value holds only the first).
function queryString(querystring) {
  var parts = [];
  Object.keys(querystring || {}).forEach(function (key) {
    var entry = querystring[key];
    var values = entry.multiValue
      ? entry.multiValue.map(function (v) { return v.value; })
      : [entry.value];
    values.forEach(function (value) {
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
    });
  });
  return parts.length ? '?' + parts.join('&') : '';
}

function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri === '/metrics' || uri === '/health') {
    return request;
  }

  if (uri === '/react' || uri.startsWith('/react/')) {
    return redirect('https://react.${apex}');
  }

  var host = request.headers.host ? request.headers.host.value : '';
  if (host === 'www.${apex}') {
    return redirect('https://${apex}' + uri + queryString(request.querystring));
  }

  if (uri === '/admin' || uri.startsWith('/admin/')) {
    if (!uri.split('/').pop().includes('.')) {
      request.uri = '/admin/index.html';
    }
  } else if (!uri.split('/').pop().includes('.')) {
    request.uri = '/index.html';
  }

  return request;
}
