# ops-01 hypotheses (from the source, before running)

1. `nginx -v` prints NGINX_VER_BUILD, i.e. "nginx/" NGINX_VERSION from src/core/nginx.h;
   `-V` adds the compiler, the OpenSSL it was built with ("running with" only when the
   runtime library differs) and NGX_CONFIGURE (ngx_show_version_info, src/core/nginx.c).
2. The 1.30.x entries in changes.xml have no "feature" type: a stable branch only takes
   fixes.
3. Modules with HTTP_*=YES in auto/options (tunnel, proxy) are built without any option,
   --with-* adds the others (realip, json); objs/ngx_modules.c lists every static module.
   A directive of a module that is not built is "unknown directive".
4. load_module paths are relative to the prefix (ngx_conf_full_name(cycle, &file, 0));
   a missing file fails in dlopen().
5. nginx -t still runs ngx_init_cycle: it opens the error log and pid file and creates the
   *_temp paths (ngx_create_paths) but does not create logs/.
6. In test mode the pid file is opened with NGX_FILE_CREATE_OR_OPEN and nothing is written
   (ngx_create_pidfile, src/core/ngx_cycle.c:1049-1068), so -t on a stopped nginx leaves an
   empty pid file and a later -s reports "invalid PID number".
7. -s reads the pid file and sends a signal; stop makes the master exit and delete it.
8. -g directives are parsed before the config file, so a pid in the file is a duplicate.
9. -q in test mode suppresses the two success lines (ngx_cycle.c:292), errors still print.
