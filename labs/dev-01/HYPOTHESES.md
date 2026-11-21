# dev-01 hypotheses (from the source, before running)

1. src/http plus src/http/modules hold the largest share of the C code.
2. configure writes objs/Makefile, objs/ngx_auto_config.h (one #define per detected feature or
   option: NGX_DEBUG for --with-debug, NGX_HAVE_KQUEUE on darwin) and objs/ngx_modules.c.
3. ngx_modules[] starts with the core modules (core, errlog, conf) and keeps the HTTP filter
   order written in the comment in auto/modules.
4. Every module declares one type in its ngx_module_t. WRONG at first: I expected six types
   including NGX_MAIL_MODULE; mail is only built with --with-mail, so this build has five.
5. With --with-debug and "error_log ... debug", one GET / shows the phase engine twice: the
   index module turns "/" into an internal redirect to /index.html.
6. debug_connection in events{} enables debug only for the listed client addresses.
7. master_process off + daemon off: one foreground process, no children.
8. ngx_http_init_phase_handlers walks the phases in order and, inside a phase, puts the handlers
   in reverse registration order; registration order is ngx_modules[] order. The indexes in the
   debug log ("generic phase: N") are positions in that array. find-config has a slot (2) but
   its checker logs nothing, so 2 never shows up.
