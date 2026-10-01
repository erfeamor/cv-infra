// CloudFront Function (viewer-request): routes two SPAs on one distribution.
// cv-public-vanilla owns /, cv-admin-react owns /admin/. Any extension-less
// URI is a client-side route and rewrites to the owning app's index.html;
// URIs with a file extension (assets) pass through untouched.
//
// T-014 ruling 4: /metrics and /health are monitoring probe paths, not SPA
// routes -- nothing routes them to the BFF (they're not under /bff/*), but
// before this exclusion the blanket extension-less rewrite sent both to
// /index.html, so a probe aimed at the CloudFront domain read 200-with-the-
// public-shell as "healthy". Excluded here so they fall through to S3
// unrewritten and never return the SPA shell (today that's a genuine 403,
// application/xml -- the bucket has no root index.html; T-403 re-verifies
// once cv-public-vanilla publishes one).
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri === '/metrics' || uri === '/health') {
    return request;
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
