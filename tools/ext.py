#!/usr/bin/env python3
"""Pinned sources of the projects around nginx that the cloud-native chapters quote.

  python3 tools/ext.py fetch          # shallow-clone every pinned tag into .ext-src/ (not in git)
  python3 tools/ext.py path NAME      # print the checkout directory of NAME

A chapter quotes them with a fenced block whose first line names the project and its tag,
  ```go
  // nginx-gateway-fabric v2.9.1: internal/controller/nginx/config/upstreams.go:25-30
and links to https://github.com/<owner>/<repo>/blob/<tag>/<path>#Ln-Lm. tools/check_docs.py
checks both against the checkout, like it checks nginx excerpts against .nginx-src.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# name -> (GitHub owner/repo, pinned tag)
EXT = {
    'nginx-gateway-fabric': ('nginx/nginx-gateway-fabric', 'v2.9.1'),
    'ingress2gateway': ('kubernetes-sigs/ingress2gateway', 'v1.2.0'),
    'kubernetes': ('kubernetes/kubernetes', 'v1.37.0'),
    'nginx-acme': ('nginx/nginx-acme', 'v0.4.2'),
    'pebble': ('letsencrypt/pebble', 'v2.10.3'),
    'cert-manager': ('cert-manager/cert-manager', 'v1.21.3'),
    'nginx-prometheus-exporter': ('nginx/nginx-prometheus-exporter', 'v1.5.3'),
    'nginx-otel': ('nginxinc/nginx-otel', 'v0.1.2'),
    'njs': ('nginx/njs', '1.0.2'),
    'ngx-rust': ('nginx/ngx-rust', 'v0.5.0'),
}

# big repositories are checked out sparsely: only these directories
SPARSE = {
    'kubernetes': ['pkg/kubelet'],
}

# fence language by file extension
LANG = {'.go': 'go', '.js': 'js', '.rs': 'rust', '.c': 'c', '.h': 'c', '.cpp': 'cpp', '.hpp': 'cpp'}


def path(name):
    repo, tag = EXT[name]
    return os.path.join(ROOT, '.ext-src', '%s-%s' % (name, tag))


def by_repo(owner_repo):
    """The name whose GitHub owner/repo is owner_repo, or None."""
    for name, (repo, _) in EXT.items():
        if repo == owner_repo:
            return name
    return None


def fetch():
    for name, (repo, tag) in sorted(EXT.items()):
        d = path(name)
        if os.path.isdir(d):
            print('have %s %s' % (name, tag))
            continue
        sparse = ['--filter=blob:none', '--sparse'] if name in SPARSE else []
        subprocess.run(['git', '-c', 'advice.detachedHead=false', 'clone', '-q', '--depth', '1',
                        *sparse, '--branch', tag, 'https://github.com/%s' % repo, d], check=True)
        if name in SPARSE:
            subprocess.run(['git', '-C', d, 'sparse-checkout', 'set', *SPARSE[name]], check=True)
        print('fetched %s %s' % (name, tag))


def main():
    if len(sys.argv) == 2 and sys.argv[1] == 'fetch':
        fetch()
    elif len(sys.argv) == 3 and sys.argv[1] == 'path':
        print(path(sys.argv[2]))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
