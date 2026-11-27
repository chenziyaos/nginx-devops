// The same check, changed: wget is refused too.
function check(r) {
    const ua = r.headersIn['User-Agent'] || '';

    if (ua.startsWith('curl') || ua.startsWith('Wget')) {
        r.return(403);
    }
}

export default { check };
