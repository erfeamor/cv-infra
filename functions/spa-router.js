// CloudFront Function (viewer-request): routes two SPAs on one distribution.
// cv-public-vanilla owns /, cv-admin-react owns /admin/. Any extension-less
// URI is a client-side route and rewrites to the owning app's index.html;
// URIs with a file extension (assets) pass through untouched.
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri === '/admin' || uri.startsWith('/admin/')) {
    if (!uri.split('/').pop().includes('.')) {
      request.uri = '/admin/index.html';
    }
  } else if (!uri.split('/').pop().includes('.')) {
    request.uri = '/index.html';
  }

  return request;
}
