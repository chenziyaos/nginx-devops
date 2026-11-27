// A check with a bug: it calls a method that does not exist.
function check(r) {
    r.headersIn['User-Agent'].startswith('curl');
}

export default { check };
