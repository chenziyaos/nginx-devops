// The check of the ngx-rust "curl" example, for js_access: 403 when the
// User-Agent starts with "curl"; returning without a response lets the request go on.
function check(r) {
    const ua = r.headersIn['User-Agent'] || '';

    if (ua.startsWith('curl')) {
        r.return(403);
    }
}

export default { check };
